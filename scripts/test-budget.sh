#!/usr/bin/env bash
# P2 milestone 4: the change budget (P2-20). With a ChangeBudget in place,
# eligible changes the agent proposes are applied without a human until the
# budget is spent; then every change waits for an approver. Ineligible
# changes always wait. Nobody but operators can change the budget, and
# nobody but the controller can record that it paid for a change. Creates
# the budget for the run and deletes it afterwards (no budget is the
# default). Exits non-zero on any failure.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
AGENT=system:serviceaccount:agent:agent
CLI=projects/02-approval-gate/bin/approvalctl
NS=approvals
T=$(date +%s)
APPROVER=approver-budget-$T
TMP=$(mktemp -d)
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:250}"; fi; }
[ -x $CLI ] || { echo "build the CLI first: make p2"; exit 1; }

replicas() { kubectl get deploy -n workloads web -o jsonpath='{.spec.replicas}'; }
st() { kubectl get changerequest -n $NS "$1" -o jsonpath="$2"; }
phase() { st "$1" '{.status.phase}'; }
wait_phase() { for _ in $(seq 1 30); do grep -qE "^($2)$" <<<"$(phase "$1")" && return 0; sleep 1; done; return 1; }
# propose NAME TYPE [REPLICAS], as the agent
propose() {
  local rep=""; [ -n "${3:-}" ] && rep=", replicas: $3"
  kubectl create --as=$AGENT -f - >/dev/null <<YAML
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
budget() { # MAX WINDOW-SECONDS
  kubectl apply -f - >/dev/null <<YAML
apiVersion: approval.safe-ops.io/v1alpha1
kind: ChangeBudget
metadata: {name: default, namespace: $NS}
spec:
  maxChanges: $1
  windowSeconds: $2
  actions: [RestartDeployment, ScaleDeployment]
  namespaces: [workloads]
  minReplicas: 1
  maxReplicas: 3
YAML
}
actl() { KUBECONFIG=$TMP/approver.kubeconfig $CLI "$@"; }
cleanup() {
  kubectl delete changebudget -n $NS default --ignore-not-found >/dev/null 2>&1 || true
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

echo "--- no budget: every change waits for a human (the default)"
propose none-$T RestartDeployment
wait_phase none-$T Pending && check "no budget: Pending" 'no change budget' "$(st none-$T '{.status.message}')" || fail "no budget: $(phase none-$T)"

echo "--- within budget: applied without a human (2 per window)"
budget 2 3600
out=$(kubectl create -f - --dry-run=server 2>&1 <<YAML || true
apiVersion: approval.safe-ops.io/v1alpha1
kind: ChangeBudget
metadata: {name: bad, namespace: $NS}
spec: {maxChanges: 1, actions: [ScaleDeployment], namespaces: [workloads], minReplicas: 3, maxReplicas: 2}
YAML
)
check "budget schema: minReplicas above maxReplicas rejected" 'minReplicas must not exceed maxReplicas' "$out"
propose big-$T ScaleDeployment 9
wait_phase big-$T Pending && check "scale to 9 (outside 1-3): waits for a human" 'not covered by the change budget: scaling to 9' "$(st big-$T '{.status.message}')" \
  || fail "scale to 9: $(phase big-$T)"
propose zero-$T ScaleDeployment 0
wait_phase zero-$T Pending && check "scale to 0: waits for a human" 'not covered.*scaling to 0' "$(st zero-$T '{.status.message}')" || fail "scale to 0: $(phase zero-$T)"
propose auto1-$T ScaleDeployment 2
wait_phase auto1-$T Applied && pass "scale to 2: Applied with no approval" || fail "scale to 2: $(phase auto1-$T) $(st auto1-$T '{.status.message}')"
[ "$(replicas)" = 2 ] && pass "web scaled to 2" || fail "web has $(replicas) replicas"
[ -z "$(st auto1-$T '{.status.approval}')" ] && [ "$(st auto1-$T '{.status.budgetGrant.budget}')" = default ] \
  && pass "recorded as paid by budget default, no human approval" || fail "grant: $(st auto1-$T '{.status.budgetGrant}') approval: $(st auto1-$T '{.status.approval}')"
[ "$(st auto1-$T '{.status.budgetGrant.reviewHash}')" = "$(st auto1-$T '{.status.reviewHash}')" ] \
  && pass "grant bound to the review hash" || fail "grant hash differs from the review hash"
[ -n "$(st auto1-$T '{.status.plan}')" ] && [ -n "$(st auto1-$T '{.status.rollbackPlan}')" ] \
  && pass "plan and rollback still recorded before applying (P2-05)" || fail "plan or rollback missing"
check "message says who approved" 'applied \(approved by change budget default\)' "$(st auto1-$T '{.status.message}')"
propose auto2-$T RestartDeployment
wait_phase auto2-$T Applied && pass "restart: Applied with no approval (2 of 2)" || fail "restart: $(phase auto2-$T) $(st auto2-$T '{.status.message}')"

echo "--- budget spent: the agent must ask"
propose over-$T ScaleDeployment 3
wait_phase over-$T Pending && check "third change: Pending, budget spent" 'change budget default is spent \(2 of 2' "$(st over-$T '{.status.message}')" \
  || fail "third change: $(phase over-$T) $(st over-$T '{.status.message}')"
[ "$(replicas)" = 2 ] && pass "nothing applied past the budget" || fail "web has $(replicas) replicas"
[ "$(kubectl get changebudget -n $NS default -o jsonpath='{.status.grants[*].changeRequest}')" = "auto1-$T auto2-$T" ] \
  && pass "budget status lists the 2 grants" || fail "grants: $(kubectl get changebudget -n $NS default -o jsonpath='{.status.grants}')"
out=$(actl budget)
check "approvalctl budget: 0 of 2 remaining" 'remaining +0 of 2' "$out"
actl approve over-$T --yes --wait 30s >/dev/null && [ "$(phase over-$T)" = Applied ] && [ "$(replicas)" = 3 ] \
  && pass "a human approval still applies it" || fail "human approval after budget: $(phase over-$T)"
[ "$(kubectl get changebudget -n $NS default -o jsonpath='{.status.grants[*].changeRequest}')" = "auto1-$T auto2-$T" ] \
  && pass "human-approved changes don't spend budget" || fail "grants changed: $(kubectl get changebudget -n $NS default -o jsonpath='{.status.grants}')"

echo "--- the window rolls: budget frees up"
budget 2 10
sleep 11
out=$(actl budget)
check "after the window: 2 of 2 remaining" 'remaining +2 of 2' "$out"
propose later-$T ScaleDeployment 1
wait_phase later-$T Applied && pass "change after the window: Applied with no approval" || fail "after window: $(phase later-$T) $(st later-$T '{.status.message}')"
[ "$(kubectl get changebudget -n $NS default -o jsonpath='{.status.grants[*].changeRequest}')" = "later-$T" ] \
  && pass "expired grants pruned" || fail "grants: $(kubectl get changebudget -n $NS default -o jsonpath='{.status.grants}')"
[ "$(phase over-$T)" = Applied ] && [ "$(phase big-$T)" = Pending ] \
  && pass "a request that waited for a human keeps waiting when budget frees up" || fail "big: $(phase big-$T)"

echo "--- concurrent proposals can't overspend"
budget 1 3600
kubectl patch changebudget -n $NS default --subresource=status --type=merge -p '{"status":{"grants":null}}' >/dev/null
for i in 1 2 3 4; do propose race$i-$T RestartDeployment & done; wait
sleep 3; for i in 1 2 3 4; do wait_phase race$i-$T 'Applied|Pending' || true; done
applied=0; for i in 1 2 3 4; do [ "$(phase race$i-$T)" = Applied ] && applied=$((applied+1)); done
[ $applied = 1 ] && pass "4 at once against a budget of 1: exactly 1 applied" || fail "$applied of 4 applied with a budget of 1"

echo "--- who may change the budget"
can() { kubectl auth can-i "$@" 2>/dev/null || true; }
for v in create update patch delete; do
  [ "$(can $v changebudgets.approval.safe-ops.io -n $NS --as=$AGENT)" = no ] && pass "agent may not $v budgets" || fail "agent MAY $v budgets"
done
[ "$(can patch changebudgets.approval.safe-ops.io/status -n $NS --as=$AGENT)" = no ] && pass "agent may not write budget status" || fail "agent MAY write budget status"
[ "$(can patch changebudgets.approval.safe-ops.io -n $NS --as=$APPROVER --as-group=safe-ops:approvers)" = no ] \
  && pass "approvers may not change the budget" || fail "approvers MAY change the budget"
G='{"status":{"budgetGrant":{"budget":"default","reviewHash":"'"$(st big-$T '{.status.reviewHash}')"'","time":"2026-01-01T00:00:00Z"}}}'
out=$(KUBECONFIG=$TMP/approver.kubeconfig command kubectl patch changerequest -n $NS big-$T --subresource=status --type=merge -p "$G" 2>&1 || true)
check "an approver can't forge a budget grant" 'only the approval controller may change status fields other than approval' "$out"
out=$(kubectl patch changerequest -n $NS big-$T --subresource=status --type=merge -p "$G" 2>&1 || true)
check "nor can a cluster admin" 'only the approval controller may change status fields other than approval' "$out"
[ "$(phase big-$T)" = Pending ] && pass "big-$T still Pending" || fail "big-$T is $(phase big-$T)"

exit $FAILED
