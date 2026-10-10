"""Types shared by the workflow and its activities. Plain dataclasses, so
Temporal's default converter stores them as JSON in the workflow history."""
from dataclasses import dataclass, field
from typing import Optional

TASK_QUEUE = "agent"
# ChangeRequest phases after which nothing more will happen.
FINAL_PHASES = ("Applied", "Rejected", "Failed", "Expired", "Cancelled")


@dataclass
class Progress:
    """Carried across continue-as-new, so a long wait keeps a small history."""
    started: str
    proposed: bool = False
    polls: int = 0
    runs: int = 1


@dataclass
class ChangeTask:
    """What the agent was asked to do. `name` becomes the ChangeRequest's name.
    `progress` is set only by the workflow itself, when it continues as new:
    the workflow takes this one argument, because the SDK ignores parameter
    types when the number of inputs differs from the number of parameters,
    and a second, optional parameter left the first arriving as a dict."""
    name: str
    intent: str
    action: dict
    blast_radius: str
    rollback: str
    approval_window_seconds: int = 3600
    scope_namespaces: list = field(default_factory=lambda: ["workloads"])
    # How long one poll activity watches the ChangeRequest before reporting
    # back, and how many polls one run makes before continuing as new (0:
    # only when Temporal suggests it). Small values let a test show a long
    # wait in seconds.
    poll_window_seconds: int = 240
    polls_per_run: int = 0
    progress: Optional[Progress] = None


@dataclass
class PollRequest:
    name: str
    window_seconds: int


@dataclass
class Decision:
    """The ChangeRequest as one poll saw it."""
    phase: str
    message: str = ""
    decided_by: str = ""


@dataclass
class Outcome:
    change_request: str
    phase: str
    message: str
    decided_by: str
    waited_seconds: float
    polls: int
    runs: Optional[int] = None


@dataclass
class Goal:
    """A task for the model-driven agent (P3 milestone 2). The operator
    fixes the target; the model only chooses what to do to it. `name`
    becomes the ChangeRequest's name if the model proposes a change."""
    name: str
    instruction: str
    target_namespace: str = "workloads"
    target_name: str = "web"
    approval_window_seconds: int = 3600


@dataclass
class Observation:
    """The target as the agent read it from the cluster."""
    exists: bool
    replicas: int = 0
    ready_replicas: int = 0
    generation: int = 0
    restarted_at: str = ""


@dataclass
class DecideRequest:
    goal: Goal
    observation: Observation


@dataclass
class ModelDecision:
    """What the model chose, validated: ScaleDeployment, RestartDeployment
    or Escalate. `detail` says why it escalated when the model didn't
    choose to (unavailable, refused, out of budget, invalid output)."""
    action: str
    reason: str
    replicas: Optional[int] = None
    detail: str = ""
    model: str = ""
    request_id: str = ""
    # MCP tools the model read before deciding (server__tool), in order.
    tools_used: list = field(default_factory=list)
    # Why it escalated, in one word (model_chose, invalid_output,
    # step_limit, ...); "" when it proposed a change.
    escalation: str = ""


@dataclass
class AgentOutcome:
    goal: str
    action: str
    reason: str
    detail: str = ""
    change: Optional[Outcome] = None
    tools_used: list = field(default_factory=list)
