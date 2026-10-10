#!/usr/bin/env bash
# P4 milestone 1: telemetry (P4-01, P4-02, P4-03). Runs three agent tasks
# through the real path (one proposes a change the gate escalates, one the
# agent escalates, one the gate denies) and checks:
#  - one trace per task links the workflow, model calls (agent and LLM
#    gateway), tool calls (agent and MCP gateway), the ChangeRequest and
#    the controller's gate decision, with GenAI token counts;
#  - no content reaches the trace store: the instruction's canary is in
#    no span, and the collector strips content attributes the agent sends
#    itself;
#  - tokens, cost, gate decisions and the agent's own counts reach
#    Prometheus, cost matches tokens at the configured price, and the
#    agent's count of model calls matches the gateway's;
#  - the controller's metrics need an authorized token; the agent can't
#    reach the stores or the gateways' metrics port;
#  - Grafana serves the dashboard and answers its cost and escalation
#    queries.
# Needs `make p2 p3 durable p4`, with the LLM gateway in mock mode.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
T=$(date +%s)
NS=approvals
PROPOSER=system:serviceaccount:agent:proposer
PRICE_IN=5 PRICE_OUT=25  # USD per million tokens: PRICES in the LLM gateway's manifest
TMP=$(mktemp -d)
FAILED=0
PFS=()
pass() { echo "PASS  $1"; }
gap() { echo "GAP   $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:300}"; fi; }
refute() { if grep -qE -- "$2" <<<"$3"; then fail "$1: found: $(grep -oE -- "$2" <<<"$3" | head -3 | tr '\n' ' ')"; else pass "$1"; fi; }
tctl() { kubectl exec -n temporal deploy/temporal -- temporal "$@"; }
st() { kubectl get changerequest -n $NS "$1" -o jsonpath="$2" 2>/dev/null; }
wf_status() { tctl workflow describe --workflow-id "$1" -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["workflowExecutionInfo"]["status"])' 2>/dev/null || echo unknown; }
in_agent() { kubectl exec -i -n agent deploy/agent-worker -- python - "$@" < scripts/otel_probe.py; }
# forward SVC_OR_DEPLOY PORT LOCAL: a port-forward for the rest of the run
forward() {
  kubectl port-forward -n "$1" "$2" "$4:$3" >/dev/null 2>&1 & PFS+=($!)
  for _ in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/$4) 2>/dev/null && return 0; sleep 1; done
  echo "port-forward to $2 didn't come up"; exit 1
}
prom() { curl -s --data-urlencode "query=$1" localhost:29090/api/v1/query |
  python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)'; }
