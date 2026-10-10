package controller

import (
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"sort"
	"strings"

	jsonpatch "github.com/evanphx/json-patch/v5"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/util/intstr"

	approvalv1alpha1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

// The review packet (P2-40) is built here from the live target, the
// server's dry run of the exact plan, and the namespace's disruption
// budgets. Plain rules over those inputs: the same cluster state always
// gives the same packet, and nothing the proposer wrote is used.

// DiffRoots are the parts of an object a plan may change and an approver
// must see.
var DiffRoots = []string{"spec", "metadata.labels", "metadata.annotations"}

// Diff lists every leaf that differs between two objects under the roots,
// sorted by path. Lists compare as a whole. Values are JSON.
func Diff(before, after map[string]any, roots ...string) []approvalv1alpha1.FieldChange {
	var out []approvalv1alpha1.FieldChange
	for _, root := range roots {
		diffAt(root, lookup(before, root), lookup(after, root), &out)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

func lookup(m map[string]any, path string) any {
	var v any = m
	for _, k := range strings.Split(path, ".") {
		mm, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = mm[k]
	}
	return v
}

func diffAt(path string, a, b any, out *[]approvalv1alpha1.FieldChange) {
	// An absent map and an empty one are the same object to the API (a
	// merge patch that removes the last annotation leaves "{}"), so
	// descend into a map even when the other side has none.
	am, aok := a.(map[string]any)
	bm, bok := b.(map[string]any)
	if aok && b == nil {
		bm, bok = map[string]any{}, true
	}
	if bok && a == nil {
		am, aok = map[string]any{}, true
	}
	if aok && bok {
		keys := map[string]bool{}
		for k := range am {
			keys[k] = true
		}
		for k := range bm {
			keys[k] = true
		}
		for k := range keys {
			diffAt(join(path, k), am[k], bm[k], out)
		}
		return
	}
	if reflect.DeepEqual(a, b) {
		return
	}
	*out = append(*out, approvalv1alpha1.FieldChange{Path: path, From: encode(a), To: encode(b)})
}

// join keeps annotation keys like kubectl.kubernetes.io/restartedAt readable.
func join(path, key string) string {
	if strings.ContainsAny(key, "./") {
		return fmt.Sprintf("%s[%q]", path, key)
	}
	return path + "." + key
}

func encode(v any) string {
	if v == nil {
		return ""
	}
	b, _ := json.Marshal(v)
	return string(b)
}

// BlastRadius computes what an action does to the target's pods.
func BlastRadius(dep *appsv1.Deployment, a approvalv1alpha1.Action, pdbs []policyv1.PodDisruptionBudget) approvalv1alpha1.ComputedBlastRadius {
	before := Observe(dep).Replicas
	after := before
	if a.Type == approvalv1alpha1.ScaleDeployment && a.Replicas != nil {
		after = *a.Replicas
	}
	br := approvalv1alpha1.ComputedBlastRadius{
		ReplicasBefore: before, ReplicasAfter: after, ReadyBefore: dep.Status.ReadyReplicas,
		PodsAdded: max(after-before, 0), PodsRemoved: max(before-after, 0),
		MaxUnavailable: MaxUnavailable(dep, after),
	}
	if a.Type == approvalv1alpha1.RestartDeployment {
		br.PodsReplaced = after
	}
	for _, p := range pdbs {
		if Selects(p, dep) {
			br.DisruptionBudgets = append(br.DisruptionBudgets, p.Name)
		}
	}
	sort.Strings(br.DisruptionBudgets)
	switch {
	case a.Type == approvalv1alpha1.RestartDeployment:
		br.Summary = fmt.Sprintf("replaces all %d pods, at most %d unavailable at a time", after, br.MaxUnavailable)
	case after > before:
		br.Summary = fmt.Sprintf("adds %d pods (%d -> %d)", br.PodsAdded, before, after)
	case after < before:
		br.Summary = fmt.Sprintf("removes %d pods (%d -> %d)", br.PodsRemoved, before, after)
	default:
		br.Summary = fmt.Sprintf("no pods change (%d replicas)", before)
	}
	return br
}

// MaxUnavailable resolves the Deployment's rollout limit for a replica
// count: all of them for Recreate, else maxUnavailable (default 25%,
// rounded down, as the Deployment controller does).
func MaxUnavailable(dep *appsv1.Deployment, replicas int32) int32 {
	if dep.Spec.Strategy.Type == appsv1.RecreateDeploymentStrategyType {
		return replicas
	}
	mu := intstr.FromString("25%")
	if ru := dep.Spec.Strategy.RollingUpdate; ru != nil && ru.MaxUnavailable != nil {
		mu = *ru.MaxUnavailable
	}
	v, err := intstr.GetScaledValueFromIntOrPercent(&mu, int(replicas), false)
	if err != nil {
		return 0
	}
	return int32(min(v, int(replicas)))
}

// Selects reports whether a PodDisruptionBudget covers the Deployment's pods.
func Selects(p policyv1.PodDisruptionBudget, dep *appsv1.Deployment) bool {
	sel, err := metav1.LabelSelectorAsSelector(p.Spec.Selector)
	return err == nil && !sel.Empty() && sel.Matches(labels.Set(dep.Spec.Template.Labels))
}

// Findings applies the review rules. dryRunRefusal is the API server's
// reason for refusing the dry run, or "".
func Findings(dep *appsv1.Deployment, a approvalv1alpha1.Action, br approvalv1alpha1.ComputedBlastRadius,
	pdbs []policyv1.PodDisruptionBudget, diff []approvalv1alpha1.FieldChange, dryRunRefusal string) []approvalv1alpha1.Finding {
	var fs []approvalv1alpha1.Finding
	add := func(s approvalv1alpha1.Severity, code, format string, args ...any) {
		fs = append(fs, approvalv1alpha1.Finding{Severity: s, Code: code, Message: fmt.Sprintf(format, args...)})
	}
	crit, warn, info := approvalv1alpha1.SeverityCritical, approvalv1alpha1.SeverityWarning, approvalv1alpha1.SeverityInfo
	if dryRunRefusal != "" {
		add(crit, "DryRunRefused", "the API server refused a dry run of this exact patch: %s", dryRunRefusal)
	}
	before, after := br.ReplicasBefore, br.ReplicasAfter
	if after == 0 && before > 0 {
		add(crit, "ScaleToZero", "scales to zero: every pod of %s goes away", dep.Name)
	}
	if after > before && after-before >= 2 && after > 2*before {
		add(warn, "LargeScaleUp", "more than doubles the replicas (%d -> %d)", before, after)
	}
	if after > 0 && after*2 < before {
		add(warn, "LargeScaleDown", "removes more than half the replicas (%d -> %d)", before, after)
	}
	for _, p := range pdbs {
		if !Selects(p, dep) || p.Spec.MinAvailable == nil {
			continue
		}
		need, err := intstr.GetScaledValueFromIntOrPercent(p.Spec.MinAvailable, int(after), true)
		if err == nil && after < int32(need) {
			add(crit, "BelowDisruptionBudget", "%d replicas is below PodDisruptionBudget %s (minAvailable %s)", after, p.Name, p.Spec.MinAvailable.String())
		}
	}
	if a.Type == approvalv1alpha1.RestartDeployment && after > 0 && br.MaxUnavailable >= after {
		add(warn, "RolloutTakesAllPods", "the rollout may take all %d pods down at once (maxUnavailable %d)", after, br.MaxUnavailable)
	}
	if dep.Status.ReadyReplicas < before {
		add(warn, "TargetDegraded", "only %d of %d pods are ready now", dep.Status.ReadyReplicas, before)
	}
	if dep.Status.ObservedGeneration < dep.Generation || dep.Status.UpdatedReplicas < dep.Status.Replicas {
		add(warn, "RolloutInProgress", "a rollout of %s is still in progress", dep.Name)
	}
	if dryRunRefusal == "" && len(diff) == 0 {
		add(info, "NoChange", "the plan changes nothing on the live object")
	}
	rank := map[approvalv1alpha1.Severity]int{crit: 0, warn: 1, info: 2}
	sort.SliceStable(fs, func(i, j int) bool { return rank[fs[i].Severity] < rank[fs[j].Severity] })
	return fs
}

// Worst returns the highest severity among findings, or "".
func Worst(fs []approvalv1alpha1.Finding) approvalv1alpha1.Severity {
	for _, s := range []approvalv1alpha1.Severity{approvalv1alpha1.SeverityCritical, approvalv1alpha1.SeverityWarning, approvalv1alpha1.SeverityInfo} {
		if slices.ContainsFunc(fs, func(f approvalv1alpha1.Finding) bool { return f.Severity == s }) {
			return s
		}
	}
	return ""
}

// RollbackCheck applies the rollback merge patch to the dry run's result
// and compares the outcome with the live object: the rollback must restore
// every reviewed field exactly.
func RollbackCheck(live, after map[string]any, rollback string) string {
	// Compare JSON with JSON: numbers from the converter are int64, from
	// JSON float64.
	lb, err := json.Marshal(live)
	if err != nil {
		return "not checked: " + err.Error()
	}
	live = nil
	if err := json.Unmarshal(lb, &live); err != nil {
		return "not checked: " + err.Error()
	}
	ab, err := json.Marshal(after)
	if err != nil {
		return "not checked: " + err.Error()
	}
	rb, err := jsonpatch.MergePatch(ab, []byte(rollback))
	if err != nil {
		return "not checked: rollback patch doesn't apply: " + err.Error()
	}
	var restored map[string]any
	if err := json.Unmarshal(rb, &restored); err != nil {
		return "not checked: " + err.Error()
	}
	if d := Diff(live, restored, DiffRoots...); len(d) > 0 {
		paths := make([]string, len(d))
		for i, c := range d {
			paths[i] = c.Path
		}
		return "FAILED: the rollback leaves these fields changed: " + strings.Join(paths, ", ")
	}
	return "passed: the rollback patch, applied to the dry run's result, restores the pre-state exactly"
}

// PolicyInput is what the semantic action gate sees: the typed action, the
// live target's labels and pods, the namespace's labels, and the computed
// review (not the proposer's text).
func PolicyInput(cr *approvalv1alpha1.ChangeRequest, dep *appsv1.Deployment, ns *corev1.Namespace, rv *approvalv1alpha1.Review) (map[string]any, error) {
	b, err := json.Marshal(map[string]any{
		"action":    cr.Spec.Action,
		"target":    map[string]any{"labels": nonNilMap(dep.Labels), "replicasBefore": Observe(dep).Replicas, "readyBefore": dep.Status.ReadyReplicas},
		"namespace": map[string]any{"name": ns.Name, "labels": nonNilMap(ns.Labels)},
		"review":    rv,
	})
	if err != nil {
		return nil, err
	}
	var in map[string]any
	return in, json.Unmarshal(b, &in)
}

func nonNilMap(m map[string]string) map[string]string {
	if m == nil {
		return map[string]string{}
	}
	return m
}
