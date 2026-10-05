#!/usr/bin/env bash
# End-to-end test of the agent: one run of the agent Job must claim a
# sandbox, run code under gVisor and release the claim. Then negative
# checks: the agent's RBAC, the claim admission policy, and the agent's
# network egress. Exits non-zero on any failure.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
AS=system:serviceaccount:agent:agent
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

echo "--- agent run"
kubectl delete job -n agent agent-demo --ignore-not-found --wait=true >/dev/null
kubectl apply -f projects/01-sandboxed-code-exec/agent/job.yaml >/dev/null
if kubectl wait -n agent job/agent-demo --for=condition=Complete --timeout=180s >/dev/null 2>&1; then
  pass "agent job completed"
else
  fail "agent job did not complete"
fi
logs=$(kubectl logs -n agent job/agent-demo)
echo "$logs" | sed 's/^/      /'
grep -q '"event": "claimed"' <<<"$logs" && pass "claimed a sandbox" || fail "no claim"
grep -q 'sum: 500000500000' <<<"$logs" && pass "code ran and returned output" || fail "no task output"
grep -q 'kernel: 4.19.0-gvisor' <<<"$logs" && pass "code ran under gVisor" || fail "not under gVisor"
grep -q '"event": "released"' <<<"$logs" && pass "released the claim" || fail "claim not released"
sleep 2
left=$(kubectl get sandboxclaim -n sandboxes -o name | grep 'agent-agent-demo' || true)
[ -z "$left" ] && pass "no leftover claim" || fail "leftover claim: $left"

echo "--- RBAC (as the agent's service account)"
can() { kubectl auth can-i "$@" --as=$AS 2>/dev/null || true; }
expect() { # want, description, can-i args...
  local want=$1 desc=$2; shift 2
  [ "$(can "$@")" = "$want" ] && pass "$desc" || fail "$desc"
}
expect yes "may create sandboxclaims in sandboxes"   create sandboxclaims.extensions.agents.x-k8s.io -n sandboxes
expect yes "may get sandboxes in sandboxes"          get sandboxes.agents.x-k8s.io -n sandboxes
expect no  "may not create Sandboxes directly"       create sandboxes.agents.x-k8s.io -n sandboxes
expect no  "may not update sandboxclaims"            update sandboxclaims.extensions.agents.x-k8s.io -n sandboxes
expect no  "may not list sandboxclaims"              list sandboxclaims.extensions.agents.x-k8s.io -n sandboxes
expect no  "may not claim in another namespace"      create sandboxclaims.extensions.agents.x-k8s.io -n default
expect no  "may not get pods"                        get pods -n sandboxes
expect no  "may not exec into pods"                  create pods/exec -n sandboxes
expect no  "may not read secrets"                    get secrets -n agent

