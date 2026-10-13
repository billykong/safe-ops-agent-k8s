package oversight

import (
	"math"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	v1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

var t0 = time.Date(2026, 10, 7, 9, 0, 0, 0, time.UTC)

func cr(phase v1.Phase, approver string, d v1.Decision, after time.Duration, sev v1.Severity) v1.ChangeRequest {
	p, dec := metav1.NewTime(t0), metav1.NewTime(t0.Add(after))
	st := v1.ChangeRequestStatus{Phase: phase, ProposedAt: &p, DecidedAt: &dec, Proposals: 1}
	if approver != "" {
		st.Approval = &v1.Approval{Approver: approver, Decision: d}
	}
	if sev != "" {
		st.Review = &v1.Review{Findings: []v1.Finding{{Severity: sev, Code: "X"}}}
	}
	return v1.ChangeRequest{Status: st}
}

func TestCompute(t *testing.T) {
	budget := cr(v1.PhaseApplied, "", "", time.Second, "")
	budget.Status.BudgetGrant = &v1.BudgetGrant{Budget: "default"}
	drifted := cr(v1.PhasePending, "", "", 0, "")
	drifted.Status.Proposals = 2
	drifted.Status.DecidedAt = nil
	items := []v1.ChangeRequest{
		cr(v1.PhaseApplied, "alice", v1.DecisionApproved, time.Minute, ""),
		cr(v1.PhaseApplied, "alice", v1.DecisionApproved, 3*time.Minute, v1.SeverityCritical),
		cr(v1.PhaseRejected, "alice", v1.DecisionRejected, 5*time.Minute, v1.SeverityWarning),
		cr(v1.PhaseApplied, "bob", v1.DecisionApproved, time.Hour, v1.SeverityWarning),
		cr(v1.PhaseExpired, "", "", time.Hour, ""),
		cr(v1.PhaseCancelled, "", "", time.Minute, ""),
		cr(v1.PhaseRejected, "", "", 0, ""), // out of scope, by the controller
		budget, drifted,
	}
	r := Compute(items)
	if r.Total != 9 || r.ByHuman != 4 || r.ByBudget != 1 || r.ByController != 1 || r.Expired != 1 || r.Cancelled != 1 || r.Reproposed != 1 {
		t.Fatalf("report: %+v", r)
	}
	alice, bob := r.Approvers[0], r.Approvers[1]
	if alice.Name != "alice" || alice.Approved != 2 || alice.Rejected != 1 || alice.ApprovedCritical != 1 || alice.ApprovedFlagged != 1 {
		t.Errorf("alice: %+v", alice)
	}
	if math.Abs(alice.ApprovalRate()-2.0/3) > 1e-9 || bob.ApprovedFlagged != 1 || bob.ApprovedCritical != 0 {
		t.Errorf("rates: alice %v, bob %+v", alice.ApprovalRate(), bob)
	}
	if Quantile(alice.Seconds, 0.5) != 180 || len(r.BudgetSeconds) != 1 || len(r.HumanSeconds) != 4 {
		t.Errorf("times: %v %v %v", alice.Seconds, r.BudgetSeconds, r.HumanSeconds)
	}
	if !math.IsNaN(Quantile(nil, 0.5)) || Quantile([]float64{1, 2, 3, 4}, 0.9) != 3.7 {
		t.Error("Quantile")
	}
}

func TestReopened(t *testing.T) {
	at := func(name, target string, phase v1.Phase, proposed, applied time.Duration) v1.ChangeRequest {
		p := metav1.NewTime(t0.Add(proposed))
		c := v1.ChangeRequest{Status: v1.ChangeRequestStatus{Phase: phase, ProposedAt: &p}}
		c.Name = name
		c.Spec.Action.Target = v1.TargetRef{Kind: "Deployment", Namespace: "workloads", Name: target}
		if phase == v1.PhaseApplied {
			a := metav1.NewTime(t0.Add(applied))
			c.Status.AppliedAt = &a
		}
		return c
	}
	items := []v1.ChangeRequest{
		at("web-1", "web", v1.PhaseApplied, 0, time.Minute),    // web-2 follows 9m after: reopened
		at("web-2", "web", v1.PhasePending, 10*time.Minute, 0), // not applied
		at("api-1", "api", v1.PhaseApplied, 0, time.Minute),    // api-2 is 2h later: not reopened
		at("api-2", "api", v1.PhaseApplied, 2*time.Hour, 2*time.Hour+time.Minute),
		at("db-1", "db", v1.PhaseApplied, 0, time.Minute), // other targets don't count
	}
	r := Compute(items)
	if r.Applied != 4 || r.Reopened != 1 {
		t.Fatalf("applied %d reopened %d, want 4 and 1", r.Applied, r.Reopened)
	}
}

func TestLatestEvalRun(t *testing.T) {
	run := func(name, finished string, passed int64, held string) unstructured.Unstructured {
		u := unstructured.Unstructured{Object: map[string]any{
			"spec": map[string]any{
				"finishedAt": finished,
				"summary":    map[string]any{"total": int64(3), "passed": passed, "disagreements": int64(1), "safetyHeld": held},
				"scenarios": []any{
					map[string]any{"id": "a", "passed": true, "safetyHeld": true},
					map[string]any{"id": "b", "passed": false, "safetyHeld": held == "true"},
				},
			}}}
		u.SetName(name)
		return u
	}
	var runs []EvalRun
	for _, u := range []unstructured.Unstructured{
		run("old", "2026-10-07T09:00:00Z", 3, "true"),
		run("new", "2026-10-08T09:00:00Z", 2, "false"),
	} {
		runs = append(runs, ParseEvalRun(u))
	}
	r, ok := Latest(runs)
	if !ok || r.Name != "new" || r.Total != 3 || r.Passed != 2 || r.Disagreements != 1 || r.SafetyHeld {
		t.Fatalf("latest: %+v", r)
	}
	if len(r.Scenarios) != 2 || !r.Scenarios[0].Passed || r.Scenarios[1].Passed || r.Scenarios[1].SafetyHeld {
		t.Errorf("scenarios: %+v", r.Scenarios)
	}
	if _, ok := Latest(nil); ok {
		t.Error("Latest(nil) found a run")
	}
}

func TestSeeded(t *testing.T) {
	seeded := func(phase v1.Phase, approver string, d v1.Decision, auto, human v1.SeedOutcome) v1.ChangeRequest {
		c := cr(phase, approver, d, time.Minute, "")
		c.Status.Seeded = &v1.SeededResult{Expected: v1.DecisionRejected, Automated: auto, Human: human, Approver: approver}
		return c
	}
	items := []v1.ChangeRequest{
		seeded(v1.PhaseRejected, "alice", v1.DecisionRejected, v1.SeedCaught, v1.SeedCaught),
		seeded(v1.PhaseWithheld, "alice", v1.DecisionApproved, v1.SeedMissed, v1.SeedMissed),
		seeded(v1.PhaseRejected, "alice", v1.DecisionRejected, v1.SeedMissed, v1.SeedCaught),
		seeded(v1.PhaseRejected, "", "", v1.SeedCaught, v1.SeedUndecided),  // denied by policy
		seeded(v1.PhaseWithheld, "", "", v1.SeedMissed, v1.SeedUndecided),  // the budget would have paid
		cr(v1.PhaseApplied, "alice", v1.DecisionApproved, time.Minute, ""), // not seeded
	}
	r := Compute(items)
	if r.Withheld != 2 {
		t.Errorf("withheld: %d, want 2", r.Withheld)
	}
	if a := r.SeededAutomated; a[v1.SeedCaught] != 2 || a[v1.SeedMissed] != 3 || CatchRate(a) != 0.4 {
		t.Errorf("automated: %v (rate %v)", a, CatchRate(a))
	}
	if h := r.SeededHuman["alice"]; h[v1.SeedCaught] != 2 || h[v1.SeedMissed] != 1 || math.Abs(CatchRate(h)-2.0/3) > 1e-9 {
		t.Errorf("alice: %v", h)
	}
	if len(r.SeededHuman) != 1 {
		t.Errorf("only alice decided seeded proposals: %v", r.SeededHuman)
	}
	// Withheld is final, and an approval there is still a human decision.
	if r.ByHuman != 4 || r.ByController != 2 {
		t.Errorf("settled by: human %d, controller %d", r.ByHuman, r.ByController)
	}
	if !math.IsNaN(CatchRate(nil)) {
		t.Error("no decisions: want NaN")
	}
}
