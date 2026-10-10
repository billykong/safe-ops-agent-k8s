package controller

import (
	"context"
	"strings"

	"github.com/prometheus/client_golang/prometheus"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
	"sigs.k8s.io/controller-runtime/pkg/metrics"

	approvalv1alpha1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

// TraceAnnotation carries the proposer's W3C trace context (P4-01), so
// the controller's spans for a request join the trace of the task that
// proposed it: model calls, tool calls, the ChangeRequest and its fate in
// one trace. The proposer writes it, so it decides only which trace the
// spans join; what they say comes from the controller.
const TraceAnnotation = "approval.safe-ops.io/traceparent"

// GateDecisions counts the semantic action gate's decisions (P4-02's
// escalation rate): each time a plan is judged, so a request re-proposed
// after drift counts again.
var GateDecisions = prometheus.NewCounterVec(prometheus.CounterOpts{
	Name: "safeops_gate_decisions_total",
	Help: "Decisions of the semantic action gate (Allow, Escalate, Deny), by action type.",
}, []string{"result", "action"})

func init() {
	metrics.Registry.MustRegister(GateDecisions)
	// Series start at zero, so a series' first increase is counted.
	for _, r := range []approvalv1alpha1.PolicyResult{approvalv1alpha1.PolicyAllow, approvalv1alpha1.PolicyEscalate, approvalv1alpha1.PolicyDeny} {
		for _, a := range []approvalv1alpha1.ActionType{approvalv1alpha1.ScaleDeployment, approvalv1alpha1.RestartDeployment} {
			GateDecisions.WithLabelValues(string(r), string(a))
		}
	}
}

func tracer() trace.Tracer { return otel.Tracer("safe-ops.io/approval-controller") }

// traceContext is ctx with the request's proposer's trace as parent, if
// its annotation holds a valid one.
func traceContext(ctx context.Context, cr *approvalv1alpha1.ChangeRequest) context.Context {
	tp := cr.Annotations[TraceAnnotation]
	if tp == "" {
		return ctx
	}
	return propagation.TraceContext{}.Extract(ctx, propagation.MapCarrier{"traceparent": tp})
}

func crAttributes(cr *approvalv1alpha1.ChangeRequest) []attribute.KeyValue {
	t := cr.Spec.Action.Target
	return []attribute.KeyValue{
		attribute.String("safeops.changerequest", cr.Namespace+"/"+cr.Name),
		attribute.String("safeops.action", string(cr.Spec.Action.Type)),
		attribute.String("safeops.target", t.Namespace+"/"+t.Name),
	}
}

// traceDecision records one gate decision: a span in the proposer's trace
// and the counter.
func traceDecision(ctx context.Context, cr *approvalv1alpha1.ChangeRequest, rv *approvalv1alpha1.Review) {
	d := rv.Policy
	GateDecisions.WithLabelValues(string(d.Result), string(cr.Spec.Action.Type)).Inc()
	_, span := tracer().Start(traceContext(ctx, cr), "policy gate", trace.WithAttributes(crAttributes(cr)...))
	span.SetAttributes(
		attribute.String("safeops.policy.result", string(d.Result)),
		attribute.String("safeops.policy.sha", d.PolicySHA),
		attribute.Int("safeops.review.findings", len(rv.Findings)),
		attribute.Int("safeops.replicas.before", int(rv.BlastRadius.ReplicasBefore)),
		attribute.Int("safeops.replicas.after", int(rv.BlastRadius.ReplicasAfter)),
		attribute.Bool("safeops.dry_run.accepted", !strings.HasPrefix(rv.DryRun, "refused")),
	)
	span.End()
}

// traceFinish records a request reaching its final phase, and who or
// what settled it.
func traceFinish(ctx context.Context, cr *approvalv1alpha1.ChangeRequest) {
	st := cr.Status
	by := "controller"
	switch {
	case st.Phase == approvalv1alpha1.PhaseExpired:
		by = "expiry"
	case st.Phase == approvalv1alpha1.PhaseCancelled:
		by = "kill-switch"
	case st.Approval != nil:
		by = "human"
	case st.BudgetGrant != nil:
		by = "change-budget"
	}
	_, span := tracer().Start(traceContext(ctx, cr), "settle", trace.WithAttributes(crAttributes(cr)...))
	span.SetAttributes(attribute.String("safeops.phase", string(st.Phase)), attribute.String("safeops.settled_by", by))
	if st.ProposedAt != nil && st.DecidedAt != nil {
		span.SetAttributes(attribute.Float64("safeops.seconds_to_decision", st.DecidedAt.Sub(st.ProposedAt.Time).Seconds()))
	}
	span.End()
}
