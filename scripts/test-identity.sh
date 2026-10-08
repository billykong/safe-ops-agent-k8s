#!/usr/bin/env bash
# P3 milestone 1: per-agent workload identity (P3-01). Each agent has its
# own service account and only its own job's RBAC; agents authenticate to
# the gateway with projected tokens minted for its audience and bound to
# their pod. Checks the split, the tokens' properties, every way the gateway
# must refuse, the network fence, and revocation by pod deletion and by the
# kill switch. Needs `make p3` (and P1, P2). Exits non-zero on any failure.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
RUNNER=system:serviceaccount:agent:runner
PROPOSER=system:serviceaccount:agent:proposer
AUD=llm-gateway.safe-ops.io
TOKEN_PATH=/var/run/secrets/safe-ops.io/llm-gateway/token
T=$(date +%s)
TMP=$(mktemp -d)
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:300}"; fi; }
can() { kubectl auth can-i "$@" 2>/dev/null || true; }

# probe NAME SERVICEACCOUNT: a long-running pod with the agent pod template
# (the runner Job's), so it gets the same token volumes.
probe() {
  kubectl create -f projects/01-sandboxed-code-exec/agent/job.yaml --dry-run=client -o json | python3 -c '
import json, sys
name, sa = sys.argv[1], sys.argv[2]
t = json.load(sys.stdin)["spec"]["template"]
t["spec"]["serviceAccountName"] = sa
t["spec"]["restartPolicy"] = "Never"
c = t["spec"]["containers"][0]
c["command"] = ["python", "-c", "import time; time.sleep(600)"]
c["env"] = [e for e in c["env"] if e["name"] != "TASK_CODE"]
print(json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": "agent", "labels": t["metadata"]["labels"]}, "spec": t["spec"]}))
' "$1" "$2" | kubectl apply -f - >/dev/null
  kubectl wait -n agent pod/"$1" --for=condition=Ready --timeout=90s >/dev/null
}
token_of() { kubectl exec -n agent "$1" -- cat "${2:-$TOKEN_PATH}"; }
claims() { # JWT payload as JSON
  python3 -c 'import base64, json, sys; p = sys.argv[1].split(".")[1]; print(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)).decode())' "$1"
}
# The gateway through a port-forward: identity is what it checks, not the
# source address (the network fence is checked separately).
forward() {
  kill "${PF:-}" 2>/dev/null || true
  command kubectl --context "$KUBE_CONTEXT" port-forward -n gateways svc/llm-gateway 18081:8080 >/dev/null 2>&1 & PF=$!
  for _ in $(seq 1 20); do curl -sf -o /dev/null localhost:18081/healthz 2>/dev/null && return 0; sleep 0.5; done
}
whoami() { # TOKEN -> "HTTP-CODE BODY"
  local h=()
  [ -n "$1" ] && h=(-H "Authorization: Bearer $1")
  curl -s -o $TMP/body -w '%{http_code}' "${h[@]}" localhost:18081/whoami; echo " $(cat $TMP/body)"
}
api_with() { # TOKEN: the API server's answer to a request carrying it
  local server ca
  server=$(kubectl config view --raw --minify --context "$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.server}')
  kubectl config view --raw --minify --context "$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > $TMP/ca.crt
  curl -s --cacert $TMP/ca.crt -H "Authorization: Bearer $1" -o /dev/null -w '%{http_code}' "$server/apis/approval.safe-ops.io/v1alpha1/namespaces/approvals/changerequests"
}

cleanup() {
  kill "${PF:-}" 2>/dev/null || true
  [ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}' 2>/dev/null)" = run ] \
    || ./scripts/kill-switch.sh resume --reason "test-identity cleanup" >/dev/null 2>&1 || true
  kubectl scale deploy -n agent agent-worker --replicas=1 >/dev/null 2>&1 || true
  kubectl delete pod -n agent id-runner-$T id-default-$T --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete pod -n workloads id-outside-$T --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status"; exit 1; }
kubectl rollout status -n gateways deploy/llm-gateway --timeout=60s >/dev/null

echo "--- one identity per agent, each with only its own job (P3-01, P3-05)"
[ -z "$(kubectl get sa -n agent agent --ignore-not-found -o name)" ] && pass "the shared agent/agent identity is gone" || fail "agent/agent still exists"
[ "$(can create sandboxclaims.extensions.agents.x-k8s.io -n sandboxes --as=$RUNNER)" = yes ] && pass "runner may claim sandboxes" || fail "runner can't claim"
[ "$(can create changerequests.approval.safe-ops.io -n approvals --as=$RUNNER)" = no ] && pass "runner may not propose changes" || fail "runner MAY propose"
[ "$(can create changerequests.approval.safe-ops.io -n approvals --as=$PROPOSER)" = yes ] && pass "proposer may propose changes" || fail "proposer can't propose"
[ "$(can create sandboxclaims.extensions.agents.x-k8s.io -n sandboxes --as=$PROPOSER)" = no ] && pass "proposer may not claim sandboxes" || fail "proposer MAY claim"
for v in "create sandboxclaims.extensions.agents.x-k8s.io -n sandboxes" "create changerequests.approval.safe-ops.io -n approvals"; do
  # shellcheck disable=SC2086
  [ "$(can $v --as=system:serviceaccount:agent:default)" = no ] && pass "agent/default (no job) may not: $v" || fail "agent/default MAY $v"
done
[ "$(kubectl get deploy -n agent agent-worker -o jsonpath='{.spec.template.spec.serviceAccountName}')" = proposer ] && pass "the Temporal worker runs as proposer" || fail "worker identity"
[ "$(grep -c 'serviceAccountName: runner' projects/01-sandboxed-code-exec/agent/job.yaml)" = 1 ] && pass "the agent Job runs as runner" || fail "job identity"

echo "--- tokens for the gateway: its audience only, pod-bound, short-lived"
probe id-runner-$T runner
TOK=$(token_of id-runner-$T)
C=$(claims "$TOK")
check "audience is the gateway's, nothing else" "\"aud\": ?\\[\"$AUD\"\\]" "$C"
life=$(python3 -c 'import json, sys; c = json.loads(sys.argv[1]); print(c["exp"] - c["iat"])' "$C")
[ "$life" -le 600 ] && pass "valid for ${life}s (at most 10 minutes; the kubelet refreshes it)" || fail "lifetime ${life}s"
check "bound to the pod" "\"name\": ?\"id-runner-$T\"" "$C"
check "the API server refuses it (wrong audience): HTTP 401" '^401$' "$(api_with "$TOK")"
API_TOK=$(token_of id-runner-$T /var/run/secrets/kubernetes.io/serviceaccount/token)
life=$(python3 -c 'import json, sys; c = json.loads(sys.argv[1]); print(c["exp"] - c["iat"])' "$(claims "$API_TOK")")
[ "$life" -le 3600 ] && pass "the agent's API token is valid ${life}s, not the year an automounted one gets here" || fail "API token lifetime ${life}s"
check "the API token works for the agent's own job" '^200$' "$(api_with "$(token_of "$(kubectl get pod -n agent -l app=agent-worker -o jsonpath='{.items[0].metadata.name}')" /var/run/secrets/kubernetes.io/serviceaccount/token)")"
forward
out=$(whoami "$TOK")
check "gateway accepts it: identity runner, this pod" "^200 .*\"serviceAccount\":\"runner\".*\"pod\":\"id-runner-$T\"" "$out"
check "gateway records the token's ID for audit" '"credentialID":"JTI=' "$out"
check "gateway refuses the pod's API-server token (wrong audience)" '^401 .*invalid for the target audiences' "$(whoami "$API_TOK")"
check "gateway refuses no token" '^401 .*no bearer token' "$(whoami "")"
check "gateway refuses garbage" '^401 ' "$(whoami "not-a-token")"
HAND=$(kubectl create token runner -n agent --audience $AUD --duration 10m)
check "gateway refuses a hand-minted token for the right audience (not pod-bound)" "^403 .*isn't bound to a pod" "$(whoami "$HAND")"
probe id-default-$T default
check "gateway refuses an identity not on its list (agent/default, pod-bound)" '^403 .*may not use this gateway' "$(whoami "$(token_of id-default-$T)")"
check "gateway logs each decision" '"status":403.*"identity":"system:serviceaccount:agent:default"' "$(kubectl logs -n gateways deploy/llm-gateway --tail=20)"

for ns in agent approval-system gateways temporal; do
  auto=$(kubectl get pods -n $ns -o jsonpath='{range .items[*]}{.metadata.name}={.spec.automountServiceAccountToken} {end}' | tr ' ' '\n' | grep -v '=false$' | grep . || true)
  [ -z "$auto" ] && pass "no pod in $ns automounts the year-long API token" || fail "automounted in $ns: $auto"
done

echo "--- the gateway's own reach"
GW=system:serviceaccount:gateways:llm-gateway
[ "$(can create tokenreviews.authentication.k8s.io --as=$GW)" = yes ] && pass "gateway may review tokens" || fail "gateway can't review tokens"
for v in "get secrets -A" "list pods -A" "create subjectaccessreviews.authorization.k8s.io" "create serviceaccounts/token -n agent"; do
  # shellcheck disable=SC2086
  [ "$(can $v --as=$GW)" = no ] && pass "gateway may not: $v" || fail "gateway MAY $v"
done

echo "--- network fence"
SVC=$(kubectl get svc -n gateways llm-gateway -o jsonpath='{.spec.clusterIP}')
connect_from() { # NAMESPACE POD -> OPEN/BLOCKED
  kubectl exec -n "$1" "$2" -- python3 -c "
import socket
try:
    socket.create_connection(('$SVC', 8080), timeout=3); print('OPEN')
except Exception:
    print('BLOCKED')" 2>&1 || true
}
check "agent pods reach the gateway" '^OPEN' "$(connect_from agent id-runner-$T)"
check "agent pods resolve the gateway's name" 'ok' "$(kubectl exec -n agent id-runner-$T -- python3 -c "import socket; socket.gethostbyname('llm-gateway.gateways.svc.cluster.local'); print('ok')" 2>&1 || true)"
kubectl run id-outside-$T -n workloads --image=python:3.13-slim --restart=Never --quiet \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"p","image":"python:3.13-slim","command":["sleep","300"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
kubectl wait -n workloads pod/id-outside-$T --for=condition=Ready --timeout=90s >/dev/null
check "pods in other namespaces can't reach it" '^BLOCKED' "$(connect_from workloads id-outside-$T)"
SBX=$(kubectl get pod -n sandboxes -o jsonpath='{.items[0].metadata.name}')
check "sandboxes can't reach it" '^BLOCKED' "$(connect_from sandboxes "$SBX")"

echo "--- revocation"
kubectl delete pod -n agent id-runner-$T --wait=true >/dev/null
sleep 11   # the gateway reuses a review for up to 10 s
check "pod deleted: its token is refused (within the 10 s review cache)" '^401 ' "$(whoami "$TOK")"
W=$(kubectl get pod -n agent -l app=agent-worker -o jsonpath='{.items[0].metadata.name}')
WTOK=$(token_of "$W")
check "the proposer's worker token works before the kill switch" '^200 .*"serviceAccount":"proposer"' "$(whoami "$WTOK")"
./scripts/kill-switch.sh stop --reason "test-identity $T" >/dev/null
sleep 11
check "kill switch: the worker's gateway token is refused" '^401 ' "$(whoami "$WTOK")"
check "kill switch: no new gateway tokens can be minted for agents" 'agent-kill-switch' "$(kubectl create token proposer -n agent --audience $AUD 2>&1 || true)"
./scripts/kill-switch.sh resume --reason "test-identity $T resume" >/dev/null
kubectl scale deploy -n agent agent-worker --replicas=1 >/dev/null
kubectl rollout status -n agent deploy/agent-worker --timeout=120s >/dev/null
W=$(kubectl get pod -n agent -l app=agent-worker -o jsonpath='{.items[0].metadata.name}')
kubectl wait -n agent pod/"$W" --for=condition=Ready --timeout=60s >/dev/null
check "after resume and a deliberate restart: a fresh token works" '^200 .*"serviceAccount":"proposer"' "$(whoami "$(token_of "$W")")"
check "the old one stays refused" '^401 ' "$(whoami "$WTOK")"

exit $FAILED
