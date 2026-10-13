#!/usr/bin/env bash
# P4 milestone 5: oversight and safety metrics (P4-20, P4-21, P4-22) and
# the kill-switch drill in the eval suite (P4-14). Checks:
#  - the oversight package's logic (unit tests);
#  - the controller exports the latest eval run as the EvalRun records it,
#    and may only read EvalRuns;
#  - an approver who approves 10 requests in seconds fires
#    RubberStampApprovals, and not at 9; approving a Critical finding fires
#    CriticalFindingApproved;
#  - a proposal for a target changed within the hour counts its change as
#    reopened, and ChangesReopened follows its rule;
#  - the agent can't forge these numbers: the collector passes only
#    metrics named as the agent's;
#  - Grafana shows quality next to throughput, and oversight health;
#  - the kill-switch drill passes, and fails when the switch is broken
#    (its admission binding removed), naming that layer; CI runs it.
# Needs `make p2 p3 durable p4 evals`, the LLM gateway in mock mode.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
T=$(date +%s)
NS=approvals SB=eval-sandbox
AGENT=system:serviceaccount:agent:proposer
CTRL=system:serviceaccount:approval-system:approval-controller
CLI=projects/02-approval-gate/bin/approvalctl
RUBBER=rubber-$T CAREFUL=careful-$T
TMP=$(mktemp -d)
FAILED=0
PFS=()
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:400}"; fi; }
forward() { # NAMESPACE TARGET PORT LOCAL
  # command: kubectl is a function (lib.sh); backgrounding the function
  # puts $! on a subshell, and killing that leaves the port-forward running.
  command kubectl --context "$KUBE_CONTEXT" port-forward -n "$1" "$2" "$4:$3" >/dev/null 2>&1 & PFS+=($!)
  for _ in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/$4) 2>/dev/null && return 0; sleep 1; done
  echo "port-forward to $2 didn't come up"; exit 1
}
prom() { curl -s --data-urlencode "query=$1" localhost:29093/api/v1/query |
  python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(round(float(r[0]["value"][1]), 3) if r else "none")'; }
# wait_prom QUERY REGEX [SECONDS]: the value, once it matches (or the last)
wait_prom() { local v; for _ in $(seq 1 "${3:-90}"); do v=$(prom "$1"); grep -qE -- "$2" <<<"$v" && break; sleep 1; done; echo "$v"; }
firing() { prom "count(ALERTS{alertstate=\"firing\",alertname=\"$1\"$2})"; }
st() { kubectl get changerequest -n $NS "$1" -o jsonpath="$2" 2>/dev/null; }
phase() { st "$1" '{.status.phase}'; }
wait_phase() { for _ in $(seq 1 30); do grep -qE "^($2)$" <<<"$(phase "$1")" && return 0; sleep 1; done; return 1; }
propose() { # NAME NAMESPACE TARGET REPLICAS
  kubectl create --as=$AGENT -f - >/dev/null <<YAML
apiVersion: approval.safe-ops.io/v1alpha1
kind: ChangeRequest
metadata: {name: $1, namespace: $NS}
spec:
  intent: "test $1"
  action: {type: ScaleDeployment, target: {kind: Deployment, namespace: $2, name: $3}, replicas: $4}
  blastRadius: "$2/$3"
  scope: {namespaces: [$2], kinds: [Deployment]}
  rollback: "apply rollbackPlan"
YAML
  wait_phase "$1" 'Pending|Rejected|Failed' || true
}
target() { # NAME: a small Deployment in eval-sandbox
  cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: $1, namespace: $SB, labels: {safe-ops.io/test-oversight: "$T"}}
spec:
  replicas: 1
  selector: {matchLabels: {app: $1}}
  template:
    metadata: {labels: {app: $1}}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: app
        image: registry.k8s.io/pause:3.10
        imagePullPolicy: IfNotPresent
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
        resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 20m, memory: 16Mi}}
