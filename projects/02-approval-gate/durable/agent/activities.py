"""Activities: the agent's only contact with the cluster. As the agent's
service account they may create and read ChangeRequests in approvals,
nothing else (RBAC, agent-write-guard, the kill switch)."""
import json
import os
import ssl
import time
import urllib.error
import urllib.request

from temporalio import activity
from temporalio.exceptions import ApplicationError

from shared import FINAL_PHASES, ChangeTask, Decision, PollRequest

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API = f"https://{os.environ.get('KUBERNETES_SERVICE_HOST', 'localhost')}:{os.environ.get('KUBERNETES_SERVICE_PORT', '443')}"
CRS = f"{API}/apis/approval.safe-ops.io/v1alpha1/namespaces/approvals/changerequests"
WORKFLOW_ANNOTATION = "approval.safe-ops.io/workflow-id"
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "2"))
_ssl = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt") if os.path.exists(f"{SA_DIR}/ca.crt") else None


def log(event, **fields):
    print(json.dumps({"event": event, **fields}), flush=True)


def k8s(method, url, body=None):
    # Re-read the token each call: projected tokens rotate, and the kill
    # switch replaces the service account.
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=_ssl, timeout=10) as r:
        return json.load(r)


def refused(e: urllib.error.HTTPError) -> ApplicationError:
    """A refusal by the API server (RBAC, admission, schema) won't change on
    retry: fail the activity for good, with the server's reason."""
    try:
        msg = json.load(e).get("message", "")
    except Exception:
        msg = ""
    return ApplicationError(f"HTTP {e.code}: {msg}", type="Refused", non_retryable=True)


@activity.defn
def propose(task: ChangeTask) -> str:
    wf = activity.info().workflow_id
    body = {
        "apiVersion": "approval.safe-ops.io/v1alpha1", "kind": "ChangeRequest",
        "metadata": {"name": task.name, "annotations": {WORKFLOW_ANNOTATION: wf}},
        "spec": {"intent": task.intent, "action": task.action, "blastRadius": task.blast_radius,
                 "scope": {"namespaces": task.scope_namespaces, "kinds": [task.action["target"]["kind"]]},
                 "rollback": task.rollback, "approvalWindowSeconds": task.approval_window_seconds},
    }
    try:
        cr = k8s("POST", CRS, body)
        log("proposed", change_request=task.name, workflow=wf, attempt=activity.info().attempt)
        return cr["metadata"]["uid"]
    except urllib.error.HTTPError as e:
        if e.code != 409:
            raise refused(e) if e.code in (400, 403, 422) else e
    # It exists. Ours, from an earlier attempt that crashed before reporting
    # back? Then adopt it. Anyone else's: never act on it.
    cr = k8s("GET", f"{CRS}/{task.name}")
    if cr["metadata"].get("annotations", {}).get(WORKFLOW_ANNOTATION) == wf:
        log("adopted", change_request=task.name, workflow=wf, attempt=activity.info().attempt)
        return cr["metadata"]["uid"]
    raise ApplicationError(f"ChangeRequest {task.name} already exists and wasn't proposed by workflow {wf}",
                           type="NotOurs", non_retryable=True)


def decided_by(status: dict) -> str:
    if status.get("approval"):
        return status["approval"].get("approver", "")
    if status.get("budgetGrant"):
        return "change budget " + status["budgetGrant"].get("budget", "")
    return ""


@activity.defn
def await_decision(req: PollRequest) -> Decision:
    """Poll the ChangeRequest until it's final or the poll window ends,
    heartbeating as it goes."""
    name = req.name
    deadline = time.monotonic() + req.window_seconds
    while True:
        try:
            cr = k8s("GET", f"{CRS}/{name}")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise ApplicationError(f"ChangeRequest {name} was deleted", type="Deleted", non_retryable=True)
            raise
        st = cr.get("status", {})
        d = Decision(phase=st.get("phase", ""), message=st.get("message", ""), decided_by=decided_by(st))
        activity.heartbeat(d.phase)
        if d.phase in FINAL_PHASES or time.monotonic() > deadline:
            return d
        if activity.is_worker_shutdown():
            raise ApplicationError("worker shutting down")  # retried on another worker
        time.sleep(POLL_SECONDS)
