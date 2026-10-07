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
