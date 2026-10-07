package oversight

import (
	"math"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

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
