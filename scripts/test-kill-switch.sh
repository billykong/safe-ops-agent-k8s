#!/usr/bin/env bash
# P2 milestone 4: the kill switch (P2-21) and its runbook (P2-22). Sets up
# an agent mid-task (a Job holding a sandbox), a pending proposal, an
# eligible change under a change budget, and a copy of the agent's token
# taken out of the cluster. Then one command stops it all, and the test
# checks each layer: admission, scale to zero, credential revocation,
# sandbox release, cancelled proposals. Then fail-closed behaviour, and the
# runbook's resume. Exits non-zero on any failure; always leaves the switch
# on "run".
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
AGENT=system:serviceaccount:agent:agent
CTRL=system:serviceaccount:approval-system:approval-controller
CLI=projects/02-approval-gate/bin/approvalctl
NS=approvals
T=$(date +%s)
APPROVER=approver-kill-$T
JOB=agent-killtest
TMP=$(mktemp -d)
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:250}"; fi; }
killed() { check "$1" 'agent-kill-switch' "$2"; }
[ -x $CLI ] || { echo "build the CLI first: make p2"; exit 1; }

replicas() { kubectl get deploy -n workloads web -o jsonpath='{.spec.replicas}'; }
st() { kubectl get changerequest -n $NS "$1" -o jsonpath="$2"; }
phase() { st "$1" '{.status.phase}'; }
wait_phase() { for _ in $(seq 1 30); do grep -qE "^($2)$" <<<"$(phase "$1")" && return 0; sleep 1; done; return 1; }
cr() { # NAME TYPE [REPLICAS]
  local rep=""; [ -n "${3:-}" ] && rep=", replicas: $3"
  cat <<YAML
apiVersion: approval.safe-ops.io/v1alpha1
kind: ChangeRequest
metadata: {name: $1, namespace: $NS}
spec:
  intent: "test $1"
  action: {type: $2, target: {kind: Deployment, namespace: workloads, name: web}$rep}
  blastRadius: "workloads/web"
  scope: {namespaces: [workloads], kinds: [Deployment]}
  rollback: "apply rollbackPlan"
YAML
}
claim() { cat <<YAML
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: agent-killtest-probe, namespace: sandboxes}
spec: {warmPoolRef: {name: python-gvisor}}
YAML
}
pod() { cat <<YAML
apiVersion: v1
kind: Pod
metadata: {name: killtest-probe, namespace: ${1:-agent}}
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
  - {name: c, image: python:3.13-slim, securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}}
