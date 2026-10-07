package controller

import (
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	v1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

func TestRunning(t *testing.T) {
	cm := func(data map[string]string) *corev1.ConfigMap { return &corev1.ConfigMap{Data: data} }
	cases := []struct {
		name string
		cm   *corev1.ConfigMap
		want bool
	}{
		{"missing: fail closed", nil, false},
		{"run", cm(map[string]string{"mode": "run"}), true},
		{"stop", cm(map[string]string{"mode": "stop", "reason": "incident"}), false},
		{"no mode", cm(nil), false},
		{"anything but run", cm(map[string]string{"mode": "Run "}), false},
	}
	for _, c := range cases {
		if got, why := Running(c.cm); got != c.want || (!got && why == "") {
			t.Errorf("%s: Running = %v %q, want %v with a reason", c.name, got, why, c.want)
		}
	}
}

func TestEligible(t *testing.T) {
	b := v1.ChangeBudgetSpec{MaxChanges: 2, Actions: []v1.ActionType{v1.ScaleDeployment, v1.RestartDeployment},
		Namespaces: []string{"workloads"}, MinReplicas: 1, MaxReplicas: 3}
	act := func(typ v1.ActionType, ns string, replicas *int32) v1.Action {
		return v1.Action{Type: typ, Replicas: replicas, Target: v1.TargetRef{Kind: "Deployment", Namespace: ns, Name: "web"}}
	}
	cases := []struct {
		name string
		a    v1.Action
		ok   bool
	}{
		{"restart", act(v1.RestartDeployment, "workloads", nil), true},
		{"scale in range", act(v1.ScaleDeployment, "workloads", ptr(int32(3))), true},
		{"scale to zero", act(v1.ScaleDeployment, "workloads", ptr(int32(0))), false},
		{"scale above max", act(v1.ScaleDeployment, "workloads", ptr(int32(4))), false},
		{"other namespace", act(v1.RestartDeployment, "prod", nil), false},
	}
	for _, c := range cases {
		if err := Eligible(b, c.a); (err == nil) != c.ok {
			t.Errorf("%s: Eligible = %v, want ok=%v", c.name, err, c.ok)
		}
	}
	restartOnly := b
	restartOnly.Actions = []v1.ActionType{v1.RestartDeployment}
	if Eligible(restartOnly, act(v1.ScaleDeployment, "workloads", ptr(int32(2)))) == nil {
		t.Error("scale allowed by a restart-only budget")
	}
}

func TestInWindow(t *testing.T) {
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	at := func(ago time.Duration) v1.Grant { return v1.Grant{Time: metav1.NewTime(now.Add(-ago))} }
	live := InWindow([]v1.Grant{at(2 * time.Hour), at(time.Hour), at(59 * time.Minute), at(time.Second)}, time.Hour, now)
	if len(live) != 2 {
		t.Errorf("want the 2 grants younger than an hour, got %d", len(live))
	}
	if BudgetWindow(v1.ChangeBudgetSpec{}) != time.Hour || BudgetWindow(v1.ChangeBudgetSpec{WindowSeconds: 10}) != 10*time.Second {
		t.Error("BudgetWindow")
	}
}
