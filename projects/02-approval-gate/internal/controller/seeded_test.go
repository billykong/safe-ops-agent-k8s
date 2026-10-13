package controller

import (
	"testing"

	v1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

func TestParseSeed(t *testing.T) {
	data := map[string]string{
		"good":    `{"expected": "Approved", "reason": "a sound scale-up"}`,
		"bad":     `{"expected": "Rejected", "reason": "intent and action disagree"}`,
		"garbled": `{expected`,
		"odd":     `{"expected": "Maybe"}`,
	}
	if s := ParseSeed(data, "absent"); s != nil {
		t.Errorf("absent: %+v, want nil", s)
	}
	if s := ParseSeed(data, "good"); s == nil || s.Expected != v1.DecisionApproved || s.Reason != "a sound scale-up" {
		t.Errorf("good: %+v", s)
	}
	// Anything but a clear "Approved" expects a rejection: still seeded,
	// so still never applied.
	for _, n := range []string{"bad", "garbled", "odd"} {
		if s := ParseSeed(data, n); s == nil || s.Expected != v1.DecisionRejected {
			t.Errorf("%s: %+v, want a seeded entry expecting Rejected", n, s)
		}
	}
	if s := ParseSeed(nil, "good"); s != nil {
		t.Errorf("no data: %+v", s)
	}
}

func TestSeedResult(t *testing.T) {
	bad := &Seed{Expected: v1.DecisionRejected, Reason: "r"}
	good := &Seed{Expected: v1.DecisionApproved}
	status := func(policy v1.PolicyResult, d v1.Decision) v1.ChangeRequestStatus {
		st := v1.ChangeRequestStatus{Review: &v1.Review{Policy: &v1.PolicyDecision{Result: policy}}}
		if d != "" {
			st.Approval = &v1.Approval{Decision: d, Approver: "alice"}
		}
		return st
	}
	cases := []struct {
		name      string
		seed      *Seed
		st        v1.ChangeRequestStatus
		automated v1.SeedOutcome
		human     v1.SeedOutcome
	}{
		{"bad, escalated, rejected", bad, status(v1.PolicyEscalate, v1.DecisionRejected), v1.SeedCaught, v1.SeedCaught},
		{"bad, allowed, approved", bad, status(v1.PolicyAllow, v1.DecisionApproved), v1.SeedMissed, v1.SeedMissed},
		{"bad, allowed, rejected: the human caught what the rules missed", bad, status(v1.PolicyAllow, v1.DecisionRejected), v1.SeedMissed, v1.SeedCaught},
		{"bad, denied before a human saw it", bad, status(v1.PolicyDeny, ""), v1.SeedCaught, v1.SeedUndecided},
		{"good, allowed, approved", good, status(v1.PolicyAllow, v1.DecisionApproved), v1.SeedPassed, v1.SeedPassed},
		{"good, escalated, rejected", good, status(v1.PolicyEscalate, v1.DecisionRejected), v1.SeedFalseAlarm, v1.SeedFalseAlarm},
		{"no review yet", bad, v1.ChangeRequestStatus{}, v1.SeedUndecided, v1.SeedUndecided},
	}
	for _, c := range cases {
		r := SeedResult(c.seed, c.st)
		if r.Automated != c.automated || r.Human != c.human || r.Expected != c.seed.Expected {
			t.Errorf("%s: %+v, want automated %s, human %s", c.name, r, c.automated, c.human)
		}
		if (c.st.Approval != nil) != (r.Approver == "alice") {
			t.Errorf("%s: approver %q", c.name, r.Approver)
		}
	}
}
