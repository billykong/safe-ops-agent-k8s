#!/usr/bin/env bash
# P3 milestone 3: MCP tools behind a gateway that brokers their secrets
# (P3-04), with pinned tool descriptors (P3-20) and no discovery (P3-21).
# Checks where the tracker's token lives (and doesn't), the network fence,
# the MCP gateway's authentication, per-identity registry and method
# allowlist, the result cap, a "rug pull" (a server that changes a tool's
# description and adds an unvetted tool), and the model-driven agent
# reading incidents through MCP before proposing. Needs `make p3`. Exits
# non-zero on any failure.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
NS=approvals
T=$(date +%s)
TMP=$(mktemp -d)
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:300}"; fi; }
can() { kubectl auth can-i "$@" 2>/dev/null || true; }
tctl() { kubectl exec -n temporal deploy/temporal -- temporal "$@"; }
phase() { kubectl get changerequest -n $NS "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
wf_status() { tctl workflow describe --workflow-id "$1" -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["workflowExecutionInfo"]["status"])' 2>/dev/null || echo unknown; }
result() { tctl workflow result --workflow-id "$1" -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("result", d)))' 2>/dev/null || echo '{}'; }
agent() { # NAME INSTRUCTION
  python3 -c 'import json, sys; print(json.dumps({"name": sys.argv[1], "instruction": sys.argv[2]}))' "$1" "$2" > $TMP/goal.json
  tctl workflow start --task-queue agent --type AgentWorkflow --workflow-id "$1" --input "$(cat $TMP/goal.json)" >/dev/null
}
decided() { # NAME: the proposal's spec, or the escalation's result. Never waits on an approval.
  local s
  for _ in $(seq 1 60); do
    s=$(wf_status "$1")
    [ "$s" = WORKFLOW_EXECUTION_STATUS_COMPLETED ] && { result "$1"; return; }
    [ -n "$(phase "$1")" ] && { echo "proposed $(kubectl get changerequest -n $NS "$1" -o jsonpath='{.spec.action} {.spec.intent}')"; return; }
    [ "$s" = WORKFLOW_EXECUTION_STATUS_FAILED ] && { echo FAILED; return; }
    sleep 1
  done
  echo "timeout: $s"
}
forward() { # NAMESPACE SVC PORT
  command kubectl --context "$KUBE_CONTEXT" port-forward -n "$1" "svc/$2" "$3:8080" >/dev/null 2>&1 &
  echo $! >> $TMP/pf
  for _ in $(seq 1 20); do curl -s -o /dev/null "localhost:$3/healthz" && return 0; sleep 0.5; done
}
reforward() {
  for pid in $(cat $TMP/pf 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
  : > $TMP/pf
  forward gateways mcp-gateway 18090; forward gateways mock-model 18082
}
rpc() { # TOKEN SERVER JSON -> "HTTP-CODE BODY"
  local h=(); [ -n "$1" ] && h=(-H "Authorization: Bearer $1")
  curl -s -o $TMP/out -w '%{http_code}' "${h[@]}" -H 'content-type: application/json' -H 'mcp-protocol-version: 2025-06-18' \
    --data "$3" "localhost:18090/mcp/$2"; echo " $(head -c 4000 $TMP/out)"
}
call() { rpc "$1" incidents "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}"; }
list() { rpc "$1" incidents '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'; }
names() { python3 -c 'import json,sys; b=sys.stdin.read().split(" ",1)[1]; print(" ".join(sorted(t["name"] for t in json.loads(b)["result"]["tools"])))'; }
token_of() { kubectl exec -n agent "$1" -- cat "/var/run/secrets/safe-ops.io/$2/token"; }
rugpull() { # on|off
  if [ "$1" = on ]; then kubectl set env -n mcp-servers deploy/incidents-mcp TOOL_VARIANT=rugpull >/dev/null
  else kubectl set env -n mcp-servers deploy/incidents-mcp TOOL_VARIANT- >/dev/null; fi
  kubectl rollout status -n mcp-servers deploy/incidents-mcp --timeout=120s >/dev/null
  for _ in $(seq 1 30); do kubectl exec -n gateways deploy/mcp-gateway -- /mcpgateway pins http://incidents-mcp.mcp-servers.svc.cluster.local:8080/mcp >/dev/null 2>&1 && break; sleep 2; done
}
cleanup() {
  for pid in $(cat $TMP/pf 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
  kubectl set env -n mcp-servers deploy/incidents-mcp TOOL_VARIANT- >/dev/null 2>&1 || true
  kubectl delete pod -n agent mcp-runner-$T --ignore-not-found --wait=false >/dev/null 2>&1 || true
  for w in $(tctl workflow list --query "ExecutionStatus='Running'" -o json 2>/dev/null | python3 -c 'import json,sys; [print(w["execution"]["workflowId"]) for w in json.load(sys.stdin) or []]' | grep -- "-$T" || true); do
    tctl workflow terminate --workflow-id "$w" --reason "test cleanup" >/dev/null 2>&1 || true
  done
  for n in $(kubectl get changerequest -n $NS -o name 2>/dev/null | grep -- "-$T\$"); do kubectl delete -n $NS "$n" --wait=false >/dev/null 2>&1; done
  rm -rf "$TMP"
}
trap cleanup EXIT
: > $TMP/pf
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status"; exit 1; }
kubectl delete changebudget -n $NS default --ignore-not-found >/dev/null
rugpull off
kubectl rollout status -n agent deploy/agent-worker --timeout=120s >/dev/null
W=$(kubectl get pod -n agent -l app=agent-worker -o jsonpath='{.items[0].metadata.name}')
PTOK=$(token_of "$W" mcp-gateway)          # proposer, MCP audience
LTOK=$(token_of "$W" llm-gateway)          # proposer, LLM-gateway audience
# A runner pod with an MCP-audience token, for the per-identity check.
kubectl create -f projects/01-sandboxed-code-exec/agent/job.yaml --dry-run=client -o json | python3 -c '
import json, sys
t = json.load(sys.stdin)["spec"]["template"]
t["spec"]["restartPolicy"] = "Never"
t["spec"]["containers"][0]["command"] = ["python", "-c", "import time; time.sleep(900)"]
t["spec"]["containers"][0]["volumeMounts"].append({"name": "mcp", "mountPath": "/var/run/secrets/safe-ops.io/mcp-gateway", "readOnly": True})
t["spec"]["volumes"].append({"name": "mcp", "projected": {"sources": [{"serviceAccountToken": {"audience": "mcp-gateway.safe-ops.io", "expirationSeconds": 600, "path": "token"}}]}})
print(json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": sys.argv[1], "namespace": "agent", "labels": t["metadata"]["labels"]}, "spec": t["spec"]}))
' mcp-runner-$T | kubectl apply -f - >/dev/null
kubectl wait -n agent pod/mcp-runner-$T --for=condition=Ready --timeout=90s >/dev/null
RTOK=$(token_of mcp-runner-$T mcp-gateway)
reforward

echo "--- the tool's secret: only the gateway and the tracker hold it (P3-04)"
holders=$(kubectl get pods -A -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    vols = p["spec"].get("volumes", [])
    if any(v.get("secret", {}).get("secretName") == "incident-tracker-token" for v in vols):
        print(p["metadata"]["namespace"] + "/" + p["metadata"]["labels"].get("app", "?"))' | sort -u | tr '\n' ' ')
[ "$holders" = "gateways/mcp-gateway mcp-servers/incident-tracker " ] && pass "mounted only by the MCP gateway and the tracker" || fail "token mounted by: $holders"
for ns in gateways mcp-servers; do for id in proposer runner; do
  [ "$(can get secrets -n $ns --as=system:serviceaccount:agent:$id)" = no ] && pass "$id can't read Secrets in $ns" || fail "$id CAN read Secrets in $ns"
done; done
out=$(kubectl exec -n mcp-servers deploy/incidents-mcp -- python3 -c "
import urllib.request
try:
    urllib.request.urlopen('http://incident-tracker.mcp-servers.svc.cluster.local:8080/incidents', timeout=5); print('OPEN')
except urllib.error.HTTPError as e: print(e.code)" 2>&1)
check "the MCP server itself has no credential: the tracker answers it 401" '^401$' "$out"

echo "--- network fence"
connect() { # NAMESPACE POD HOST
  kubectl exec -n "$1" "$2" -- python3 -c "
import socket
try:
    socket.create_connection(('$3', 8080), timeout=3); print('OPEN')
except Exception: print('BLOCKED')" 2>&1 || true
}
MCPIP=$(kubectl get svc -n mcp-servers incidents-mcp -o jsonpath='{.spec.clusterIP}')
TRIP=$(kubectl get svc -n mcp-servers incident-tracker -o jsonpath='{.spec.clusterIP}')
GWIP=$(kubectl get svc -n gateways mcp-gateway -o jsonpath='{.spec.clusterIP}')
check "agent pods reach the MCP gateway" '^OPEN' "$(connect agent mcp-runner-$T "$GWIP")"
check "agent pods can't reach the MCP server directly" '^BLOCKED' "$(connect agent mcp-runner-$T "$MCPIP")"
check "agent pods can't reach the tracker" '^BLOCKED' "$(connect agent mcp-runner-$T "$TRIP")"

echo "--- who may use which tools (P3-21: a static registry, no discovery)"
check "no token: 401" '^401 ' "$(list "")"
check "the LLM gateway's token (wrong audience): 401" '^401 .*invalid for the target audiences' "$(list "$LTOK")"
check "runner (not in the registry): 403" '^403 ' "$(list "$RTOK")"
check "a server not in the registry: 403" '^403 .*may not use MCP server \"other\"' "$(rpc "$PTOK" other '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
check "proposer sees exactly its pinned tools" '^get_incident list_open_incidents$' "$(list "$PTOK" | names)"
out=$(rpc "$PTOK" incidents '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}')
python3 -c 'import json,sys; r=json.loads(sys.argv[1].split(" ",1)[1])["result"]; sys.exit(0 if list(r["capabilities"])==["tools"] and "instructions" not in r else 1)' "$out" \
  && pass "initialize: tools-only capabilities, no server instructions passed on" || fail "initialize: $out"
for m in resources/list prompts/list completion/complete; do
  check "method $m refused" '"code":-32601' "$(rpc "$PTOK" incidents "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"$m\",\"params\":{}}")"
done
check "batches refused" '^400 ' "$(rpc "$PTOK" incidents '[{"jsonrpc":"2.0","id":1,"method":"tools/list"}]')"

echo "--- calls: the gateway adds the credential, caps the output"
out=$(call "$PTOK" get_incident '{"incident_id":"INC-1001"}')
check "get_incident works through the gateway (credential added there)" 'scale web to 3 replicas.*"isError":false' "$out"
call "$PTOK" get_incident '{"incident_id":"INC-1003"}' >/dev/null
check "a 200 kB result is truncated to the cap, and says so" 'truncated by the MCP gateway: 16384 of' "$(cat $TMP/out)"
[ "$(wc -c < $TMP/out)" -lt 20000 ] && pass "capped response is $(wc -c < $TMP/out) bytes" || fail "response is $(wc -c < $TMP/out) bytes"
check "a tool not in the registry is refused" '"code":-32602.*not available' "$(call "$PTOK" delete_incident '{"incident_id":"INC-1001"}')"
check "each call is audited with identity, pod and token ID" '"method":"tools/call".*"identity":"system:serviceaccount:agent:proposer".*"credentialID":"JTI=.*"tool":"get_incident"' \
  "$(kubectl logs -n gateways deploy/mcp-gateway --tail=10)"

echo "--- descriptor pins (P3-20): a server changes under us"
rugpull on
out=$(list "$PTOK" | names)
check "changed get_incident and unvetted delete_incident are hidden" '^list_open_incidents$' "$out"
check "calling the changed tool is refused" '"code":-32602.*descriptor is changed' "$(call "$PTOK" get_incident '{"incident_id":"INC-1001"}')"
check "calling the new tool is refused" '"code":-32602.*not available' "$(call "$PTOK" delete_incident '{"incident_id":"INC-1001"}')"
check "the gateway logs the drift, with the new hash" '"mcp descriptor rejected".*"tool":"get_incident","status":"changed","hash":"sha256:' \
  "$(kubectl logs -n gateways deploy/mcp-gateway --tail=20)"
agent rug-$T "Look into incident INC-1001 and fix it. [mock:tool:incidents__get_incident:{\"incident_id\":\"INC-1001\"}]"
check "the agent can't use the changed tool and escalates instead" '"action": "Escalate"' "$(decided rug-$T)"
[ -z "$(phase rug-$T)" ] && pass "nothing proposed from it" || fail "rug-$T proposed"
rugpull off
check "restored server: both tools back" '^get_incident list_open_incidents$' "$(list "$PTOK" | names)"

echo "--- the agent reads incidents through MCP, then proposes"
agent inc1-$T "Look into incident INC-1001 and fix it. [mock:tool:incidents__get_incident:{\"incident_id\":\"INC-1001\"}]"
out=$(decided inc1-$T)
check "INC-1001 (capacity): reads it, proposes scaling to 3" '^proposed .*"replicas":3.*"type":"ScaleDeployment"' "$out"
check "the request records which tools were read" '\[tools read\] incidents__get_incident' "$out"
check "the tool output reached the model marked untrusted" 'tool_output source=\\"incidents/get_incident\\" trust=\\"untrusted\\"' "$(curl -s localhost:18082/debug/last)"
agent inc2-$T "Look into incident INC-1002 and fix it. [mock:tool:incidents__get_incident:{\"incident_id\":\"INC-1002\"}]"
check "INC-1002 (stale config): proposes a restart" '^proposed .*"type":"RestartDeployment"' "$(decided inc2-$T)"
agent inc3-$T "Look into incident INC-1003. [mock:tool:incidents__get_incident:{\"incident_id\":\"INC-1003\"}]"
check "INC-1003 (no action needed): escalates, nothing proposed" '"action": "Escalate"' "$(decided inc3-$T)"

echo "--- the registry lives in git"
live=$(kubectl get configmap -n gateways mcp-registry -o jsonpath='{.data.registry\.json}' | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))')
repo=$(python3 -c '
import json, sys, re
s = open("projects/03-tool-access/manifests/55-mcp-gateway.yaml").read()
block = s.split("registry.json: |", 1)[1].split("\n---", 1)[0]
print(json.dumps(json.loads("\n".join(l[4:] for l in block.splitlines())), sort_keys=True))')
[ "$live" = "$repo" ] && pass "the running registry matches the reviewed one in git" || fail "the running registry differs from git"

exit $FAILED
