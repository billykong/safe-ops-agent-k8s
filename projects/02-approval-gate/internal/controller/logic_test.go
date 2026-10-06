package controller

import (
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	v1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

func ptr[T any](v T) *T { return &v }

func spec(ns, kind string, scopeNS, scopeKinds []string) v1.ChangeRequestSpec {
	return v1.ChangeRequestSpec{
		Action: v1.Action{Type: v1.ScaleDeployment, Replicas: ptr(int32(2)),
			Target: v1.TargetRef{Kind: kind, Namespace: ns, Name: "web"}},
		Scope: v1.Scope{Namespaces: scopeNS, Kinds: scopeKinds},
	}
}

func TestCheckScope(t *testing.T) {
	cases := []struct {
		name    string
		spec    v1.ChangeRequestSpec
		wantErr bool
	}{
		{"in scope", spec("workloads", "Deployment", []string{"workloads"}, []string{"Deployment"}), false},
		{"namespace outside scope", spec("kube-system", "Deployment", []string{"workloads"}, []string{"Deployment"}), true},
		{"kind outside scope", spec("workloads", "Deployment", []string{"workloads"}, []string{"ConfigMap"}), true},
	}
	for _, c := range cases {
		if err := CheckScope(c.spec); (err != nil) != c.wantErr {
			t.Errorf("%s: err = %v, wantErr %v", c.name, err, c.wantErr)
		}
	}
}

func TestPlanScale(t *testing.T) {
	a := v1.Action{Type: v1.ScaleDeployment, Replicas: ptr(int32(3))}
	plan, rb, err := Plan(a, v1.TargetState{Replicas: 1}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if plan != `{"spec":{"replicas":3}}` || rb != `{"spec":{"replicas":1}}` {
		t.Errorf("plan %s rollback %s", plan, rb)
	}
}

func TestPlanRestart(t *testing.T) {
	now := time.Date(2026, 10, 6, 1, 2, 3, 0, time.UTC)
	a := v1.Action{Type: v1.RestartDeployment}
	plan, rb, err := Plan(a, v1.TargetState{}, now)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"2026-10-06T01:02:03Z"}}}}}`
	if plan != want {
		t.Errorf("plan = %s", plan)
	}
	// No previous restart: the rollback removes the annotation (null).
	if rb != `{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":null}}}}}` {
		t.Errorf("rollback = %s", rb)
	}
	// With a previous restart, the rollback restores it.
	_, rb, _ = Plan(a, v1.TargetState{RestartedAt: "2026-01-01T00:00:00Z"}, now)
	if rb != `{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"2026-01-01T00:00:00Z"}}}}}` {
		t.Errorf("rollback with previous restart = %s", rb)
	}
}

func TestPlanRejectsMalformedAction(t *testing.T) {
	if _, _, err := Plan(v1.Action{Type: v1.ScaleDeployment}, v1.TargetState{}, time.Now()); err == nil {
		t.Error("scale without replicas planned")
	}
	if _, _, err := Plan(v1.Action{Type: "DeleteNamespace"}, v1.TargetState{}, time.Now()); err == nil {
		t.Error("unknown action planned")
	}
}

func TestObserveAndDrift(t *testing.T) {
	dep := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Generation: 4},
		Spec: appsv1.DeploymentSpec{Replicas: ptr(int32(2)), Template: corev1.PodTemplateSpec{
			ObjectMeta: metav1.ObjectMeta{Annotations: map[string]string{RestartAnnotation: "t1"}}}},
	}
	pre := Observe(dep)
	if pre != (v1.TargetState{Generation: 4, Replicas: 2, RestartedAt: "t1"}) {
		t.Fatalf("observe = %+v", pre)
	}
	if Drifted(pre, Observe(dep)) {
		t.Error("unchanged target reported as drifted")
	}
	dep.Generation = 5 // e.g. someone edited the image
	if !Drifted(pre, Observe(dep)) {
		t.Error("generation change not detected")
	}
	// Defaulted replicas (nil) read as 1, like the API server's default.
	if got := Observe(&appsv1.Deployment{}).Replicas; got != 1 {
		t.Errorf("nil replicas observed as %d", got)
	}
}

func TestReviewHash(t *testing.T) {
	cr := &v1.ChangeRequest{Spec: spec("workloads", "Deployment", []string{"workloads"}, []string{"Deployment"})}
	cr.UID = "uid-1"
	cr.Status.PreState = &v1.TargetState{Generation: 1, Replicas: 1}
	cr.Status.Plan, cr.Status.RollbackPlan = `{"spec":{"replicas":2}}`, `{"spec":{"replicas":1}}`
	h1, err := ReviewHash(cr)
	if err != nil {
		t.Fatal(err)
	}
	if h2, _ := ReviewHash(cr); h1 != h2 || len(h1) != len("sha256:")+64 {
		t.Fatalf("not stable or malformed: %s %s", h1, h2)
	}
	// Each reviewed part changes the hash.
	mutations := map[string]func(c *v1.ChangeRequest){
		"uid":      func(c *v1.ChangeRequest) { c.UID = "uid-2" },
		"spec":     func(c *v1.ChangeRequest) { c.Spec.Intent = "other" },
		"preState": func(c *v1.ChangeRequest) { c.Status.PreState = &v1.TargetState{Generation: 2, Replicas: 1} },
		"plan":     func(c *v1.ChangeRequest) { c.Status.Plan = `{"spec":{"replicas":9}}` },
		"rollback": func(c *v1.ChangeRequest) { c.Status.RollbackPlan = `{"spec":{"replicas":0}}` },
	}
	for name, mutate := range mutations {
		c := cr.DeepCopy()
		mutate(c)
		if h, _ := ReviewHash(c); h == h1 {
			t.Errorf("changing %s didn't change the hash", name)
		}
	}
	// Status fields outside the review (phase, approval) don't.
	c := cr.DeepCopy()
	c.Status.Phase, c.Status.Message = v1.PhaseApplying, "x"
	if h, _ := ReviewHash(c); h != h1 {
		t.Error("phase/message changed the hash")
	}
}
