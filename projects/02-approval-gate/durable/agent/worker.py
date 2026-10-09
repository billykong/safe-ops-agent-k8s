"""The agent as a Temporal worker (P2-30): runs ChangeWorkflow and its
activities from the `agent` task queue. Holds no state of its own: kill it
at any point and another worker resumes from the workflow history."""
import asyncio
import os
import signal
from concurrent.futures import ThreadPoolExecutor

from temporalio.client import Client
from temporalio.worker import Worker

from activities import await_decision, log, propose
from model import decide, observe
from shared import TASK_QUEUE
from workflows import AgentWorkflow, ChangeWorkflow

ADDRESS = os.environ.get("TEMPORAL_ADDRESS", "localhost:7233")
NAMESPACE = os.environ.get("TEMPORAL_NAMESPACE", "default")


async def main():
    # PID 1 gets no default SIGTERM action: handle it, or the pod waits out
    # its grace period and is SIGKILLed (P1 finding). Before connecting:
    # Client.connect keeps retrying while Temporal is down.
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for s in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(s, stop.set)
    connect = asyncio.ensure_future(Client.connect(ADDRESS, namespace=NAMESPACE))
    stopping = asyncio.ensure_future(stop.wait())
    await asyncio.wait([connect, stopping], return_when=asyncio.FIRST_COMPLETED)
    if not connect.done():
        connect.cancel()
        log("worker_stopping", connected=False)
        return
    client = connect.result()
    with ThreadPoolExecutor(max_workers=8) as pool:
        worker = Worker(client, task_queue=TASK_QUEUE, workflows=[ChangeWorkflow, AgentWorkflow],
                        activities=[propose, await_decision, observe, decide], activity_executor=pool)
        async with worker:
            log("worker_started", address=ADDRESS, namespace=NAMESPACE, task_queue=TASK_QUEUE)
            await stop.wait()
            log("worker_stopping")


if __name__ == "__main__":
    asyncio.run(main())
