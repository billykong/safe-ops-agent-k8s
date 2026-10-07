package controller

import (
	"fmt"
	"slices"
	"time"

	corev1 "k8s.io/api/core/v1"

	approvalv1alpha1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

// The kill switch (P2-21) is one ConfigMap. The agent runs only while its
// data.mode is exactly "run"; anything else, including the ConfigMap being
// missing or unreadable, means stopped. The same object is the parameter of
// the agent-kill-switch admission policy (manifests/90-kill-switch.yaml).
const (
	KillSwitchNamespace = "approval-system"
	KillSwitchName      = "agent-kill-switch"
	KillSwitchRun       = "run"
)

// Running reports whether the kill switch lets the agent run, and why not.
// A nil ConfigMap means it wasn't found.
func Running(cm *corev1.ConfigMap) (bool, string) {
	if cm == nil {
		return false, fmt.Sprintf("kill switch %s/%s is missing: stopped (fail closed)", KillSwitchNamespace, KillSwitchName)
	}
	if mode := cm.Data["mode"]; mode != KillSwitchRun {
		why := fmt.Sprintf("kill switch engaged (mode %q)", mode)
		if r := cm.Data["reason"]; r != "" {
			why += ": " + r
		}
		return false, why
	}
	return true, ""
}

// Eligible reports why an action may not be applied on the budget, or nil.
func Eligible(b approvalv1alpha1.ChangeBudgetSpec, a approvalv1alpha1.Action) error {
	if !slices.Contains(b.Actions, a.Type) {
		return fmt.Errorf("%s is not an autonomous action (budget allows %v)", a.Type, b.Actions)
	}
	if !slices.Contains(b.Namespaces, a.Target.Namespace) {
		return fmt.Errorf("namespace %q is not autonomous (budget allows %v)", a.Target.Namespace, b.Namespaces)
	}
	if a.Type == approvalv1alpha1.ScaleDeployment {
		if a.Replicas == nil || *a.Replicas < b.MinReplicas || *a.Replicas > b.MaxReplicas {
			r := "none"
			if a.Replicas != nil {
				r = fmt.Sprint(*a.Replicas)
			}
			return fmt.Errorf("scaling to %s replicas is outside the autonomous range %d-%d", r, b.MinReplicas, b.MaxReplicas)
		}
	}
	return nil
}

// InWindow returns the grants made within window before now.
func InWindow(grants []approvalv1alpha1.Grant, window time.Duration, now time.Time) []approvalv1alpha1.Grant {
	var live []approvalv1alpha1.Grant
	for _, g := range grants {
		if now.Sub(g.Time.Time) < window {
			live = append(live, g)
		}
	}
	return live
}

// BudgetWindow is the budget's rolling window.
func BudgetWindow(b approvalv1alpha1.ChangeBudgetSpec) time.Duration {
	if b.WindowSeconds <= 0 {
		return time.Hour
	}
	return time.Duration(b.WindowSeconds) * time.Second
}
