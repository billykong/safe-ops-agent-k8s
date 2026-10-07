package controller

import (
	"strings"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	policyv1 "k8s.io/api/policy/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"

	v1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

func deployment(replicas, ready int32) *appsv1.Deployment {
	d := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "web", Generation: 3}}
	d.Spec.Replicas = ptr(replicas)
	d.Spec.Template.Labels = map[string]string{"app": "web"}
	d.Status = appsv1.DeploymentStatus{ObservedGeneration: 3, Replicas: replicas, UpdatedReplicas: replicas, ReadyReplicas: ready}
	return d
}

func recreate(d *appsv1.Deployment) *appsv1.Deployment {
	d.Spec.Strategy.Type = appsv1.RecreateDeploymentStrategyType
	return d
}

func pdb(name string, minAvailable int) policyv1.PodDisruptionBudget {
	m := intstr.FromInt(minAvailable)
	return policyv1.PodDisruptionBudget{ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: policyv1.PodDisruptionBudgetSpec{MinAvailable: &m, Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": "web"}}}}
}

func codes(fs []v1.Finding) string {
	var c []string
	for _, f := range fs {
		c = append(c, string(f.Severity)+":"+f.Code)
	}
	return strings.Join(c, ",")
}

func scale(n int32) v1.Action { return v1.Action{Type: v1.ScaleDeployment, Replicas: ptr(n)} }

func TestDiff(t *testing.T) {
	before := map[string]any{"spec": map[string]any{"replicas": int64(1), "template": map[string]any{"metadata": map[string]any{}}}}
	after := map[string]any{"spec": map[string]any{"replicas": int64(2), "template": map[string]any{"metadata": map[string]any{
		"annotations": map[string]any{"kubectl.kubernetes.io/restartedAt": "T"}}}}}
	d := Diff(before, after, DiffRoots...)
	if len(d) != 2 || d[0].Path != "spec.replicas" || d[0].From != "1" || d[0].To != "2" ||
		d[1].Path != `spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]` || d[1].From != "" || d[1].To != `"T"` {
		t.Errorf("diff: %+v", d)
	}
	if len(Diff(before, before, DiffRoots...)) != 0 {
		t.Error("diff of identical objects")
	}
}

func TestBlastRadius(t *testing.T) {
	d := deployment(4, 4)
	if br := BlastRadius(d, scale(6), nil); br.PodsAdded != 2 || br.PodsRemoved != 0 || br.Summary != "adds 2 pods (4 -> 6)" {
		t.Errorf("scale up: %+v", br)
	}
	br := BlastRadius(d, v1.Action{Type: v1.RestartDeployment}, []policyv1.PodDisruptionBudget{pdb("web-pdb", 2)})
	if br.PodsReplaced != 4 || br.MaxUnavailable != 1 || len(br.DisruptionBudgets) != 1 {
		t.Errorf("restart: %+v", br) // 25% of 4, rounded down
	}
	d.Spec.Strategy.Type = appsv1.RecreateDeploymentStrategyType
	if MaxUnavailable(d, 4) != 4 {
		t.Error("Recreate takes all pods down")
	}
}

func TestFindings(t *testing.T) {
	restart := v1.Action{Type: v1.RestartDeployment}
	some := []v1.FieldChange{{Path: "spec.replicas"}}
	cases := []struct {
		name    string
		dep     *appsv1.Deployment
		a       v1.Action
		pdbs    []policyv1.PodDisruptionBudget
		diff    []v1.FieldChange
		refusal string
		want    string
	}{
		{"healthy small scale", deployment(2, 2), scale(3), nil, some, "", ""},
		{"scale to zero", deployment(2, 2), scale(0), nil, some, "", "Critical:ScaleToZero"},
		{"below PDB", deployment(3, 3), scale(1), []policyv1.PodDisruptionBudget{pdb("web-pdb", 2)}, some, "",
			"Critical:BelowDisruptionBudget,Warning:LargeScaleDown"},
		{"more than doubles", deployment(2, 2), scale(5), nil, some, "", "Warning:LargeScaleUp"},
		// Default strategy: 25% of 1 rounds down to 0 unavailable (a surge
		// pod comes first), so no downtime and no finding.
		{"single-replica restart, rolling", deployment(1, 1), restart, nil, some, "", ""},
		{"restart with Recreate", recreate(deployment(3, 3)), restart, nil, some, "", "Warning:RolloutTakesAllPods"},
		{"degraded target", deployment(3, 1), restart, nil, some, "", "Warning:TargetDegraded"},
		{"dry run refused", deployment(2, 2), scale(3), nil, nil, "denied", "Critical:DryRunRefused"},
		{"no change", deployment(2, 2), scale(2), nil, nil, "", "Info:NoChange"},
	}
	for _, c := range cases {
		br := BlastRadius(c.dep, c.a, c.pdbs)
		if got := codes(Findings(c.dep, c.a, br, c.pdbs, c.diff, c.refusal)); got != c.want {
			t.Errorf("%s: findings %q, want %q", c.name, got, c.want)
		}
	}
	d := deployment(2, 2)
	d.Generation = 4
	if got := codes(Findings(d, scale(3), BlastRadius(d, scale(3), nil), nil, some, "")); got != "Warning:RolloutInProgress" {
		t.Errorf("rollout in progress: %q", got)
	}
}

func TestRollbackCheck(t *testing.T) {
	live := map[string]any{"spec": map[string]any{"replicas": int64(1)}}
	after := map[string]any{"spec": map[string]any{"replicas": int64(2)}}
	if got := RollbackCheck(live, after, `{"spec":{"replicas":1}}`); !strings.HasPrefix(got, "passed") {
		t.Errorf("good rollback: %s", got)
	}
	if got := RollbackCheck(live, after, `{"spec":{"replicas":3}}`); !strings.HasPrefix(got, "FAILED") || !strings.Contains(got, "spec.replicas") {
		t.Errorf("bad rollback: %s", got)
	}
	// Restart: rollback removes the annotation that wasn't there before.
	liveR := map[string]any{"spec": map[string]any{"template": map[string]any{"metadata": map[string]any{}}}}
	afterR := map[string]any{"spec": map[string]any{"template": map[string]any{"metadata": map[string]any{
		"annotations": map[string]any{RestartAnnotation: "T"}}}}}
	_, rb, _ := Plan(v1.Action{Type: v1.RestartDeployment}, v1.TargetState{}, time.Date(2026, 10, 7, 1, 2, 3, 0, time.UTC))
	if got := RollbackCheck(liveR, afterR, rb); !strings.HasPrefix(got, "passed") {
		t.Errorf("restart rollback: %s", got)
	}
}
