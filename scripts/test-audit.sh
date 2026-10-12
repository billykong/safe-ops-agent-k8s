#!/usr/bin/env bash
# P4 milestone 2: the API server's audit log (P4-04, SEC-36). Checks:
#  - the pipeline: the API server runs with the policy, the webhook to the
#    sink and the node-local log; the sink's chain verifies;
#  - the agent's identity: a real task's ChangeRequest is recorded under
#    the agent's service account, with the pod, node and token id behind
#    it, the full request, and the task's trace id; the same event is in
#    the node's log;
#  - the agent's refused requests (with its real token) are recorded,
#    counted, and raise an alert;
#  - no secret values or bearer tokens in either copy;
#  - a change to admission configuration (GAP-02) and to the kill switch
#    is recorded and raises an alert;
#  - the agent can't write to or delete the store: no RBAC in namespace
#    audit, no route to the sink, and the sink takes only the API
#    server's client certificate;
#  - tampering: an edit on the node's disk breaks the chain, the sink and
#    Prometheus report it, and restoring the byte restores the chain;
#  - delivery: events made while the sink restarts still arrive; after a
#    long outage they don't (GAP-07), and the drop is counted and alerts.
# Needs `make p2 p3 durable p4 audit`, with the LLM gateway in mock mode.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
T=$(date +%s)
NODE=${CLUSTER:-safe-ops}-control-plane
NS=approvals
AGENT=system:serviceaccount:agent:proposer
TMP=$(mktemp -d)
FAILED=0
PFS=()
RESTORE=""
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:300}"; fi; }
refute() { if grep -qE -- "$2" <<<"$3"; then fail "$1: found: $(grep -oE -- "$2" <<<"$3" | head -3 | tr '\n' ' ')"; else pass "$1"; fi; }
node() { docker exec "$NODE" "$@"; }
sink() { kubectl exec -n audit deploy/audit-sink -- /audit-sink "$@"; }
# The sink's events and the node's log, as JSON lines.
sink_events() { sink cat > $TMP/sink.jsonl; }
node_events() { node cat /var/log/kubernetes/audit/audit.log > $TMP/node.jsonl; }
ev() { python3 scripts/audit_events.py "$@"; }
# as_agent METHOD PATH [BODY]: the API, with the agent worker's own token.
as_agent() { kubectl exec -i -n agent deploy/agent-worker -- python - "$@" < scripts/kube_probe.py; }
in_agent_connect() { kubectl exec -i -n agent deploy/agent-worker -- python - connect "$@" < scripts/otel_probe.py 2>&1 || true; }
forward() {
  # command: kubectl is a function (lib.sh); backgrounding the function
  # puts $! on a subshell, and killing that leaves the port-forward running.
  command kubectl --context "$KUBE_CONTEXT" port-forward -n "$1" "$2" "$4:$3" >/dev/null 2>&1 & PFS+=($!)
  for _ in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/$4) 2>/dev/null && return 0; sleep 1; done
  echo "port-forward to $2 didn't come up"; exit 1
}
prom() { curl -s --data-urlencode "query=$1" localhost:29091/api/v1/query |
  python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)'; }
