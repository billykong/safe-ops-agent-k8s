"""The agent's change workflow (P2-30). Deterministic: no I/O here, only
activities, timers and state, so Temporal can replay it on any worker after
a crash. Everything that touches the cluster is in activities.py."""
from datetime import datetime, timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    from dataclasses import replace

    from shared import FINAL_PHASES, ChangeTask, Decision, Outcome, PollRequest, Progress


@workflow.defn
class ChangeWorkflow:
    def __init__(self) -> None:
        self._state = "starting"

    @workflow.query
    def state(self) -> str:
        return self._state

    @workflow.run
    async def run(self, task: ChangeTask) -> Outcome:
        progress = task.progress or Progress(started=workflow.now().isoformat())
        if not progress.proposed:
            self._state = "proposing"
            # Idempotent: a retry after a crash finds its own ChangeRequest.
            await workflow.execute_activity(
                "propose", task,
                start_to_close_timeout=timedelta(seconds=30),
                retry_policy=RetryPolicy(initial_interval=timedelta(seconds=1), maximum_interval=timedelta(seconds=30)),
            )
            progress.proposed = True
        polls_this_run = 0
        while True:
            self._state = "waiting for a decision"
            # Each poll lasts a few minutes and heartbeats; if the worker dies
            # mid-poll, the missed heartbeat reschedules it on another worker
            # within heartbeat_timeout. Unlimited retries: an approval can
            # take hours, and the ChangeRequest's own expiry ends the wait.
            d: Decision = await workflow.execute_activity(
                "await_decision", PollRequest(task.name, task.poll_window_seconds),
                result_type=Decision,
                start_to_close_timeout=timedelta(minutes=10),
                heartbeat_timeout=timedelta(seconds=20),
                retry_policy=RetryPolicy(initial_interval=timedelta(seconds=1), maximum_interval=timedelta(seconds=30)),
            )
            progress.polls += 1
            polls_this_run += 1
            if d.phase in FINAL_PHASES:
                self._state = d.phase
                waited = (workflow.now() - datetime.fromisoformat(progress.started)).total_seconds()
                return Outcome(change_request=task.name, phase=d.phase, message=d.message,
                               decided_by=d.decided_by, waited_seconds=round(waited, 1), polls=progress.polls,
                               runs=progress.runs)
            self._state = f"waiting for a decision ({d.phase or 'not yet proposed'})"
            # A day of waiting is a few hundred polls; start a fresh history
            # when Temporal suggests it, carrying the progress over.
            if workflow.info().is_continue_as_new_suggested() or polls_this_run == task.polls_per_run:
                progress.runs += 1
                workflow.continue_as_new(replace(task, progress=progress))