echo "--- claim admission policy (server-side dry run as the agent)"
claim() { # extra-spec-yaml
  cat <<YAML | kubectl create --as=$AS --dry-run=server -f - 2>&1 || true
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: admission-test, namespace: sandboxes}
spec:
$1
YAML
}
out=$(claim "  warmPoolRef: {name: python-gvisor}")
grep -q 'created (server dry run)' <<<"$out" && pass "plain claim allowed" || fail "plain claim rejected: $out"
out=$(claim "  warmPoolRef: {name: python-gvisor-pypi}")
grep -q 'created (server dry run)' <<<"$out" && pass "egress (pypi) pool claim allowed" || fail "pypi pool claim rejected: $out"
for case in \
  "other warm pool|  warmPoolRef: {name: something-else}" \
  "pod labels|  warmPoolRef: {name: python-gvisor}
  additionalPodMetadata: {labels: {app: agent}}" \
  "pod annotations|  warmPoolRef: {name: python-gvisor}
  additionalPodMetadata: {annotations: {x: 'y'}}" \
  "env injection|  warmPoolRef: {name: python-gvisor}
  env: [{name: X, value: 'y'}]"; do
  desc=${case%%|*}; spec=${case#*|}
  out=$(claim "$spec")
  grep -q 'ValidatingAdmissionPolicy' <<<"$out" && pass "denied: $desc" || fail "not denied: $desc: $out"
done

echo "--- agent egress"
SB_IP=$(kubectl get pod -n sandboxes -o jsonpath='{.items[0].status.podIP}')
API_IP=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
DNS_IP=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
kubectl delete pod -n agent egress-test --ignore-not-found --wait=true >/dev/null
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: egress-test, namespace: agent, labels: {app: agent}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: c
    image: python:3.13-slim
    command:
    - python
    - -c
    - |
      import socket
      for name, h, p in [("sandbox executor", "$SB_IP", 8888), ("API server", "$API_IP", 443),
                         ("internet", "1.1.1.1", 443), ("cluster DNS", "$DNS_IP", 53),
                         ("sandbox other port", "$SB_IP", 22)]:
          try:
              socket.create_connection((h, p), timeout=3); print(name, "OPEN")
          except Exception as e:
              print(name, "BLOCKED", type(e).__name__)
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
YAML
kubectl wait -n agent pod/egress-test --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null || true
eg=$(kubectl logs -n agent egress-test)
kubectl delete pod -n agent egress-test --wait=false >/dev/null
for want in "sandbox executor OPEN" "API server OPEN" "internet BLOCKED" "cluster DNS BLOCKED" "sandbox other port BLOCKED"; do
  grep -q "^$want" <<<"$eg" && pass "$want" || fail "$want: got $(grep "^${want% *}" <<<"$eg")"
done

echo "--- claim released on error paths"
# agent_pod NAME CODE: one agent run as a bare pod (the Job's pod template),
# so the test controls its lifetime. Its claim is agent-NAME.
agent_pod() {
  kubectl delete pod -n agent "$1" --ignore-not-found --wait=true >/dev/null
  kubectl create -f projects/01-sandboxed-code-exec/agent/job.yaml --dry-run=client -o json | python3 -c '
import json, sys
name, code = sys.argv[1], sys.argv[2]
t = json.load(sys.stdin)["spec"]["template"]
t["spec"]["containers"][0]["env"] = [{"name": "TASK_CODE", "value": code}, {"name": "TASK_TIMEOUT_S", "value": "55"}]
print(json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": "agent", "labels": t["metadata"]["labels"]}, "spec": t["spec"]}))
' "$1" "$2" | kubectl apply -f - >/dev/null
}
finished() { kubectl wait -n agent pod/"$1" --for=jsonpath='{.status.phase}'="$2" --timeout=120s >/dev/null 2>&1; }
claim_gone() { sleep 2; [ -z "$(kubectl get sandboxclaim -n sandboxes agent-"$1" --ignore-not-found -o name)" ]; }

agent_pod agent-err-raise 'raise RuntimeError("task failed")'
finished agent-err-raise Failed && logs=$(kubectl logs -n agent agent-err-raise) || logs=""
grep -q '"event": "released"' <<<"$logs" && claim_gone agent-err-raise \
  && pass "task code raises: agent exits 1, claim released" || fail "task error: claim not released: ${logs:0:300}"

# The user code SIGKILLs its parent, the executor, mid-request: the agent
# gets a transport error, not a result.
agent_pod agent-err-executor 'import os, time; os.kill(os.getppid(), 9); time.sleep(5)'
finished agent-err-executor Failed && logs=$(kubectl logs -n agent agent-err-executor) || logs=""
grep -q '"event": "error"' <<<"$logs" && grep -q '"event": "released"' <<<"$logs" && claim_gone agent-err-executor \
  && pass "executor dies mid-run: transport error, claim released" || fail "executor death: ${logs:0:300}"

# Pod deleted mid-run: Kubernetes sends SIGTERM. The agent must release and
# exit promptly, not sit out the 30s grace period and leak the claim.
agent_pod agent-err-sigterm 'import time; time.sleep(50)'
for i in $(seq 1 90); do kubectl logs -n agent agent-err-sigterm 2>/dev/null | grep -q '"event": "claimed"' && break; sleep 1; done
backstop=$(kubectl get sandboxclaim -n sandboxes agent-agent-err-sigterm -o jsonpath='{.spec.lifecycle.shutdownTime}' 2>/dev/null)
[ -n "$backstop" ] && pass "agent's claim carries a shutdownTime backstop ($backstop)" || fail "claim has no shutdownTime"
t0=$(date +%s)
kubectl delete pod -n agent agent-err-sigterm --wait=true >/dev/null
took=$(( $(date +%s) - t0 ))
[ "$took" -lt 15 ] && claim_gone agent-err-sigterm \
  && pass "pod deleted mid-run (SIGTERM): claim released, pod gone in ${took}s" \
  || fail "SIGTERM: pod took ${took}s; claim left: $(kubectl get sandboxclaim -n sandboxes agent-agent-err-sigterm --ignore-not-found -o name)"
kubectl delete pod -n agent agent-err-raise agent-err-executor --ignore-not-found --wait=false >/dev/null

echo "--- backstop: a claim whose owner never releases it expires (shutdownTime)"
EXP=expiry-$(date +%s)
kubectl apply -f - >/dev/null <<YAML
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: $EXP, namespace: sandboxes}
spec:
  warmPoolRef: {name: python-gvisor}
  lifecycle: {shutdownTime: "$(date -u -d '+20 seconds' +%Y-%m-%dT%H:%M:%SZ)", shutdownPolicy: Delete}
YAML
kubectl wait -n sandboxes sandboxclaim/$EXP --for=condition=Ready --timeout=120s >/dev/null
SBX=$(kubectl get sandboxclaim -n sandboxes $EXP -o jsonpath='{.status.sandbox.name}')
gone=""
for i in $(seq 1 30); do
  if [ -z "$(kubectl get sandboxclaim -n sandboxes $EXP --ignore-not-found -o name)" ] && \
     [ -z "$(kubectl get sandbox -n sandboxes "$SBX" --ignore-not-found -o name)" ]; then gone=yes; break; fi
  sleep 5
done
[ -n "$gone" ] && pass "claim and its sandbox deleted after shutdownTime (+20s)" \
  || { fail "claim $EXP or sandbox $SBX still exists 170s after claiming"; kubectl delete sandboxclaim -n sandboxes $EXP --wait=false >/dev/null 2>&1; }

exit $FAILED