alerts() { curl -s localhost:29091/api/v1/alerts | python3 -c '
import json,sys
for a in json.load(sys.stdin)["data"]["alerts"]:
    print(a["labels"]["alertname"], a["state"], a["labels"].get("resource",""), a["labels"].get("actor",""))'; }
# wait_alert NAME [EXTRA]: up to ~90s for the alert to be pending or firing
wait_alert() { for _ in $(seq 1 45); do a=$(alerts); grep -qE "^$1 (pending|firing).*${2:-}" <<<"$a" && break; sleep 2; done; echo "$a"; }
cleanup() {
  [ -n "$RESTORE" ] && eval "$RESTORE" || true
  for p in "${PFS[@]}"; do kill "$p" 2>/dev/null || true; done
  kubectl exec -n temporal deploy/temporal -- temporal workflow terminate --workflow-id audit-$T --reason "test cleanup" >/dev/null 2>&1 || true
  kubectl delete changerequest -n $NS audit-$T --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete validatingadmissionpolicy audit-probe-$T --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete secret -n workloads audit-probe-$T --ignore-not-found >/dev/null 2>&1 || true
  kubectl annotate configmap -n approval-system agent-kill-switch safe-ops.io/audit-probe- >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status"; exit 1; }
grep -q mock-model <<<"$(kubectl get deploy -n gateways llm-gateway -o jsonpath='{.spec.template.spec.containers[0].env}')" \
  || { echo "the LLM gateway isn't in mock mode: scripts/llm-gateway-mode.sh mock"; exit 1; }
kubectl delete changebudget -n $NS default --ignore-not-found >/dev/null
forward observability svc/prometheus 9090 29091

echo "=== The pipeline"
cmd=$(kubectl get pod -n kube-system kube-apiserver-$NODE -o jsonpath='{.spec.containers[0].command}')
for f in audit-policy-file=/etc/kubernetes/audit/policy.yaml audit-webhook-config-file= audit-log-path=/var/log/kubernetes/audit/audit.log; do
  check "API server runs with --$f" "\-\-$f" "$cmd"
done
check "the node's log is root's alone" '^-rw------- 1 root root' "$(node ls -l /var/log/kubernetes/audit/audit.log)"
check "the sink's chain verifies" '^ok entries=[1-9]' "$(sink verify 2>&1)"
check "Prometheus scrapes the sink" '^1$' "$(prom 'up{job="audit-sink"}')"

echo "=== The agent's identity, from a real task"
TID=$(scripts/agent-task.sh audit-$T web "Look into incident INC-1001 and fix it. [mock:tool:incidents__get_incident:{\"incident_id\":\"INC-1001\"}]")
for _ in $(seq 1 60); do kubectl get changerequest -n $NS audit-$T >/dev/null 2>&1 && break; sleep 1; done
POD=$(kubectl get pod -n agent -l app=agent-worker -o jsonpath='{.items[0].metadata.name}')
for _ in $(seq 1 20); do
  sink_events
  line=$(ev --where verb=create --where 'objectRef>resource=changerequests' --where "objectRef>name=audit-$T" --where stage=ResponseComplete < $TMP/sink.jsonl)
  [ -n "$line" ] && break; sleep 2
done
row() { ev --print "$1" <<<"$line"; }
check "the agent's proposal is in the sink" 'changerequests' "$line"
check "under the agent's own identity" "^$AGENT\$" "$(row 'user>username')"
check "with the pod its token is bound to" "^\[\"$POD\"\]\$" "$(row 'user>extra>authentication.kubernetes.io/pod-name')"
check "and the node and token id" 'JTI=' "$(row 'user>extra>authentication.kubernetes.io/credential-id')$(row 'user>extra>authentication.kubernetes.io/node-name')"
check "at RequestResponse: what it asked for" '^RequestResponse$' "$(row level)"
check "the request carries the task's trace id ($TID)" "$TID" "$(row 'requestObject>metadata>annotations')"
check "and what it got: 201" '^201$' "$(row 'responseStatus>code')"
ID=$(row auditID)
for _ in $(seq 1 10); do node_events; [ "$(ev --where auditID=$ID --where stage=ResponseComplete --count < $TMP/node.jsonl)" = 1 ] && break; sleep 1; done
check "the same event (auditID $ID) is in the node's log" '^1$' "$(ev --where auditID=$ID --where stage=ResponseComplete --count < $TMP/node.jsonl)"

echo "=== The agent's refused requests are recorded and alert"
f0=$(prom 'sum(safeops_audit_events_total{actor="agent",outcome="forbidden"})')
declare -A TRIES=(
  ["delete the chain's volume claim"]="DELETE /api/v1/namespaces/audit/persistentvolumeclaims/audit-chain"
  ["delete the sink"]="DELETE /apis/apps/v1/namespaces/audit/deployments/audit-sink"
  ["read the sink's TLS secret"]="GET /api/v1/namespaces/audit/secrets/audit-sink-tls"
  ["delete the audit namespace"]="DELETE /api/v1/namespaces/audit"
  ["delete the write guard"]="DELETE /apis/admissionregistration.k8s.io/v1/validatingadmissionpolicies/agent-write-guard"
)
for d in "${!TRIES[@]}"; do
  read -r m p <<<"${TRIES[$d]}"
  check "agent's token: $d: 403" '^403' "$(as_agent "$m" "$p" 2>&1)"
done
check "agent's token: flip the kill switch: 403" '^403' "$(as_agent PATCH /api/v1/namespaces/approval-system/configmaps/agent-kill-switch '{"data":{"mode":"run"}}' 2>&1)"
sleep 4; sink_events
n=$(ev --where "user>username=$AGENT" --where 'responseStatus>code=403' --where stage=ResponseComplete --where 'objectRef>namespace=audit' < $TMP/sink.jsonl | ev --count)
check "each refusal in namespace audit is in the sink (4 or more)" '^([4-9]|[1-9][0-9]+)$' "$n"
check "the attempt on the write guard is in the sink" '^[1-9]' "$(ev --where "user>username=$AGENT" --where verb=delete --where 'objectRef>name=agent-write-guard' --where 'responseStatus>code=403' --count < $TMP/sink.jsonl)"
for _ in $(seq 1 30); do f1=$(prom 'sum(safeops_audit_events_total{actor="agent",outcome="forbidden"})'); [ "${f1%.*}" -ge $(( ${f0%.*} + 6 )) ] && break; sleep 2; done
check "Prometheus counts them: agent forbidden $f0 -> $f1 (6 or more)" '^ok$' "$([ "${f1%.*}" -ge $(( ${f0%.*} + 6 )) ] && echo ok || echo no)"
check "alert AgentRequestForbidden" '^AgentRequestForbidden (pending|firing)' "$(wait_alert AgentRequestForbidden)"

echo "=== No secrets or tokens in either copy"
CANARY=audit-canary-$T-$RANDOM
kubectl create secret generic -n workloads audit-probe-$T --from-literal=value=$CANARY >/dev/null
sleep 4; sink_events; node_events
check "creating a secret is recorded (who, when)" '^1$' "$(ev --where verb=create --where 'objectRef>name=audit-probe-'$T --where 'objectRef>resource=secrets' --where stage=ResponseComplete --count < $TMP/sink.jsonl)"
for s in sink node; do
  refute "the secret's value is not in the $s copy" "$CANARY|$(printf %s "$CANARY" | base64)" "$(cat $TMP/$s.jsonl)"
  refute "no bearer token (JWT) in the $s copy" 'eyJhbGciOi[A-Za-z0-9_-]{10,}\.' "$(cat $TMP/$s.jsonl)"
done

echo "=== Changes to what guards the agent alert (GAP-02)"
kubectl apply -f - >/dev/null <<YAML
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: audit-probe-$T}
spec:
  matchConstraints:
    resourceRules: [{apiGroups: [""], apiVersions: [v1], operations: [CREATE], resources: [configmaps]}]
  validations: [{expression: "true"}]
YAML
kubectl delete validatingadmissionpolicy audit-probe-$T >/dev/null
kubectl annotate configmap -n approval-system agent-kill-switch safe-ops.io/audit-probe=$T >/dev/null
kubectl annotate configmap -n approval-system agent-kill-switch safe-ops.io/audit-probe- >/dev/null
sleep 4; sink_events
vap=$(ev --where 'objectRef>name=audit-probe-'$T --where 'objectRef>resource=validatingadmissionpolicies' --where stage=ResponseComplete --print verb --print level --print 'user>username' < $TMP/sink.jsonl)
check "the policy's create is recorded with its body, and who" "create	Request	kubernetes-admin" "$vap"
check "and its delete" "delete	Request	kubernetes-admin" "$vap"
check "the kill switch's change is recorded" '^[1-9]' "$(ev --where 'objectRef>name=agent-kill-switch' --where verb=patch --where 'responseStatus>code=200' --count < $TMP/sink.jsonl)"
check "alert AdmissionConfigChanged (human, validatingadmissionpolicies)" '^AdmissionConfigChanged (pending|firing) validatingadmissionpolicies human' "$(wait_alert AdmissionConfigChanged validatingadmissionpolicies)"
check "alert GuardConfigChanged (kill-switch)" '^GuardConfigChanged (pending|firing) kill-switch human' "$(wait_alert GuardConfigChanged kill-switch)"

echo "=== The dashboard"
forward observability svc/grafana 3000 23001
dash=$(curl -s localhost:23001/api/dashboards/uid/safe-ops-agent)
titles=$(python3 -c 'import json,sys; [print(p["title"]) for p in json.load(sys.stdin)["dashboard"]["panels"]]' <<<"$dash" 2>/dev/null || true)
for t in "Agent requests refused by the API server" "Admission configuration changes" "Audit events dropped" "Audit chain"; do
  check "the dashboard has '$t'" "^$t$" "$titles"
done
gq() { # TITLE: the panel's query, run through Grafana over the last 15 minutes
  python3 -c 'import json,sys; [print(t["expr"].replace("$__range","15m")) for p in json.load(sys.stdin)["dashboard"]["panels"] if p["title"]==sys.argv[1] for t in p.get("targets",[])]' "$1" <<<"$dash" |
  python3 -c 'import json,sys; print(json.dumps({"from":"now-15m","to":"now","queries":[{"refId":"A","datasource":{"type":"prometheus","uid":"prometheus"},"expr":sys.stdin.read().strip(),"instant":True}]}))' |
  curl -s -H 'Content-Type: application/json' localhost:23001/api/ds/query -d @- |
  python3 -c 'import json,sys; f=json.load(sys.stdin)["results"]["A"]["frames"]; v=f[0]["data"]["values"][1][0] if f and f[0]["data"]["values"] else None; print("none" if v is None else int(float(v)))'
}
check "Grafana answers 'Agent requests refused by the API server' (6 or more)" '^([6-9]|[1-9][0-9]+)$' "$(gq 'Agent requests refused by the API server')"
check "... 'Admission configuration changes' (2 or more)" '^([2-9]|[1-9][0-9]+)$' "$(gq 'Admission configuration changes')"
check "... 'Audit chain': verified" '^1$' "$(gq 'Audit chain')"

echo "=== The agent can't write to or delete the store"
for verb_res in "delete persistentvolumeclaims" "delete deployments" "update deployments" "get secrets" "create pods/exec" "delete pods" "update networkpolicies" "update ciliumnetworkpolicies"; do
  out=$(kubectl auth can-i $verb_res -n audit --as=$AGENT 2>/dev/null || true)
  check "agent may not $verb_res in audit" '^no$' "$out"
done
for verb_res in "delete namespaces/audit" "delete persistentvolumes" "update storageclasses" "create nodes/proxy" "impersonate users"; do
  out=$(kubectl auth can-i $verb_res --as=$AGENT 2>/dev/null || true)
  check "agent may not $verb_res" '^no$' "$out"
done
check "the chain's volume is kept if its claim is deleted (Retain)" '^Retain$' \
  "$(kubectl get pv "$(kubectl get pvc -n audit audit-chain -o jsonpath='{.spec.volumeName}')" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')"
check "no route from the agent to the sink's webhook" '^no connection' "$(in_agent_connect 10.96.0.200 8443)"
check "no route from the agent to the sink's metrics" '^no connection' "$(in_agent_connect 10.96.0.200 9090)"
# From the node, the one place the network admits: TLS decides.
c() { node curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --cacert /etc/kubernetes/audit/ca.crt "$@" https://10.96.0.200:8443/audit 2>&1 || true; }
check "no client certificate: refused in the handshake" 'certificate required|alert|SSL|000' "$(c -X POST -d '{}')"
node sh -c "cd /tmp && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=kube-apiserver-audit -keyout fake.key -out fake.crt 2>/dev/null"
check "a self-made certificate with the API server's name: refused" 'unknown ca|alert|SSL|000' "$(c --cert /tmp/fake.crt --key /tmp/fake.key -X POST -d '{}')"
node rm -f /tmp/fake.key /tmp/fake.crt
check "the API server's certificate gets in, and the sink checks the body (400)" '^400$' \
  "$(c --cert /etc/kubernetes/audit/client.crt --key /etc/kubernetes/audit/client.key -X POST -d '{"kind":"Status"}')"
check "the sink has no way to read, change or delete entries over HTTP (405)" '^405$' \
  "$(c --cert /etc/kubernetes/audit/client.crt --key /etc/kubernetes/audit/client.key -X DELETE)"

echo "=== Tampering on the node's disk is detected"
PV=$(kubectl get pvc -n audit audit-chain -o jsonpath='{.spec.volumeName}')
FILE=$(kubectl get pv $PV -o jsonpath='{.spec.hostPath.path}')/audit.jsonl
# Flip one character of the agent's proposal's auditID, in place (same
# inode, same length): what a root user on the node could do.
OFF=$(node grep -b -o "\"auditID\":\"$ID\"" "$FILE" | head -1 | cut -d: -f1)
POS=$(( OFF + 11 ))
ORIG=$(node dd if="$FILE" bs=1 skip=$POS count=1 2>/dev/null)
NEW=$([ "$ORIG" = f ] && echo e || echo f)
RESTORE="node sh -c 'printf $ORIG | dd of=$FILE bs=1 seek=$POS conv=notrunc 2>/dev/null'"
node sh -c "printf $NEW | dd of=$FILE bs=1 seek=$POS conv=notrunc 2>/dev/null"
check "the edit is detected by a fresh verify" "broken after [0-9]+ good entries: line [0-9]+: hash doesn't match" "$(sink verify 2>&1 || true)"
for _ in $(seq 1 30); do [ "$(prom 'safeops_audit_chain_verified')" = 0 ] && break; sleep 2; done
check "the running sink reports it (safeops_audit_chain_verified 0)" '^0$' "$(prom 'safeops_audit_chain_verified')"
check "and logs it" 'CHAIN CHECK FAILED' "$(kubectl logs -n audit deploy/audit-sink --since=2m)"
check "alert AuditChainBroken" '^AuditChainBroken (pending|firing)' "$(wait_alert AuditChainBroken)"
eval "$RESTORE"; RESTORE=""
check "restoring the byte restores the chain" '^ok entries=' "$(sink verify 2>&1)"
for _ in $(seq 1 30); do [ "$(prom 'safeops_audit_chain_verified')" = 1 ] && break; sleep 2; done
check "and the sink sees it whole again" '^1$' "$(prom 'safeops_audit_chain_verified')"

echo "=== Delivery across a short sink outage"
# probe NAME: the agent asks for a configmap in namespace audit (refused);
# seen FILE NAME: how many final events for it are in FILE.
probe() { as_agent GET "/api/v1/namespaces/audit/configmaps/$1" >/dev/null 2>&1 || true; }
seen() { ev --where "user>username=$AGENT" --where 'objectRef>name='"$2" --where stage=ResponseComplete --count < "$1"; }
sink_down() {
  kubectl scale -n audit deploy/audit-sink --replicas=0 >/dev/null
  kubectl wait --for=delete pod -n audit -l app=audit-sink --timeout=60s >/dev/null 2>&1 || true
}
sink_up() {
  kubectl scale -n audit deploy/audit-sink --replicas=1 >/dev/null
  kubectl rollout status -n audit deploy/audit-sink --timeout=120s >/dev/null
}
sink_down
check "the sink is down" '^$' "$(kubectl get pod -n audit -l app=audit-sink -o name)"
probe audit-short-$T
sleep 3
sink_up
for _ in $(seq 1 30); do sink_events; [ "$(seen $TMP/sink.jsonl audit-short-$T)" = 1 ] && break; sleep 2; done
check "an event made while the sink was down arrived when it came back (the API server retries)" '^1$' "$(seen $TMP/sink.jsonl audit-short-$T)"
check "the chain still verifies after the restart" '^ok entries=' "$(sink verify 2>&1)"

echo "=== A long sink outage (GAP-07)"
e0=$(prom 'sum(apiserver_audit_error_total{plugin="webhook"})')
sink_down
probe audit-long-$T
# The API server gives up on a batch after about 45s of retries.
for _ in $(seq 1 60); do e1=$(prom 'sum(apiserver_audit_error_total{plugin="webhook"})'); [ "${e1%.*}" -gt "${e0%.*}" ] && break; sleep 3; done
check "the API server counts the events it dropped ($e0 -> $e1)" '^ok$' "$([ "${e1%.*}" -gt "${e0%.*}" ] && echo ok || echo no)"
check "alert AuditEventsDropped" '^AuditEventsDropped (pending|firing)' "$(wait_alert AuditEventsDropped)"
check "alert AuditSinkDown (pending, fires after 2 minutes)" '^AuditSinkDown (pending|firing)' "$(wait_alert AuditSinkDown)"
sink_up
node_events
check "the node's log has the event" '^1$' "$(seen $TMP/node.jsonl audit-long-$T)"
sleep 10; sink_events
if [ "$(seen $TMP/sink.jsonl audit-long-$T)" = 0 ]; then
  echo "GAP   GAP-07: the event made during a long outage is missing from the sink; only the node's log has it"
else
  pass "the event made during a long outage reached the sink anyway"
fi
check "the chain still verifies" '^ok entries=' "$(sink verify 2>&1)"

echo
[ $FAILED = 0 ] && echo "ALL PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
