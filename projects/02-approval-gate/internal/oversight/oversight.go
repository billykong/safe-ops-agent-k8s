// Package oversight computes oversight metrics (P2-42) from the
// ChangeRequests themselves: who decided what, how fast, and whether they
// approved requests the review rules flagged. Derived from the record on
// every call, not counted in memory, so a controller restart or a replayed
// reconcile can't skew them.
package oversight

import (
	"context"
	"math"
	"sort"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	v1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

// Approver is one human approver's record.
type Approver struct {
	Name     string
	Approved int
	Rejected int
	// ApprovedFlagged counts approvals of requests whose packet had a
	// Warning or Critical finding; ApprovedCritical, a Critical one. A high
	// share with few rejections is a rubber-stamping signal.
	ApprovedFlagged  int
	ApprovedCritical int
	// Seconds from proposal to decision, per decided request.
	Seconds []float64
}

// ApprovalRate is approved / decided, or NaN with no decisions.
func (a Approver) ApprovalRate() float64 {
	if a.Approved+a.Rejected == 0 {
		return math.NaN()
	}
	return float64(a.Approved) / float64(a.Approved+a.Rejected)
}

// Report summarises a set of ChangeRequests.
type Report struct {
	Total   int
	ByPhase map[v1.Phase]int
	// Final outcomes by who or what settled them.
	ByHuman, ByBudget, ByController, Expired, Cancelled int
	// Reproposed: requests whose plan was recomputed after drift.
	Reproposed int
	Approvers  []Approver
	// HumanSeconds and BudgetSeconds: proposal-to-decision times.
	HumanSeconds, BudgetSeconds []float64
}

var final = map[v1.Phase]bool{v1.PhaseApplied: true, v1.PhaseRejected: true, v1.PhaseFailed: true,
	v1.PhaseExpired: true, v1.PhaseCancelled: true}

// Compute builds the report.
func Compute(items []v1.ChangeRequest) Report {
	r := Report{ByPhase: map[v1.Phase]int{}}
	byName := map[string]*Approver{}
	for i := range items {
		st := items[i].Status
		r.Total++
		r.ByPhase[st.Phase]++
		if st.Proposals > 1 {
			r.Reproposed++
		}
		if !final[st.Phase] {
			continue
		}
		secs := math.NaN()
		if st.ProposedAt != nil && st.DecidedAt != nil {
			secs = st.DecidedAt.Sub(st.ProposedAt.Time).Seconds()
		}
		switch {
		case st.Phase == v1.PhaseExpired:
			r.Expired++
		case st.Phase == v1.PhaseCancelled:
			r.Cancelled++
		case st.Approval != nil:
			r.ByHuman++
			a := byName[st.Approval.Approver]
			if a == nil {
				a = &Approver{Name: st.Approval.Approver}
				byName[a.Name] = a
			}
			if st.Approval.Decision == v1.DecisionApproved {
				a.Approved++
				switch worst(st.Review) {
				case v1.SeverityCritical:
					a.ApprovedCritical++
					a.ApprovedFlagged++
				case v1.SeverityWarning:
					a.ApprovedFlagged++
				}
			} else {
				a.Rejected++
			}
			if !math.IsNaN(secs) {
				a.Seconds = append(a.Seconds, secs)
				r.HumanSeconds = append(r.HumanSeconds, secs)
			}
		case st.BudgetGrant != nil:
			r.ByBudget++
			if !math.IsNaN(secs) {
				r.BudgetSeconds = append(r.BudgetSeconds, secs)
			}
		default:
			r.ByController++ // rejected for scope, failed to apply, ...
		}
	}
	for _, a := range byName {
		r.Approvers = append(r.Approvers, *a)
	}
	sort.Slice(r.Approvers, func(i, j int) bool { return r.Approvers[i].Name < r.Approvers[j].Name })
	return r
}

func worst(rv *v1.Review) v1.Severity {
	if rv == nil {
		return ""
	}
	w := v1.Severity("")
	for _, f := range rv.Findings {
		switch {
		case f.Severity == v1.SeverityCritical:
			return f.Severity
		case f.Severity == v1.SeverityWarning:
			w = f.Severity
		}
	}
	return w
}

// Quantile of xs (0..1), linear interpolation; NaN if empty.
func Quantile(xs []float64, q float64) float64 {
	if len(xs) == 0 {
		return math.NaN()
	}
	s := append([]float64(nil), xs...)
	sort.Float64s(s)
	pos := q * float64(len(s)-1)
	lo := int(math.Floor(pos))
	hi := int(math.Ceil(pos))
	return s[lo] + (s[hi]-s[lo])*(pos-float64(lo))
}

// Buckets for time to decision: 10 s to a day.
var Buckets = []float64{10, 60, 300, 900, 3600, 4 * 3600, 24 * 3600}

// Collector exposes a Report as Prometheus metrics, recomputed on every
// scrape from list (normally the controller's cache).
type Collector struct {
	List func(context.Context) ([]v1.ChangeRequest, error)

	requests, decisions, flagged, reproposed, outcomes *prometheus.Desc
	timeToDecision                                     *prometheus.Desc
}

func NewCollector(list func(context.Context) ([]v1.ChangeRequest, error)) *Collector {
	return &Collector{
		List: list,
		requests: prometheus.NewDesc("safeops_changerequests", "ChangeRequests by phase.",
			[]string{"phase"}, nil),
		outcomes: prometheus.NewDesc("safeops_changerequest_outcomes", "Final ChangeRequests by what settled them.",
			[]string{"settled_by"}, nil),
		decisions: prometheus.NewDesc("safeops_approver_decisions", "Human decisions by approver.",
			[]string{"approver", "decision"}, nil),
		flagged: prometheus.NewDesc("safeops_approver_approvals_flagged",
			"Approvals of requests whose review packet had findings of at least this severity.",
			[]string{"approver", "severity"}, nil),
		reproposed: prometheus.NewDesc("safeops_changerequests_reproposed",
			"ChangeRequests re-proposed after their target drifted.", nil, nil),
		timeToDecision: prometheus.NewDesc("safeops_changerequest_time_to_decision_seconds",
			"Seconds from proposal to decision.", []string{"decided_by"}, nil),
	}
}

func (c *Collector) Describe(ch chan<- *prometheus.Desc) {
	for _, d := range []*prometheus.Desc{c.requests, c.outcomes, c.decisions, c.flagged, c.reproposed, c.timeToDecision} {
		ch <- d
	}
}

func (c *Collector) Collect(ch chan<- prometheus.Metric) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	items, err := c.List(ctx)
	if err != nil {
		ch <- prometheus.NewInvalidMetric(c.requests, err)
		return
	}
	r := Compute(items)
	g := func(d *prometheus.Desc, v int, labels ...string) {
		ch <- prometheus.MustNewConstMetric(d, prometheus.GaugeValue, float64(v), labels...)
	}
	for p, n := range r.ByPhase {
		g(c.requests, n, string(p))
	}
	g(c.outcomes, r.ByHuman, "human")
	g(c.outcomes, r.ByBudget, "change-budget")
	g(c.outcomes, r.ByController, "controller")
	g(c.outcomes, r.Expired, "expiry")
	g(c.outcomes, r.Cancelled, "kill-switch")
	g(c.reproposed, r.Reproposed)
	for _, a := range r.Approvers {
		g(c.decisions, a.Approved, a.Name, "approved")
		g(c.decisions, a.Rejected, a.Name, "rejected")
		g(c.flagged, a.ApprovedFlagged, a.Name, "warning")
		g(c.flagged, a.ApprovedCritical, a.Name, "critical")
	}
	hist := func(xs []float64, by string) {
		counts := map[float64]uint64{}
		sum := 0.0
		for _, x := range xs {
			sum += x
			for _, b := range Buckets {
				if x <= b {
					counts[b]++
				}
			}
		}
		ch <- prometheus.MustNewConstHistogram(c.timeToDecision, uint64(len(xs)), sum, counts, by)
	}
	hist(r.HumanSeconds, "human")
	hist(r.BudgetSeconds, "change-budget")
}
