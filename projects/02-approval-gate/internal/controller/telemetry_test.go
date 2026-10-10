package controller

import (
	"context"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"go.opentelemetry.io/otel/trace"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	approvalv1alpha1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

func TestTraceContext(t *testing.T) {
	cr := &approvalv1alpha1.ChangeRequest{ObjectMeta: metav1.ObjectMeta{Annotations: map[string]string{
		TraceAnnotation: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}}}
	sc := trace.SpanContextFromContext(traceContext(context.Background(), cr))
	if !sc.IsRemote() || sc.TraceID().String() != "4bf92f3577b34da6a3ce929d0e0e4736" {
		t.Errorf("trace context from the annotation: %v", sc)
	}
	for _, bad := range []string{"", "not a traceparent", "00-00000000000000000000000000000000-00f067aa0ba902b7-01"} {
		cr.Annotations[TraceAnnotation] = bad
		if sc := trace.SpanContextFromContext(traceContext(context.Background(), cr)); sc.IsValid() {
			t.Errorf("annotation %q gave a parent: %v", bad, sc)
		}
	}
}

func TestTraceDecisionCounts(t *testing.T) {
	cr := &approvalv1alpha1.ChangeRequest{Spec: approvalv1alpha1.ChangeRequestSpec{
		Action: approvalv1alpha1.Action{Type: approvalv1alpha1.ScaleDeployment}}}
	c := GateDecisions.WithLabelValues("Escalate", "ScaleDeployment")
	before := testutil.ToFloat64(c)
	traceDecision(context.Background(), cr, &approvalv1alpha1.Review{
		Policy: &approvalv1alpha1.PolicyDecision{Result: approvalv1alpha1.PolicyEscalate}})
	if got := testutil.ToFloat64(c) - before; got != 1 {
		t.Errorf("Escalate decisions grew by %v, want 1", got)
	}
}
