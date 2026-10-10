"""Starts one task for the model-driven agent (AgentWorkflow) as the root
of its trace (P4-01). Runs in the agent's worker pod, which has the SDKs
and may reach Temporal and the collector:

  kubectl exec -i -n agent deploy/agent-worker -- python - NAME TARGET INSTRUCTION < scripts/agent_task.py

or scripts/agent-task.sh NAME TARGET INSTRUCTION. Prints the trace id.

Why not `temporal workflow start`: the CLI sends no trace context, and
Temporal's tracing interceptor then has no parent for the workflow's
activities, so each becomes its own trace. Starting here, inside an
"agent task" span, puts the workflow, model calls, tool calls, the
ChangeRequest and the controller's decision in one trace."""
import asyncio
import os
import sys

sys.path.insert(0, "/opt/agent")

from temporalio.client import Client  # noqa: E402
from temporalio.contrib.opentelemetry import TracingInterceptor  # noqa: E402

import telemetry  # noqa: E402
from shared import TASK_QUEUE, Goal  # noqa: E402


async def main(name, target, instruction):
    telemetry.setup(with_metrics=False)
    client = await Client.connect(os.environ.get("TEMPORAL_ADDRESS", "localhost:7233"), interceptors=[TracingInterceptor()])
    with telemetry.tracer.start_as_current_span("agent task", attributes={
            "safeops.task": name, "safeops.target": f"workloads/{target}"}) as span:
        await client.start_workflow("AgentWorkflow", Goal(name=name, instruction=instruction, target_name=target),
                                    id=name, task_queue=TASK_QUEUE)
        print(format(span.get_span_context().trace_id, "032x"))
    telemetry.shutdown()


asyncio.run(main(*sys.argv[1:4]))