jaeger_trace() { curl -s "localhost:26686/api/v3/traces/$1"; }
cleanup() {
  for p in "${PFS[@]}"; do kill "$p" 2>/dev/null || true; done
  for w in obs-$T obs-esc-$T obs-deny-$T; do tctl workflow terminate --workflow-id "$w" --reason "test cleanup" >/dev/null 2>&1 || true; done
  kubectl delete changerequest -n $NS obs-$T obs-deny-$T --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status"; exit 1; }
grep -q mock-model <<<"$(kubectl get deploy -n gateways llm-gateway -o jsonpath='{.spec.template.spec.containers[0].env}')" \
  || { echo "the LLM gateway isn't in mock mode: scripts/llm-gateway-mode.sh mock"; exit 1; }
# No change budget: the proposed change waits for a human and is never applied.
kubectl delete changebudget -n $NS default --ignore-not-found >/dev/null

echo "=== The stack"
for d in otel-collector jaeger prometheus grafana; do
  check "$d is available" '^1$' "$(kubectl get deploy -n observability $d -o jsonpath='{.status.availableReplicas}')"
done
forward observability svc/prometheus 9090 29090
forward observability svc/jaeger 16686 26686
forward observability svc/grafana 3000 23000
forward approval-system deploy/approval-controller 8443 28443
targets=$(curl -s localhost:29090/api/v1/targets | python3 -c 'import json,sys; [print(t["labels"]["job"], t["health"]) for t in json.load(sys.stdin)["data"]["activeTargets"]]')
for j in llm-gateway mcp-gateway approval-controller; do check "Prometheus scrapes $j" "^$j up$" "$targets"; done

# Counters before the tasks.
q_tok="sum(safeops_llm_tokens_total{identity=\"$PROPOSER\"})"
q_in="sum(safeops_llm_tokens_total{identity=\"$PROPOSER\",type=\"input\"})"
q_out="sum(safeops_llm_tokens_total{identity=\"$PROPOSER\",type=\"output\"})"
q_cost="sum(safeops_llm_cost_usd_total{identity=\"$PROPOSER\"})"
q_req="sum(safeops_llm_requests_total{identity=\"$PROPOSER\"})"
q_calls="sum(safeops_agent_model_calls_total)"
q_tasks="sum(safeops_agent_tasks_total)"
q_esc='sum(safeops_agent_tasks_total{decision="Escalate",escalation="model_chose"})'
q_tool='sum(safeops_mcp_tool_calls_total{server="incidents",tool="get_incident",outcome="ok"})'
for v in tok in out cost req calls tasks esc tool; do q=q_$v; eval "${v}0=\$(prom \"\${$q}\")"; done
for r in Allow Escalate Deny; do eval "gate_${r}0=\$(prom 'sum(safeops_gate_decisions_total{result=\"$r\"})')"; done

echo "=== Three tasks, started as traces (scripts/agent-task.sh)"
CANARY=canary-$T-7f3a
TID=$(scripts/agent-task.sh obs-$T web "Look into incident INC-1001 and fix it. Ticket ref $CANARY. [mock:tool:incidents__get_incident:{\"incident_id\":\"INC-1001\"}]")
check "the proposing task started, trace id printed" '^[0-9a-f]{32}$' "$TID"
TID_ESC=$(scripts/agent-task.sh obs-esc-$T web "Is web healthy? Ticket ref $CANARY.")
check "the escalating task started, trace id printed" '^[0-9a-f]{32}$' "$TID_ESC"
TID_DENY=$(scripts/agent-task.sh obs-deny-$T payments 'Stop payments. [mock:tool:propose_scale_deployment:{"replicas":0,"reason":"as asked"}]')
check "the denied task started, trace id printed" '^[0-9a-f]{32}$' "$TID_DENY"
for _ in $(seq 1 60); do [ -n "$(st obs-$T '{.status.review.policy.result}')" ] && break; sleep 1; done
RESULT=$(st obs-$T '{.status.review.policy.result}')
check "obs-$T: the agent proposed a change and the gate decided" '^(Allow|Escalate|Deny)$' "$RESULT"
for _ in $(seq 1 60); do [ "$(wf_status obs-esc-$T)" = WORKFLOW_EXECUTION_STATUS_COMPLETED ] && break; sleep 1; done
check "obs-esc-$T: the agent escalated (workflow completed, no ChangeRequest)" '^COMPLETED none$' \
  "$(wf_status obs-esc-$T | sed 's/WORKFLOW_EXECUTION_STATUS_//') $(st obs-esc-$T '{.metadata.name}' || true)$( [ -z "$(st obs-esc-$T '{.metadata.name}')" ] && echo none)"

echo "=== P4-01: one trace per task, model call to tool call to ChangeRequest"
for _ in $(seq 1 30); do
  jaeger_trace "$TID" > $TMP/trace.json
  grep -q '"policy gate"' $TMP/trace.json && break; sleep 2
done
python3 scripts/trace_lines.py < $TMP/trace.json > $TMP/spans
spans=$(cat $TMP/spans)
check "root: the starter's 'agent task' span, for this task" "^safe-ops-agent \| agent task \| .*safeops.task=obs-$T" "$spans"
check "the workflow and its activities are in it" "RunWorkflow:AgentWorkflow" "$spans"
check "... including the child workflow that proposes" "RunActivity:propose" "$spans"
check "invoke_agent span: the decision, the prompt version" "\| invoke_agent safe-ops-agent \| .*safeops.decision=ScaleDeployment.*safeops.prompt_sha=[0-9a-f]{12}" "$spans"
agent_chats=$(grep -c '^safe-ops-agent | chat claude-opus-5-5 | .*gen_ai.operation.name=chat.*gen_ai.usage.input_tokens=[0-9]' $TMP/spans || true)
gw_chats=$(grep -c '^llm-gateway | chat claude-opus-5-5 | .*gen_ai.usage.input_tokens=[0-9].*safeops.cost_usd=.*safeops.identity=system:serviceaccount:agent:proposer' $TMP/spans || true)
check "chat spans with GenAI token counts: agent side (2: look up, then act)" '^2$' "$agent_chats"
check "... and the LLM gateway's, one per agent call, with cost and identity" "^$agent_chats$" "$gw_chats"
sum_tokens() { grep "^$1 | chat " $TMP/spans | grep -oE 'gen_ai.usage.(input|output)_tokens=[0-9]+' | cut -d= -f2 | paste -sd+ | bc; }
check "the agent's and the gateway's token counts agree" "^$(sum_tokens llm-gateway)$" "$(sum_tokens safe-ops-agent)"
check "execute_tool span for the incident lookup (agent)" '^safe-ops-agent \| execute_tool incidents__get_incident \| .*gen_ai.tool.name=incidents__get_incident' "$spans"
check "... and the MCP gateway's, allowed" '^mcp-gateway \| tools/call incidents__get_incident \| .*safeops.outcome=ok' "$spans"
check "the controller's gate decision on this ChangeRequest, in the same trace" \
  "^approval-controller \| policy gate \| .*safeops.changerequest=$NS/obs-$T .*safeops.policy.result=$RESULT" "$spans"
check "the ChangeRequest's annotation carries the task's trace" "^00-$TID-" "$(st obs-$T '{.metadata.annotations.approval\.safe-ops\.io/traceparent}')"
# Spans are exported in batches, every few seconds: wait for the decision's.
for _ in $(seq 1 20); do
  jaeger_trace "$TID_ESC" | python3 scripts/trace_lines.py > $TMP/spans-esc
  grep -q 'invoke_agent' $TMP/spans-esc && break; sleep 2
done
check "the escalating task's trace: decision Escalate, why: model_chose" \
  '\| invoke_agent safe-ops-agent \| .*safeops.decision=Escalate.*safeops.escalation=model_chose' "$(cat $TMP/spans-esc)"
refute "... and no gate decision in it (nothing was proposed)" 'policy gate' "$(cat $TMP/spans-esc)"
for _ in $(seq 1 30); do
  jaeger_trace "$TID_DENY" | python3 scripts/trace_lines.py > $TMP/spans-deny
  grep -q '| settle |' $TMP/spans-deny && break; sleep 2
done
check "the denied task's trace: the gate's Deny" "^approval-controller \| policy gate \| .*safeops.changerequest=$NS/obs-deny-$T .*safeops.policy.result=Deny" "$(cat $TMP/spans-deny)"
check "... and the request settled: Rejected, by the controller" \
  "^approval-controller \| settle \| .*safeops.changerequest=$NS/obs-deny-$T .*safeops.phase=Rejected .*safeops.settled_by=controller" "$(cat $TMP/spans-deny)"

echo "=== P4-03: no content in traces"
refute "the instruction's canary is in neither trace" "$CANARY" "$(cat $TMP/trace.json; jaeger_trace "$TID_ESC")"
keys=$(python3 scripts/trace_lines.py --keys < $TMP/trace.json)
refute "no content attributes (messages, instructions, tool arguments or results)" \
  '^gen_ai\.(input\.messages|output\.messages|system_instructions|tool\.call\.(arguments|result))$' "$keys"
PROBE=$(python3 -c 'import os; print(os.urandom(16).hex())')
check "a span with content, sent from the agent's pod straight to the collector, is accepted" '^200$' "$(in_agent span "$PROBE" "$CANARY-probe")"
for _ in $(seq 1 20); do jaeger_trace "$PROBE" > $TMP/probe.json; grep -q 'redaction probe' $TMP/probe.json && break; sleep 2; done
check "... and stored" '\| redaction probe \| safeops.task=redaction-probe$' "$(python3 scripts/trace_lines.py < $TMP/probe.json)"
refute "... with its content attributes and exception message stripped by the collector" "$CANARY-probe" "$(cat $TMP/probe.json)"
check "... keeping the exception's type" '^event:exception.type$' "$(python3 scripts/trace_lines.py --keys < $TMP/probe.json)"
FORGED=$(python3 -c 'import os; print(os.urandom(16).hex())')
in_agent span "$FORGED" "$CANARY-forged" llm-gateway >/dev/null
for _ in $(seq 1 20); do jaeger_trace "$FORGED" > $TMP/forged.json; grep -q 'redaction probe' $TMP/forged.json && break; sleep 2; done
if grep -q '^llm-gateway | redaction probe |' <<<"$(python3 scripts/trace_lines.py < $TMP/forged.json)"; then
  gap "GAP-06 a span the agent's pod sent as service llm-gateway is stored as the gateway's (docs/known-gaps.md)"
else
  pass "a span the agent's pod sent as another service isn't stored as that service's"
fi

echo "=== P4-02: tokens, cost, escalation in Prometheus"
for _ in $(seq 1 45); do
  [ "$(prom "$q_tasks")" = "$(python3 -c "print(int(float('$tasks0'))+3)")" ] && \
  python3 -c "import sys; sys.exit(0 if float('$(prom "$q_tok")') > float('$tok0') and float('$(prom 'sum(safeops_gate_decisions_total{result="'$RESULT'"})')') > float('$(eval echo \$gate_${RESULT}0)') else 1)" && break
  sleep 2
done
d() { python3 -c "print(round(float('$(prom "$1")') - float('$2'), 9))"; }
d_in=$(d "$q_in" "$in0"); d_out=$(d "$q_out" "$out0"); d_cost=$(d "$q_cost" "$cost0")
check "the agent reported 3 more tasks" '^3(\.0)?$' "$(d "$q_tasks" "$tasks0")"
check "... one of them an escalation, model_chose" '^1(\.0)?$' "$(d "$q_esc" "$esc0")"
check "the LLM gateway counted the proposer's tokens" '^[1-9][0-9]*(\.0)?$' "$(d "$q_tok" "$tok0")"
check "... and its estimated cost: input x \$$PRICE_IN + output x \$$PRICE_OUT per million" ok \
  "$(python3 -c "print('ok' if abs($d_cost - ($d_in*$PRICE_IN + $d_out*$PRICE_OUT)/1e6) < 1e-9 and $d_cost > 0 else 'cost $d_cost for $d_in in, $d_out out')")"
check "the gate's $RESULT decision was counted by the controller" '^[1-9]' "$(d "sum(safeops_gate_decisions_total{result=\"$RESULT\"})" "$(eval echo \$gate_${RESULT}0)")"
for _ in $(seq 1 20); do [ "$(d 'sum(safeops_gate_decisions_total{result="Deny"})' "$gate_Deny0")" != 0.0 ] && break; sleep 2; done
check "... and the Deny" '^[1-9]' "$(d 'sum(safeops_gate_decisions_total{result="Deny"})' "$gate_Deny0")"
check "the MCP gateway counted the incident lookup" '^1(\.0)?$' "$(d "$q_tool" "$tool0")"
# Both are eventually consistent (the agent exports every 10 s, Prometheus
# scrapes every 15 s): wait for the two counts to settle.
for _ in $(seq 1 20); do [ "$(d "$q_req" "$req0")" = "$(d "$q_calls" "$calls0")" ] && break; sleep 2; done
check "the gateway counted 4 model requests from the proposer (2 + 1 + 1)" '^4(\.0)?$' "$(d "$q_req" "$req0")"
check "... and the agent reported the same" "^$(d "$q_req" "$req0")$" "$(d "$q_calls" "$calls0")"

echo "=== Who can read and write telemetry"
noauth=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost:28443/metrics)
check "the controller's metrics without a token: 401" '^401$' "$noauth"
agent_tok=$(kubectl create token proposer -n agent --duration=10m)
check "... with the agent's token: 403" '^403$' "$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $agent_tok" https://localhost:28443/metrics)"
prom_tok=$(kubectl create token prometheus -n observability --duration=10m)
check "... with Prometheus's token: the metrics" '^safeops_gate_decisions_total\{' \
  "$(curl -sk -H "Authorization: Bearer $prom_tok" https://localhost:28443/metrics)"
check "the agent's pod reaches the collector (control)" '^connected$' "$(in_agent connect otel-collector.observability.svc.cluster.local 4318)"
for hp in "jaeger.observability.svc.cluster.local 16686" "jaeger.observability.svc.cluster.local 4317" \
          "prometheus.observability.svc.cluster.local 9090" "grafana.observability.svc.cluster.local 3000"; do
  check "the agent's pod can't reach ${hp/ /:}" '^(dns error|no connection)' "$(in_agent connect $hp)"
done
check "the agent's pod reaches the LLM gateway (control)" '^connected$' "$(in_agent connect llm-gateway.gateways.svc.cluster.local 8080)"
check "... but not its metrics port" '^no connection' "$(in_agent connect llm-gateway.gateways.svc.cluster.local 9090)"

echo "=== Grafana"
check "Grafana is healthy" '"database": ?"ok"' "$(curl -s localhost:23000/api/health)"
dash=$(curl -s localhost:23000/api/dashboards/uid/safe-ops-agent)
titles=$(python3 -c 'import json,sys; [print(p["title"]) for p in json.load(sys.stdin)["dashboard"]["panels"]]' <<<"$dash" 2>/dev/null || true)
for t in "Cost per task" "Agent escalation rate" "Gate escalation rate" "Tokens per minute by identity and type" "Recent agent traces"; do
  check "the provisioned dashboard (anonymous viewer) has '$t'" "^$t$" "$titles"
done
gq() { # EXPR: the dashboard's query, run through Grafana over the last 15 minutes
  python3 -c 'import json,sys; print(json.dumps({"from":"now-15m","to":"now","queries":[{"refId":"A","datasource":{"type":"prometheus","uid":"prometheus"},"expr":sys.argv[1],"instant":True}]}))' "$1" |
  curl -s -H 'Content-Type: application/json' localhost:23000/api/ds/query -d @- |
  python3 -c 'import json,sys; f=json.load(sys.stdin)["results"]["A"]["frames"]; print(f[0]["data"]["values"][1][0] if f and f[0]["data"]["values"] else "none")'
}
expr() { python3 -c 'import json,sys; [print(t["expr"].replace("$__range","15m")) for p in json.load(sys.stdin)["dashboard"]["panels"] if p["title"]==sys.argv[1] for t in p.get("targets",[])]' "$1" <<<"$dash"; }
check "Grafana answers 'Cost per task' with a cost" ok "$(python3 -c "v='$(gq "$(expr 'Cost per task')")'; print('ok' if v!='none' and float(v)>0 else v)")"
check "... and 'Agent escalation rate' with a share" ok "$(python3 -c "v='$(gq "$(expr 'Agent escalation rate')")'; print('ok' if v!='none' and 0<float(v)<=1 else v)")"
PW=$(kubectl get secret -n observability grafana-admin -o jsonpath='{.data.password}' | base64 -d)
for ds in prometheus jaeger; do
  check "Grafana's $ds datasource works" '"status": ?"OK"' "$(curl -s -u "admin:$PW" localhost:23000/api/datasources/uid/$ds/health)"
done

[ $FAILED = 0 ] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