YAML
}
# A kubeconfig holding only a bearer token, as an attacker would use it.
token_kubeconfig() { # TOKEN FILE
  local server ca
  server=$(kubectl config view --raw --minify --context "$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.server}')
  ca=$(kubectl config view --raw --minify --context "$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  cat >"$2" <<YAML
apiVersion: v1
kind: Config
clusters: [{name: c, cluster: {server: "$server", certificate-authority-data: "$ca"}}]
users: [{name: u, user: {token: "$1"}}]
contexts: [{name: c, context: {cluster: c, user: u}}]
current-context: c
YAML
}
with_token() { KUBECONFIG=$1 command kubectl "${@:2}" 2>&1 || true; }
actl() { KUBECONFIG=$TMP/approver.kubeconfig $CLI "$@"; }
mode() { kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}' 2>/dev/null || echo missing; }

cleanup() {
  [ "$(mode)" = run ] || ./scripts/kill-switch.sh resume --reason "test-kill-switch cleanup" >/dev/null 2>&1 || true
  kubectl delete job -n agent $JOB --ignore-not-found --wait=false >/dev/null 2>&1 || true
  # The runbook's deliberate restart, for the Temporal worker (if installed).
  kubectl scale deploy -n agent agent-worker --replicas=1 >/dev/null 2>&1 || true
  kubectl delete changebudget -n $NS default --ignore-not-found >/dev/null 2>&1 || true
  for n in $(kubectl get changerequest -n $NS -o name 2>/dev/null | grep -- "-$T\$"); do kubectl delete -n $NS "$n" --wait=false >/dev/null 2>&1; done
  kubectl scale deploy -n workloads web --replicas=1 >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
[ "$(mode)" = run ] || { echo "the kill switch is already engaged: scripts/kill-switch.sh status"; exit 1; }
kubectl scale deploy -n workloads web --replicas=1 >/dev/null
./scripts/new-approver.sh $APPROVER $TMP/approver.kubeconfig 1 >/dev/null

echo "--- before: an agent mid-task, a pending proposal, a stolen token"
kubectl delete job -n agent $JOB --ignore-not-found --wait=true >/dev/null
kubectl create -f projects/01-sandboxed-code-exec/agent/job.yaml --dry-run=client -o json | python3 -c '
import json, sys
j = json.load(sys.stdin)
j["metadata"]["name"] = sys.argv[1]
j["spec"]["template"]["spec"]["containers"][0]["env"] = [
  {"name": "TASK_CODE", "value": "import time; time.sleep(600)"}, {"name": "TASK_TIMEOUT_S", "value": "600"}]
print(json.dumps(j))' $JOB | kubectl apply -f - >/dev/null
for _ in $(seq 1 60); do
  POD=$(kubectl get pod -n agent -l job-name=$JOB -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$POD" ] && kubectl get sandboxclaim -n sandboxes "agent-$POD" >/dev/null 2>&1 && break; sleep 1
done
[ -n "$POD" ] && kubectl get sandboxclaim -n sandboxes "agent-$POD" >/dev/null 2>&1 \
  && pass "agent job running, holding sandbox claim agent-$POD" || fail "agent didn't start or claim a sandbox"
cr pending-$T ScaleDeployment 2 | kubectl create --as=$AGENT -f - >/dev/null
wait_phase pending-$T Pending && pass "agent's proposal pending-$T is Pending" || fail "pending-$T: $(phase pending-$T)"
kubectl apply -f projects/02-approval-gate/examples/change-budget.yaml >/dev/null
STOLEN=$(kubectl create token agent -n agent --duration=1h)
token_kubeconfig "$STOLEN" $TMP/stolen.kubeconfig
out=$(with_token $TMP/stolen.kubeconfig get changerequests -n $NS -o name)
check "stolen token works before the switch (reads proposals)" "pending-$T" "$out"
OLD_UID=$(kubectl get sa -n agent agent -o jsonpath='{.metadata.uid}')

echo "--- one action: kill-switch.sh stop"
out=$(./scripts/kill-switch.sh stop --reason "test-kill-switch $T" 2>&1) || fail "kill-switch.sh stop failed: $out"
echo "$out" | sed 's/^/      /'
[ "$(mode)" = stop ] && pass "flag says stop" || fail "flag: $(mode)"
grep -q "test-kill-switch $T" <<<"$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.reason}')" \
  && pass "reason and operator recorded on the flag" || fail "reason not recorded"

echo "--- admission: the agent can't act"
killed "agent can't propose a change" "$(cr probe-$T RestartDeployment | kubectl create --as=$AGENT --dry-run=server -f - 2>&1 || true)"
killed "agent can't claim a sandbox" "$(claim | kubectl create --as=$AGENT --dry-run=server -f - 2>&1 || true)"
killed "nobody can start a pod in the agent namespace (cluster admin tried)" "$(pod | kubectl create --dry-run=server -f - 2>&1 || true)"
killed "nobody can mint a token for the agent (cluster admin tried)" "$(kubectl create token agent -n agent 2>&1 || true)"
out=$(pod sandboxes | kubectl create --dry-run=server -f - 2>&1 || true)
grep -q 'agent-kill-switch' <<<"$out" && fail "pods outside the agent namespace blocked: $out" || pass "pods elsewhere unaffected (sandboxes)"
out=$(cr human-$T RestartDeployment | kubectl create -f - 2>&1 || true)
check "a human can still create a proposal" 'created' "$out"

echo "--- scaled to zero, and it stays there"
[ "$(kubectl get job -n agent $JOB -o jsonpath='{.spec.suspend}')" = true ] && pass "agent job suspended" || fail "job not suspended"
n=$(kubectl get pods -n agent --no-headers 2>/dev/null | wc -l)
[ "$n" = 0 ] && pass "no agent pods" || fail "$n agent pods left"
kubectl patch job -n agent $JOB --type=merge -p '{"spec":{"suspend":false}}' >/dev/null
sleep 8
n=$(kubectl get pods -n agent --no-headers 2>/dev/null | wc -l)
ev=$(kubectl get events -n agent --field-selector involvedObject.name=$JOB,reason=FailedCreate -o jsonpath='{.items[*].message}')
[ "$n" = 0 ] && grep -q agent-kill-switch <<<"$ev" && pass "un-suspending the job brings back no pods (FailedCreate: agent-kill-switch)" \
  || fail "after un-suspend: $n pods; events: ${ev:0:200}"
kubectl patch job -n agent $JOB --type=merge -p '{"spec":{"suspend":true}}' >/dev/null

echo "--- credentials revoked, reads included"
NEW_UID=$(kubectl get sa -n agent agent -o jsonpath='{.metadata.uid}')
[ -n "$NEW_UID" ] && [ "$NEW_UID" != "$OLD_UID" ] && pass "agent ServiceAccount recreated (new uid)" || fail "SA uid $OLD_UID -> $NEW_UID"
out=$(with_token $TMP/stolen.kubeconfig get changerequests -n $NS -o name)
check "stolen token refused, even for reads" 'Unauthorized|must be logged in' "$out"

echo "--- in-flight work cancelled"
for _ in $(seq 1 30); do kubectl get sandboxclaim -n sandboxes "agent-$POD" >/dev/null 2>&1 || break; sleep 1; done
kubectl get sandboxclaim -n sandboxes "agent-$POD" >/dev/null 2>&1 && fail "claim agent-$POD still held" || pass "agent's sandbox claim released"
wait_phase pending-$T Cancelled && check "pending proposal Cancelled, with the reason" 'kill switch engaged.*test-kill-switch' "$(st pending-$T '{.status.message}')" \
  || fail "pending-$T: $(phase pending-$T)"
wait_phase human-$T Cancelled && pass "a proposal made while stopped is cancelled, not applied, despite the change budget" \
  || fail "human-$T: $(phase human-$T) $(st human-$T '{.status.message}')"
H=$(st pending-$T '{.status.reviewHash}')
KUBECONFIG=$TMP/approver.kubeconfig command kubectl patch changerequest -n $NS pending-$T --subresource=status --type=merge \
  -p "{\"status\":{\"approval\":{\"decision\":\"Approved\",\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"reviewHash\":\"$H\"}}}" >/dev/null 2>&1 || true
sleep 3
[ "$(phase pending-$T)" = Cancelled ] && [ "$(replicas)" = 1 ] && pass "approving a cancelled proposal applies nothing" \
  || fail "after approval: $(phase pending-$T), web has $(replicas) replicas"

echo "--- who can touch the switch"
can() { kubectl auth can-i "$@" 2>/dev/null || true; }
for v in update patch delete; do
  [ "$(can $v configmaps/agent-kill-switch -n approval-system --as=$AGENT)" = no ] && pass "agent may not $v the switch" || fail "agent MAY $v the switch"
done
[ "$(can patch configmaps/agent-kill-switch -n approval-system --as=$APPROVER --as-group=safe-ops:approvers)" = no ] \
  && pass "approvers may not flip the switch" || fail "approvers MAY flip the switch"
[ "$(can patch configmaps/agent-kill-switch -n approval-system --as=$CTRL)" = no ] && [ "$(can get configmaps -n approval-system --as=$CTRL)" = yes ] \
  && pass "the controller may read the switch, not flip it" || fail "controller's access to the switch is wrong"
[ "$(can get configmaps -n agent --as=$CTRL)" = no ] && pass "the controller reads ConfigMaps only in its own namespace" || fail "controller reads ConfigMaps elsewhere"
[ "$(can delete validatingadmissionpolicybindings.admissionregistration.k8s.io --as=$AGENT)" = no ] \
  && pass "agent may not remove the switch's policy bindings (GAP-02)" || fail "agent MAY remove the switch's bindings"

echo "--- runbook: resume"
out=$(./scripts/kill-switch.sh resume --reason "test-kill-switch $T resume" 2>&1) || fail "resume failed: $out"
[ "$(mode)" = run ] && pass "flag says run" || fail "flag: $(mode)"
out=$(cr probe-$T RestartDeployment | kubectl create --as=$AGENT --dry-run=server -f - 2>&1 || true)
check "agent can propose again" 'created \(server dry run\)' "$out"
out=$(claim | kubectl create --as=$AGENT --dry-run=server -f - 2>&1 || true)
check "agent can claim a sandbox again" 'created \(server dry run\)' "$out"
NEWTOK=$(kubectl create token agent -n agent --duration=10m 2>&1 || true)
token_kubeconfig "$NEWTOK" $TMP/new.kubeconfig
check "a new token works" "changerequest" "$(with_token $TMP/new.kubeconfig get changerequests -n $NS -o name)"
check "the stolen token stays dead" 'Unauthorized|must be logged in' "$(with_token $TMP/stolen.kubeconfig get changerequests -n $NS -o name)"
[ "$(kubectl get job -n agent $JOB -o jsonpath='{.spec.suspend}')" = true ] && [ "$(kubectl get pods -n agent --no-headers 2>/dev/null | wc -l)" = 0 ] \
  && pass "resume doesn't restart the agent: its job stays suspended" || fail "agent restarted on resume"
[ "$(phase pending-$T)" = Cancelled ] && pass "cancelled proposals stay cancelled" || fail "pending-$T: $(phase pending-$T)"

echo "--- fail closed: a missing or garbled flag stops the agent"
kubectl delete configmap -n approval-system agent-kill-switch >/dev/null
sleep 2
out=$(cr probe-$T RestartDeployment | kubectl create --as=$AGENT --dry-run=server -f - 2>&1 || true)
check "flag deleted: agent can't propose" 'no params found|agent-kill-switch' "$out"
out=$(pod | kubectl create --dry-run=server -f - 2>&1 || true)
check "flag deleted: no pods in the agent namespace" 'no params found|agent-kill-switch' "$out"
out=$(kubectl create configmap killtest-probe -n agent --dry-run=server 2>&1 || true)
check "flag deleted: the rest of the cluster is unaffected" 'created \(server dry run\)' "$out"
out=$(pod sandboxes | kubectl create --dry-run=server -f - 2>&1 || true)
check "flag deleted: pods outside the agent namespace unaffected" 'created \(server dry run\)' "$out"
cr missing-$T RestartDeployment > $TMP/missing.yaml
out=$(kubectl create -f $TMP/missing.yaml 2>&1 || true)
check "flag deleted: proposals frozen for everyone (the fail-closed denial ignores matchConditions)" 'no params found' "$out"
kubectl create configmap -n approval-system agent-kill-switch --from-literal=mode=yes --from-literal=reason="garbled" >/dev/null
sleep 2
killed "flag garbled (mode=yes): agent can't propose" "$(cr probe-$T RestartDeployment | kubectl create --as=$AGENT --dry-run=server -f - 2>&1 || true)"
kubectl create -f $TMP/missing.yaml >/dev/null
wait_phase missing-$T Cancelled && pass "flag garbled: controller cancels proposals" || fail "missing-$T: $(phase missing-$T)"
./scripts/kill-switch.sh resume --reason "test-kill-switch $T restore" >/dev/null
[ "$(mode)" = run ] && pass "flag restored to run" || fail "flag: $(mode)"

exit $FAILED
