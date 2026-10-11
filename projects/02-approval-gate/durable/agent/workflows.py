"""The agent's change workflow (P2-30). Deterministic: no I/O here, only
activities, timers and state, so Temporal can replay it on any worker after
a crash. Everything that touches the cluster is in activities.py."""
from datetime import datetime, timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    from dataclasses import replace

    from shared import (FINAL_PHASES, AgentOutcome, ChangeTask, Decision, DecideRequest, DecisionSummary, Goal,
                        ModelDecision, Observation, Outcome, PollRequest, Progress)


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


@workflow.defn
class AgentWorkflow:
    """The model-driven agent (P3 milestone 2): observe the target, ask the
    model through the gateway what to do, and either escalate or propose
    the chosen typed action through ChangeWorkflow, which waits for the
    approval gate. The model never touches the cluster."""

    def __init__(self) -> None:
        self._state = "starting"
        self._decision: DecisionSummary | None = None

    @workflow.query
    def state(self) -> str:
        return self._state

    @workflow.query
    def decision(self) -> DecisionSummary | None:
        """The validated decision, once made, without the model's reasoning."""
        return self._decision

    @workflow.run
    async def run(self, goal: Goal) -> AgentOutcome:
        self._state = "observing"
        obs = await workflow.execute_activity(
            "observe", goal, result_type=Observation, start_to_close_timeout=timedelta(seconds=30),
            retry_policy=RetryPolicy(maximum_attempts=5))
        self._state = "asking the model"
        # At most two attempts: the activity turns model and gateway errors
        # into an escalation itself, so a retry here is for crashes only,
        # and every attempt spends budget.
        d: ModelDecision = await workflow.execute_activity(
            "decide", DecideRequest(goal, obs), result_type=ModelDecision,
            start_to_close_timeout=timedelta(seconds=150), retry_policy=RetryPolicy(maximum_attempts=2))
        self._decision = DecisionSummary(action=d.action, replicas=d.replicas, escalation=d.escalation, model=d.model,
                                         prompt_sha=d.prompt_sha, tools_used=list(d.tools_used))
        if d.action == "Escalate":
            self._state = "escalated"
            return AgentOutcome(goal=goal.name, action=d.action, reason=d.reason, detail=d.detail, tools_used=d.tools_used)
        action = {"type": d.action, "target": {"kind": "Deployment", "namespace": goal.target_namespace, "name": goal.target_name}}
        if d.action == "ScaleDeployment":
            action["replicas"] = d.replicas
        task = ChangeTask(
            name=goal.name,
            intent=(f"[model's reasoning, not verified] {d.reason}\n\n[operator's instruction] {goal.instruction}"
                    + (f"\n\n[tools read] {', '.join(d.tools_used)}" if d.tools_used else ""))[:2000],
            action=action,
            blast_radius="not assessed by the agent: see the controller's review packet",
            rollback="apply the controller's recorded rollbackPlan",
            approval_window_seconds=goal.approval_window_seconds,
            scope_namespaces=[goal.target_namespace],
        )
        self._state = f"proposed {d.action}; waiting for the approval gate"
        change: Outcome = await workflow.execute_child_workflow(
            ChangeWorkflow.run, task, id=f"{goal.name}-change", result_type=Outcome)
        self._state = change.phase
        return AgentOutcome(goal=goal.name, action=d.action, reason=d.reason, change=change, tools_used=d.tools_used)
