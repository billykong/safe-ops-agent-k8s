// Package telemetry sets up the gateways' OpenTelemetry tracing (P4-01):
// OTLP over HTTP to the collector named by OTEL_EXPORTER_OTLP_ENDPOINT, W3C
// trace context in and out. Without that variable, tracing is a no-op, so
// the binaries run unchanged outside the cluster and in unit tests.
//
// Spans carry what happened (identity, model, tokens, tool, outcome),
// never content: no prompts, completions, tool arguments or results
// (P4-03). The collector drops any attribute not on its allowlist as well.
package telemetry

import (
	"context"
	"net/http"
	"os"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.40.0"
	"go.opentelemetry.io/otel/trace"
)

// Setup installs the global tracer provider and propagator for service,
// and returns a function that flushes and stops it.
func Setup(ctx context.Context, service string) (func(context.Context) error, error) {
	otel.SetTextMapPropagator(propagation.TraceContext{})
	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" && os.Getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") == "" {
		return func(context.Context) error { return nil }, nil
	}
	exp, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, err
	}
	res, err := resource.Merge(resource.Default(), resource.NewSchemaless(semconv.ServiceName(service)))
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp), sdktrace.WithResource(res))
	otel.SetTracerProvider(tp)
	return tp.Shutdown, nil
}

// Tracer is the gateways' tracer.
func Tracer() trace.Tracer { return otel.Tracer("safe-ops.io/gateway") }

// Extract returns r's context with the caller's trace context, if it sent
// one. The caller is an agent, so this only decides which trace the
// gateway's span joins; nothing in the span is taken from the caller.
func Extract(r *http.Request) context.Context {
	return otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
}