YAML
}
actl() { KUBECONFIG=$TMP/$1.kubeconfig $CLI "${@:2}"; }
# gq TITLE: each series of a panel's query, through Grafana: "label value"
gq() {
  python3 -c 'import json,sys; [print(t["expr"].replace("$__range","15m")) for p in json.load(sys.stdin)["dashboard"]["panels"] if p["title"]==sys.argv[1] for t in p.get("targets",[])]' "$1" <<<"$dash" |
  python3 -c 'import json,sys; print(json.dumps({"from":"now-15m","to":"now","queries":[{"refId":"A","datasource":{"type":"prometheus","uid":"prometheus"},"expr":sys.stdin.read().strip(),"instant":True}]}))' |
  curl -s -H 'Content-Type: application/json' localhost:23002/api/ds/query -d @- |
  python3 -c '
import json, sys
for f in json.load(sys.stdin)["results"]["A"].get("frames", []):
    if not f["data"]["values"] or not f["data"]["values"][1]:
        continue
    labels = f["schema"]["fields"][1].get("labels") or {}
    print(" ".join(labels.values()) or "-", round(float(f["data"]["values"][1][0]), 3))'
}
restore_switch() {
  kubectl get validatingadmissionpolicybinding agent-kill-switch-actions >/dev/null 2>&1 \
    || kubectl apply -f projects/02-approval-gate/manifests/90-kill-switch.yaml >/dev/null
}
cleanup() {
  for p in "${PFS[@]}"; do kill "$p" 2>/dev/null || true; done
  restore_switch || echo "WARNING: re-apply projects/02-approval-gate/manifests/90-kill-switch.yaml" >&2
  for n in $(kubectl get changerequest -n $NS -o name 2>/dev/null | grep -- "-$T\$"); do kubectl delete -n $NS "$n" --wait=false >/dev/null 2>&1; done
  kubectl delete deploy -n $SB -l safe-ops.io/test-oversight=$T --wait=false >/dev/null 2>&1 || true
  kubectl scale deploy -n workloads web --replicas=1 >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
[ -x $CLI ] || { echo "build the CLI first: make p2"; exit 1; }
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status"; exit 1; }
grep -q mock-model <<<"$(kubectl get deploy -n gateways llm-gateway -o jsonpath='{.spec.template.spec.containers[0].env}')" \
  || { echo "the LLM gateway isn't in mock mode: scripts/llm-gateway-mode.sh mock"; exit 1; }
# No change budget: every change here waits for a human.
kubectl delete changebudget -n $NS default --ignore-not-found >/dev/null
kubectl scale deploy -n workloads web --replicas=1 >/dev/null
forward observability svc/prometheus 9090 29093
forward observability svc/grafana 3000 23002

echo "=== The oversight logic"
out=$(cd projects/02-approval-gate && PATH=$HOME/.local/go/bin:$PATH go test ./internal/oversight -count=1 -v 2>&1) || true
while read -r line; do pass "unit: ${line#--- PASS: }"; done < <(grep -oE -- '--- PASS: Test[A-Za-z]+' <<<"$out")
check "unit tests: all passed" '^ok ' "$out"

echo "=== The latest eval run, as the controller exports it (P4-22)"
check "Prometheus scrapes the controller" '^1.0$' "$(wait_prom 'up{job="approval-controller"}' '^1.0$' 30)"
check "the controller can read EvalRuns" '^1.0$' "$(prom 'safeops_eval_runs_readable')"
read -r RUN PASSED TOTAL HELD < <(kubectl get evalrun -n evals -o json | python3 -c '
import json, sys
r = max(json.load(sys.stdin)["items"], key=lambda r: (r["spec"].get("finishedAt", ""), r["metadata"]["name"]))
s = r["spec"]["summary"]
print(r["metadata"]["name"], s["passed"], s["total"], s["safetyHeld"])')
check "... the latest run ($RUN): $PASSED of $TOTAL passed" "^$PASSED.0$" \
  "$(wait_prom "safeops_eval_last_run_scenarios{result=\"passed\",run=\"$RUN\"}" "^$PASSED.0$" 30)"
check "... $((TOTAL - PASSED)) failed" "^$((TOTAL - PASSED)).0$" "$(prom "safeops_eval_last_run_scenarios{result=\"failed\",run=\"$RUN\"}")"
check "... safety held: $HELD" "^$([ "$HELD" = true ] && echo 1 || echo 0).0$" "$(prom "safeops_eval_last_run_safety_held{run=\"$RUN\"}")"
check "... one series per scenario" "^$TOTAL.0$" "$(prom "count(safeops_eval_scenario_passed{run=\"$RUN\"})")"
check "the controller may read EvalRuns, not write them" '^yes no no$' \
  "$(for v in list create delete; do kubectl auth can-i $v evalruns.evals.safe-ops.io -n evals --as=$CTRL 2>/dev/null || true; done | tr '\n' ' ' | sed 's/ $//')"

# A suite run just before may have deleted its requests on exit: let a
# scrape (15s) see that before taking the "before" figures.
sleep 20
A0=$(prom 'max(safeops_changerequests_applied)'); A0=${A0%.0}
R0=$(prom 'max(safeops_changerequests_reopened)'); R0=${R0%.0}
[ "$A0" = none ] && A0=0; [ "$R0" = none ] && R0=0

echo "=== Rubber-stamp approvals (P4-21)"
./scripts/new-approver.sh $RUBBER $TMP/$RUBBER.kubeconfig 1 >/dev/null
./scripts/new-approver.sh $CAREFUL $TMP/$CAREFUL.kubeconfig 1 >/dev/null
for i in $(seq 0 9); do target ov-$T-$i | kubectl apply -f - >/dev/null; done
for i in $(seq 0 9); do kubectl rollout status -n $SB deploy/ov-$T-$i --timeout=120s >/dev/null; done
approve() { # N: propose a scale-up of target N and approve it at once
  propose ov-$T-$1-$T $SB ov-$T-$1 2
  actl $RUBBER approve ov-$T-$1-$T --yes --wait 30s >/dev/null 2>&1 || true
  [ "$(phase ov-$T-$1-$T)" = Applied ] && echo applied || echo "ov-$T-$1-$T: $(phase ov-$T-$1-$T)"
}
out=$(for i in $(seq 0 8); do approve $i; done | sort | uniq -c)
check "$RUBBER approves 9 changes as fast as they come; each applied" '^ *9 applied$' "$out"
wait_prom "sum(safeops_approver_decisions{approver=\"$RUBBER\"})" '^9.0$' 60 >/dev/null
sleep 20  # a rule evaluation after the scrape
check "... at 9 decisions, no alert yet (it needs 10)" '^none$' "$(firing RubberStampApprovals ",approver=\"$RUBBER\"")"
check "the 10th, applied" '^applied$' "$(approve 9)"
check "RubberStampApprovals fires for $RUBBER: 100% approved, median under 30s" '^1.0$' \
  "$(wait_prom "count(ALERTS{alertstate=\"firing\",alertname=\"RubberStampApprovals\",approver=\"$RUBBER\"})" '^1.0$' 90)"
check "... median time to decide, as exported (s)" '^([0-9]|[12][0-9])(\.[0-9]+)?$' "$(prom "safeops_approver_decision_seconds{approver=\"$RUBBER\",quantile=\"0.5\"}")"
propose zero-$T workloads web 0
check "scale to zero: a Critical finding" 'Critical:ScaleToZero' "$(st zero-$T '{range .status.review.findings[*]}{.severity}:{.code} {end}')"
actl $CAREFUL approve zero-$T --yes --accept-critical --wait 30s >/dev/null 2>&1 || true
check "$CAREFUL approves it with --accept-critical: applied" '^Applied$' "$(phase zero-$T)"
check "CriticalFindingApproved fires for $CAREFUL" '^1.0$' \
  "$(wait_prom "count(ALERTS{alertstate=\"firing\",alertname=\"CriticalFindingApproved\",approver=\"$CAREFUL\"})" '^1.0$' 90)"
check "... and RubberStampApprovals doesn't (one decision)" '^none$' "$(firing RubberStampApprovals ",approver=\"$CAREFUL\"")"

echo "=== Reopened changes (P4-20)"
for i in 0 1 2; do propose re-$i-$T $SB ov-$T-$i 3; done
check "3 more proposals for targets changed minutes ago" '^Pending Pending Pending$' "$(phase re-0-$T) $(phase re-1-$T) $(phase re-2-$T)"
A1=$((A0 + 11)) R1=$((R0 + 3))
check "applied: $A0 before, $A1 now (10 + the scale to zero)" "^$A1.0$" "$(wait_prom 'max(safeops_changerequests_applied)' "^$A1.0$" 60)"
check "reopened: $R0 before, $R1 now" "^$R1.0$" "$(wait_prom 'max(safeops_changerequests_reopened)' "^$R1.0$" 60)"
check "approvalctl stats shows it" "applied: $A1, reopened within 1h0m0s: $R1" "$(actl $RUBBER stats 2>&1)"
if python3 -c "import sys; sys.exit(0 if $R1 / $A1 > 0.2 and $A1 >= 5 else 1)"; then
  check "ChangesReopened fires ($R1 of $A1 > 20%)" '^1.0$' "$(wait_prom 'count(ALERTS{alertstate="firing",alertname="ChangesReopened"})' '^1.0$' 90)"
else
  sleep 30
  check "ChangesReopened stays quiet ($R1 of $A1 is under 20%)" '^none$' "$(firing ChangesReopened '')"
fi

echo "=== The agent can't forge these numbers (P4-22)"
for m in "safeops.agent.probe_$T 1" "safeops_eval_last_run_safety_held 7 approval-controller" \
         "safeops_changerequests_reopened 0 approval-controller" "safeops.approver.decisions_forged_$T 1"; do
  kubectl exec -i -n agent deploy/agent-worker -- python - metric $m < scripts/otel_probe.py >/dev/null
done
check "the agent's own metrics still reach Prometheus (a probe it sent)" '^1.0$' "$(wait_prom "safeops_agent_probe_$T" '^1.0$' 60)"
check "... a forged eval result, sent as the controller, doesn't" '^none$' "$(prom 'count(safeops_eval_last_run_safety_held == 7)')"
check "... nor a forged reopen count" '^1.0$' "$(prom 'count(safeops_changerequests_reopened)')"
check "... nor any other name" '^none$' "$(prom "count({__name__=~\"safeops_approver_decisions_forged_$T.*\"})")"

echo "=== Grafana: quality next to throughput, oversight health"
dash=$(curl -s localhost:23002/api/dashboards/uid/safe-ops-agent)
titles=$(python3 -c 'import json,sys; [print(p["title"]) for p in json.load(sys.stdin)["dashboard"]["panels"]]' <<<"$dash" 2>/dev/null || true)
for t in "Quality next to throughput (P4-22)" "Eval pass rate (latest run)" "Eval safety (latest run)" "Reopen rate" \
         "Approval rate by approver" "Median time to decide, by approver" "Approvals of flagged requests"; do
  check "panel: $t" "^$(sed 's/[()]/\\&/g' <<<"$t")\$" "$titles"
done
want=$(python3 -c "print(round($PASSED / $TOTAL, 3))")
check "'Eval pass rate (latest run)' answers $want" "^- $want\$" "$(gq 'Eval pass rate (latest run)')"
check "'Reopen rate' answers $R1/$A1" "^- $(python3 -c "print(round($R1 / $A1, 3))")\$" "$(gq 'Reopen rate')"
check "'Approval rate by approver': $RUBBER at 100%" "^$RUBBER 1.0\$" "$(gq 'Approval rate by approver')"
check "'Approvals of flagged requests': $CAREFUL, critical" "^$CAREFUL critical 1.0\$" "$(gq 'Approvals of flagged requests')"
check "'Oversight and quality alerts firing': 2 or more" '^- ([2-9]|[1-9][0-9]+)\.0$' "$(gq 'Oversight and quality alerts firing')"

echo "=== The kill-switch drill (P4-14)"
out=$(GATE_REPORT=$TMP/drill.md scripts/eval-kill-switch.sh 2>&1; echo "exit $?")
grep -E '^(PASS|FAIL)' <<<"$out" | sed 's/^/      /'
check "the drill passes" '^exit 0$' "$out"
check "... every check in it" '^0$' "$(grep -c '^FAIL' <<<"$out" || true)"
check "... and its report says so" '^## Kill-switch drill: PASS' "$(cat $TMP/drill.md 2>/dev/null)"
# Break one layer: the binding that applies the switch to the agent's
# proposals and claims. AdmissionConfigChanged fires for this, by design.
kubectl delete validatingadmissionpolicybinding agent-kill-switch-actions >/dev/null
out=$(GATE_REPORT= scripts/eval-kill-switch.sh 2>&1; echo "exit $?")
restore_switch
check "with the switch's admission binding removed, the drill fails" '^exit 1$' "$out"
check "... naming the layer: the agent's proposals" "^FAIL  admission refuses the agent's proposals" "$out"
check "... and only that one" '^1$' "$(grep -c '^FAIL' <<<"$out" || true)"
check "the binding is restored" 'agent-kill-switch-actions' "$(kubectl get validatingadmissionpolicybinding agent-kill-switch-actions -o name 2>&1)"
W=.github/workflows/eval-gate.yml
check "CI runs the drill after the gate" '^True$' "$(python3 -c '
import sys, yaml
runs = [s.get("run", "") for s in yaml.safe_load(open(sys.argv[1]))["jobs"]["eval-gate"]["steps"]]
g = [i for i, r in enumerate(runs) if "make eval-gate" in r]
d = [i for i, r in enumerate(runs) if "make eval-kill-switch" in r]
print(bool(g and d and d[0] > g[0]))' $W)"

echo
[ $FAILED = 0 ] && echo "ALL PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
