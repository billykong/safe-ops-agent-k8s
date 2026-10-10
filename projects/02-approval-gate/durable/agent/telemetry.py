"""The agent's telemetry (P4-01, P4-02): OpenTelemetry traces and metrics,
sent over OTLP/HTTP to the collector named by OTEL_EXPORTER_OTLP_ENDPOINT.
Without it, everything here is a no-op.

Spans follow the GenAI semantic conventions: `invoke_agent` per decision,
`chat <model>` per model call, `execute_tool <tool>` per MCP tool call,
with token counts. They never carry content (P4-03): no prompts, no
instruction, no model output, no tool arguments or results; only names,
counts, ids and outcomes. The collector enforces that again with an
attribute allowlist, since the agent's own telemetry is no more trusted
than the agent.

The metrics here are the agent's own account (tasks and how they ended,
model and tool calls). Tokens and cost are counted by the LLM gateway,
gate decisions by the approval controller: those are the trusted numbers,
and a dashboard can compare the two."""
import os

from opentelemetry import metrics, propagate, trace
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

SERVICE = "safe-ops-agent"
ENABLED = bool(os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT"))


def setup(with_metrics=True):
    """Install the tracer and meter providers. Call once, before the
    Temporal client connects. A short-lived process (the task starter)
    sends traces only: its zeroed counters would collide with the
    worker's."""
    propagate.set_global_textmap(TraceContextTextMapPropagator())
    if not ENABLED:
        return
    from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    # The instance is the pod: each worker's counters are their own series.
    res = Resource.create({"service.name": SERVICE, "service.instance.id": os.environ.get("HOSTNAME", "")})
    tp = TracerProvider(resource=res)
    tp.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(tp)
    if not with_metrics:
        return
    metrics.set_meter_provider(MeterProvider(resource=res, metric_readers=[
        PeriodicExportingMetricReader(OTLPMetricExporter(), export_interval_millis=10_000)]))
    init_series()


def shutdown():
    for p in (trace.get_tracer_provider(), metrics.get_meter_provider()):
        if hasattr(p, "shutdown"):
            p.shutdown()


tracer = trace.get_tracer("safe-ops.io/agent")
_meter = metrics.get_meter("safe-ops.io/agent")
tasks = _meter.create_counter("safeops.agent.tasks", unit="{task}",
                              description="Agent decisions, by action and, for escalations, why (agent-reported).")
model_calls = _meter.create_counter("safeops.agent.model_calls", unit="{call}",
                                    description="Model calls the agent made, by outcome (agent-reported).")
tool_calls = _meter.create_counter("safeops.agent.tool_calls", unit="{call}",
                                   description="MCP tool calls the agent made, by tool and outcome (agent-reported).")
# The GenAI conventions' client metrics.
token_usage = _meter.create_histogram("gen_ai.client.token.usage", unit="{token}",
                                      description="Tokens per model call, by type.",
                                      explicit_bucket_boundaries_advisory=[1, 4, 16, 64, 256, 1024, 4096, 16384, 65536, 262144])
duration = _meter.create_histogram("gen_ai.client.operation.duration", unit="s",
                                   description="Model call duration.",
                                   explicit_bucket_boundaries_advisory=[0.01, 0.04, 0.16, 0.64, 2.56, 10.24, 40.96, 81.92])


# Why the agent escalates (model.escalate's kinds), so every series exists
# from the start at zero and its first increase is counted.
ESCALATIONS = ("model_chose", "invalid_output", "no_action", "too_many_lookups", "step_limit", "model_refused",
               "model_unavailable", "model_request_failed", "gateway_budget", "no_target")


def init_series():
    for d in ("ScaleDeployment", "RestartDeployment"):
        tasks.add(0, {"decision": d, "escalation": "none"})
    for e in ESCALATIONS:
        tasks.add(0, {"decision": "Escalate", "escalation": e})
    model_calls.add(0, {"outcome": "ok"})


def trace_headers() -> dict:
    """Headers that carry the current trace to a gateway."""
    carrier = {}
    propagate.inject(carrier)
    return carrier
