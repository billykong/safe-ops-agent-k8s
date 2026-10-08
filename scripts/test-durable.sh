#!/usr/bin/env bash
# P2 milestone 5: durable execution across long approvals (P2-30, P2-31).
# The agent is a Temporal worker; each task is a ChangeWorkflow that
# proposes a ChangeRequest and waits for its decision. Checks that the wait
# survives the worker and the Temporal server being restarted mid-approval,
# and the worker being down for the approval itself, without losing state
# or proposing twice; that a long wait keeps a bounded history; every
# outcome; idempotent proposals; Temporal's network fence; and that the kill
# switch terminates in-flight workflows. Needs `make p2 durable`. Exits
# non-zero on any failure.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
AGENT=system:serviceaccount:agent:proposer
CLI=projects/02-approval-gate/bin/approvalctl
NS=approvals
T=$(date +%s)
APPROVER=approver-durable-$T
TMP=$(mktemp -d)
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:300}"; fi; }
[ -x $CLI ] || { echo "build the CLI first: make p2"; exit 1; }

tctl() { kubectl exec -n temporal deploy/temporal -- temporal "$@"; }
# start NAME TYPE [REPLICAS] [EXTRA-JSON-FIELDS]: give the agent a task
start() {
  local rep=""; [ -n "${3:-}" ] && rep=",\"replicas\":$3"
  tctl workflow start --task-queue agent --type ChangeWorkflow --workflow-id "$1" --input \
    "{\"name\":\"$1\",\"intent\":\"test $1\",\"action\":{\"type\":\"$2\",\"target\":{\"kind\":\"Deployment\",\"namespace\":\"workloads\",\"name\":\"web\"}$rep},\"blast_radius\":\"workloads/web\",\"rollback\":\"apply rollbackPlan\"${4:-}}" 2>&1
}
wf_status() { tctl workflow describe --workflow-id "$1" -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["workflowExecutionInfo"]["status"])' 2>/dev/null || echo unknown; }
wait_wf() { for _ in $(seq 1 ${3:-60}); do [ "$(wf_status "$1")" = "$2" ] && return 0; sleep 1; done; return 1; }
result() { tctl workflow result --workflow-id "$1" -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result") or d; print(json.dumps(r))' 2>/dev/null || echo '{}'; }
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$1" "$2"; }
state() { tctl workflow query --workflow-id "$1" --type state -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("queryResult", d))' 2>/dev/null || echo "?"; }
# Count activity schedules of a type across a workflow's runs.
scheduled() {
  local total=0 n
  for run in $(tctl workflow list --query "WorkflowId='$1'" -o json 2>/dev/null | python3 -c 'import json,sys; [print(w["execution"]["runId"]) for w in json.load(sys.stdin) or []]'); do
    n=$(tctl workflow show --workflow-id "$1" --run-id "$run" -o json 2>/dev/null | python3 -c '
import json, sys
ev = json.load(sys.stdin)["events"]
print(sum(1 for e in ev if e["eventType"] == "EVENT_TYPE_ACTIVITY_TASK_SCHEDULED"
          and e["activityTaskScheduledEventAttributes"]["activityType"]["name"] == sys.argv[1]))' "$2")
    total=$((total + n))
  done
  echo $total
}
phase() { kubectl get changerequest -n $NS "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
wait_phase() { for _ in $(seq 1 30); do grep -qE "^($2)$" <<<"$(phase "$1")" && return 0; sleep 1; done; return 1; }
replicas() { kubectl get deploy -n workloads web -o jsonpath='{.spec.replicas}'; }
actl() { KUBECONFIG=$TMP/approver.kubeconfig $CLI "$@"; }
worker_ready() { kubectl rollout status -n agent deploy/agent-worker --timeout=120s >/dev/null 2>&1; }
temporal_ready() { kubectl rollout status -n temporal deploy/temporal --timeout=180s >/dev/null 2>&1; }

cleanup() {
  [ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}' 2>/dev/null)" = run ] \
    || ./scripts/kill-switch.sh resume --reason "test-durable cleanup" >/dev/null 2>&1 || true
  kubectl scale deploy -n agent agent-worker --replicas=1 >/dev/null 2>&1 || true
  for w in $(tctl workflow list --query "ExecutionStatus='Running'" -o json 2>/dev/null | python3 -c 'import json,sys; [print(w["execution"]["workflowId"]) for w in json.load(sys.stdin) or []]' | grep -- "-$T\$"); do
    tctl workflow terminate --workflow-id "$w" --reason "test cleanup" >/dev/null 2>&1 || true
  done
  for n in $(kubectl get changerequest -n $NS -o name 2>/dev/null | grep -- "-$T\$"); do kubectl delete -n $NS "$n" --wait=false >/dev/null 2>&1; done
  kubectl scale deploy -n workloads web --replicas=1 >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status"; exit 1; }
kubectl delete changebudget -n $NS default --ignore-not-found >/dev/null
kubectl scale deploy -n workloads web --replicas=1 >/dev/null
./scripts/new-approver.sh $APPROVER $TMP/approver.kubeconfig 1 >/dev/null

echo "--- setup"
kubectl scale deploy -n agent agent-worker --replicas=1 >/dev/null
temporal_ready && pass "Temporal server ready" || fail "Temporal not ready"
worker_ready && pass "agent worker ready" || fail "agent worker not ready"
for _ in $(seq 1 30); do
  pollers=$(tctl task-queue describe --task-queue agent -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("pollers") or d.get("versionsInfo", [{}])[0].get("pollers", []) if isinstance(d, dict) else 0))' 2>/dev/null || echo 0)
  [ "${pollers:-0}" -gt 0 ] && break; sleep 1
done
[ "${pollers:-0}" -gt 0 ] && pass "worker is polling task queue agent" || fail "no pollers on task queue agent"

echo "--- Temporal's network fence (its frontend has no auth: GAP-03)"
SVC=$(kubectl get svc -n temporal temporal -o jsonpath='{.spec.clusterIP}')
probe_pod() { # NAMESPACE NAME -> "OPEN" or "BLOCKED"
  kubectl run "$2" -n "$1" --image=python:3.13-slim --restart=Never --quiet \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"p","image":"python:3.13-slim","command":["python","-c","import socket,sys\ntry:\n socket.create_connection((sys.argv[1],7233),timeout=3); print(\"OPEN\")\nexcept Exception: print(\"BLOCKED\")","'"$SVC"'"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
  kubectl wait -n "$1" pod/"$2" --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s >/dev/null 2>&1 || true
  kubectl logs -n "$1" "$2" 2>/dev/null || echo "no output"
  kubectl delete pod -n "$1" "$2" --wait=false >/dev/null 2>&1
}
check "an agent pod that isn't the worker can't reach Temporal" '^BLOCKED' "$(probe_pod agent durable-probe-$T)"
check "a pod in another namespace can't reach Temporal" '^BLOCKED' "$(probe_pod workloads durable-probe-$T)"
check "a sandbox can't reach Temporal" '^BLOCKED' "$(kubectl exec -n sandboxes "$(kubectl get pod -n sandboxes -l agents.x-k8s.io/sandbox-name -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || kubectl get pod -n sandboxes -o jsonpath='{.items[0].metadata.name}')" -- python3 -c "
import socket
try:
    socket.create_connection(('$SVC', 7233), timeout=3); print('OPEN')
except Exception:
    print('BLOCKED')" 2>&1 || true)"

echo "--- P2-31: worker and Temporal server restarted mid-approval, nothing lost"
W=restart-$T
out=$(start $W ScaleDeployment 2)
check "task started as workflow $W" 'Running|WorkflowId' "$out"
wait_phase $W Pending && pass "agent proposed $W: Pending" || fail "$W not proposed: $(phase $W)"
check "workflow is waiting for the decision" 'waiting for a decision' "$(state $W)"
OLD_WORKER=$(kubectl get pod -n agent -l app=agent-worker -o jsonpath='{.items[0].metadata.name}')
OLD_SERVER=$(kubectl get pod -n temporal -l app=temporal -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n agent "$OLD_WORKER" --wait=true >/dev/null
kubectl delete pod -n temporal "$OLD_SERVER" --wait=true >/dev/null
temporal_ready && worker_ready && pass "worker and Temporal server pods deleted and replaced" || fail "pods didn't come back"
[ "$(wf_status $W)" = WORKFLOW_EXECUTION_STATUS_RUNNING ] && pass "the workflow is still running after both restarts" || fail "after restarts: $(wf_status $W)"
check "and still waiting for the decision (state rebuilt by replay)" 'waiting for a decision' "$(state $W)"
actl approve $W --yes --wait 0s >/dev/null
wait_wf $W WORKFLOW_EXECUTION_STATUS_COMPLETED 90 && pass "approved: the workflow completed" || fail "after approval: $(wf_status $W)"
R=$(result $W)
[ "$(field "$R" phase)" = Applied ] && [ "$(field "$R" decided_by)" = "$APPROVER" ] \
  && pass "outcome: Applied, decided by $APPROVER" || fail "outcome: $R"
[ "$(replicas)" = 2 ] && pass "web scaled to 2" || fail "web has $(replicas) replicas"
[ "$(scheduled $W propose)" = 1 ] && pass "proposed exactly once" || fail "propose scheduled $(scheduled $W propose) times"
n=$(kubectl get changerequest -n $NS -o name | grep -c "/$W\$" || true)
[ "$n" = 1 ] && pass "one ChangeRequest for the task" || fail "$n ChangeRequests for $W"

echo "--- no agent running at all while the human decides"
W=offline-$T
start $W RestartDeployment >/dev/null
wait_phase $W Pending && pass "$W proposed" || fail "$W: $(phase $W)"
kubectl scale deploy -n agent agent-worker --replicas=0 >/dev/null
kubectl wait -n agent --for=delete pod -l app=agent-worker --timeout=60s >/dev/null 2>&1 || true
actl approve $W --yes --wait 20s >/dev/null
[ "$(phase $W)" = Applied ] && pass "approved and applied by the controller while no agent runs" || fail "$W: $(phase $W)"
sleep 3
[ "$(wf_status $W)" = WORKFLOW_EXECUTION_STATUS_RUNNING ] && pass "the workflow waits, durably, with no worker" || fail "$W: $(wf_status $W)"
kubectl scale deploy -n agent agent-worker --replicas=1 >/dev/null
worker_ready
wait_wf $W WORKFLOW_EXECUTION_STATUS_COMPLETED 90 && check "worker back: the workflow picks up the outcome" '"phase": "Applied"' "$(result $W)" \
  || fail "$W after worker returned: $(wf_status $W)"

echo "--- a long wait keeps a bounded history (continue-as-new)"
W=long-$T
start $W RestartDeployment "" ',"poll_window_seconds":2,"polls_per_run":2' >/dev/null
wait_phase $W Pending || true
sleep 15
runs=$(tctl workflow list --query "WorkflowId='$W'" -o json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin) or []))')
[ "${runs:-0}" -ge 3 ] && pass "waiting rolled over into $runs runs (2 polls each)" || fail "only ${runs:-0} runs"
actl approve $W --yes --wait 0s >/dev/null
wait_wf $W WORKFLOW_EXECUTION_STATUS_COMPLETED 60 && R=$(result $W) || R='{}'
[ "$(field "$R" phase)" = Applied ] && [ "$(field "$R" runs)" -ge 3 ] && [ "$(field "$R" polls)" -ge 5 ] \
  && pass "outcome carried across runs: Applied after $(field "$R" polls) polls in $(field "$R" runs) runs" || fail "long wait outcome: $R"
[ "$(scheduled $W propose)" = 1 ] && pass "still proposed exactly once across all runs" || fail "propose scheduled $(scheduled $W propose) times"

echo "--- every outcome reaches the workflow"
W=reject-$T
start $W RestartDeployment >/dev/null; wait_phase $W Pending || true
actl reject $W --yes --wait 0s >/dev/null
wait_wf $W WORKFLOW_EXECUTION_STATUS_COMPLETED && check "rejected" '"phase": "Rejected"' "$(result $W)" || fail "$W: $(wf_status $W)"
W=expire-$T
start $W RestartDeployment "" ',"approval_window_seconds":10' >/dev/null
wait_wf $W WORKFLOW_EXECUTION_STATUS_COMPLETED 60 && check "expired after its 10 s window" '"phase": "Expired"' "$(result $W)" || fail "$W: $(wf_status $W)"
W=scope-$T
start $W ScaleDeployment 2 ',"scope_namespaces":["elsewhere"]' >/dev/null
wait_wf $W WORKFLOW_EXECUTION_STATUS_COMPLETED && check "out of scope: rejected by the controller" 'outside the declared scope.*"phase": "Rejected"' "$(result $W)" \
  || fail "$W: $(wf_status $W)"

echo "--- proposals are idempotent and never hijack someone else's"
W=dup-$T
start $W RestartDeployment >/dev/null
start $W RestartDeployment >/dev/null 2>&1 || true
runs=$(tctl workflow list --query "WorkflowId='$W'" -o json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin) or []))')
sleep 3
n=$(kubectl get changerequest -n $NS -o name | grep -c "/$W\$" || true)
[ "$runs" = 1 ] && [ "$n" = 1 ] && pass "starting the same task twice gives one run and one proposal" || fail "$W: $runs runs, $n ChangeRequests"
cr_yaml() { # NAME [ANNOTATION-VALUE]
  local ann=""; [ -n "${2:-}" ] && ann="annotations: {approval.safe-ops.io/workflow-id: $2}"
  cat <<YAML
apiVersion: approval.safe-ops.io/v1alpha1
kind: ChangeRequest
metadata:
  name: $1
  namespace: $NS
  $ann
spec:
  intent: "pre-existing $1"
  action: {type: RestartDeployment, target: {kind: Deployment, namespace: workloads, name: web}}
  blastRadius: "workloads/web"
  scope: {namespaces: [workloads], kinds: [Deployment]}
  rollback: "apply rollbackPlan"
YAML
}
W=adopt-$T
cr_yaml $W $W | kubectl create --as=$AGENT -f - >/dev/null   # as if an earlier attempt created it and crashed
start $W RestartDeployment >/dev/null
sleep 4
check "a ChangeRequest from an earlier attempt of the same workflow is adopted" 'waiting for a decision' "$(state $W)"
W=notours-$T
cr_yaml $W | kubectl create --as=$AGENT -f - >/dev/null
start $W RestartDeployment >/dev/null
wait_wf $W WORKFLOW_EXECUTION_STATUS_FAILED 30 && pass "a same-named ChangeRequest from elsewhere fails the workflow, not adopted" \
  || fail "$W: $(wf_status $W)"

echo "--- kill switch terminates in-flight workflows"
W=kill-$T
start $W RestartDeployment >/dev/null
wait_phase $W Pending && pass "$W waiting for approval" || fail "$W: $(phase $W)"
out=$(./scripts/kill-switch.sh stop --reason "test-durable $T" 2>&1) || fail "kill switch: $out"
check "kill switch reports terminated workflows" 'in-flight workflows terminated: [1-9]' "$out"
[ "$(wf_status $W)" = WORKFLOW_EXECUTION_STATUS_TERMINATED ] && pass "workflow terminated" || fail "$W: $(wf_status $W)"
running=$(tctl workflow list --query "ExecutionStatus='Running'" -o json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin) or []))')
[ "$running" = 0 ] && pass "no workflow left running" || fail "$running workflows still running"
wait_phase $W Cancelled && pass "its ChangeRequest cancelled" || fail "$W: $(phase $W)"
[ "$(kubectl get deploy -n agent agent-worker -o jsonpath='{.spec.replicas}')" = 0 ] && pass "worker scaled to zero" || fail "worker not scaled down"
temporal_ready && pass "Temporal itself keeps running (the record stays readable)" || fail "Temporal down"
./scripts/kill-switch.sh resume --reason "test-durable $T resume" >/dev/null
[ "$(kubectl get deploy -n agent agent-worker -o jsonpath='{.spec.replicas}')" = 0 ] && pass "resume doesn't restart the worker" || fail "worker restarted on resume"
kubectl scale deploy -n agent agent-worker --replicas=1 >/dev/null
worker_ready && pass "worker restarted deliberately" || fail "worker didn't come back"
W=after-$T
start $W RestartDeployment >/dev/null
wait_phase $W Pending && pass "the restarted worker (new service account token) proposes again" || fail "$W: $(phase $W)"
actl reject $W --yes --wait 0s >/dev/null
wait_wf $W WORKFLOW_EXECUTION_STATUS_COMPLETED || fail "$W: $(wf_status $W)"

exit $FAILED
