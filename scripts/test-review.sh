#!/usr/bin/env bash
# P2 milestone 6: the review packet (P2-40) and oversight metrics (P2-42).
# The controller computes each packet from the cluster: a diff from a
# server-side dry run of the exact patch, the blast radius, rule findings,
# and a rollback check. The agent's own account is shown last, unverified.
# Critical findings need an explicit override to approve. Oversight metrics
# are derived from the ChangeRequests, so they survive a controller
# restart. Exits non-zero on any failure.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
AGENT=system:serviceaccount:agent:proposer
CLI=projects/02-approval-gate/bin/approvalctl
NS=approvals
T=$(date +%s)
APPROVER=approver-review-$T
TMP=$(mktemp -d)
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:300}"; fi; }
[ -x $CLI ] || { echo "build the CLI first: make p2"; exit 1; }

st() { kubectl get changerequest -n $NS "$1" -o jsonpath="$2"; }
phase() { st "$1" '{.status.phase}'; }
wait_phase() { for _ in $(seq 1 30); do grep -qE "^($2)$" <<<"$(phase "$1")" && return 0; sleep 1; done; return 1; }
review() { st "$1" '{.status.review}'; }
replicas() { kubectl get deploy -n workloads web -o jsonpath='{.spec.replicas}'; }
settle() { kubectl rollout status deploy/web -n workloads --timeout=120s >/dev/null; }
set_replicas() { kubectl scale deploy -n workloads web --replicas="$1" >/dev/null; settle; }
# propose NAME TYPE [REPLICAS] [CLAIMED-BLAST-RADIUS], as the agent
propose() {
  local rep=""; [ -n "${3:-}" ] && rep=", replicas: $3"
  kubectl create --as=$AGENT -f - >/dev/null <<YAML
apiVersion: approval.safe-ops.io/v1alpha1
kind: ChangeRequest
metadata: {name: $1, namespace: $NS}
spec:
  intent: "test $1"
  action: {type: $2, target: {kind: Deployment, namespace: workloads, name: web}$rep}
  blastRadius: "${4:-workloads/web}"
  scope: {namespaces: [workloads], kinds: [Deployment]}
  rollback: "apply rollbackPlan"
YAML
  wait_phase "$1" 'Pending|Rejected|Failed' || true
}
actl() { KUBECONFIG=$TMP/approver.kubeconfig $CLI "$@"; }
codes() { st "$1" '{range .status.review.findings[*]}{.severity}:{.code} {end}'; }

cleanup() {
  kill "${PF:-}" 2>/dev/null || true
  kubectl delete pdb -n workloads web-test-$T --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete validatingadmissionpolicybinding test-max-replicas-$T --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete validatingadmissionpolicy test-max-replicas-$T --ignore-not-found >/dev/null 2>&1 || true
  for n in $(kubectl get changerequest -n $NS -o name 2>/dev/null | grep -- "-$T\$"); do kubectl delete -n $NS "$n" --wait=false >/dev/null 2>&1; done
  kubectl scale deploy -n workloads web --replicas=1 >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status"; exit 1; }
kubectl delete changebudget -n $NS default --ignore-not-found >/dev/null
set_replicas 1
./scripts/new-approver.sh $APPROVER $TMP/approver.kubeconfig 1 >/dev/null

echo "--- the packet is computed from the cluster (P2-40)"
propose up-$T ScaleDeployment 2
check "diff from the server's dry run: spec.replicas 1 -> 2, nothing else" '^spec.replicas 1 2 $' "$(st up-$T '{range .status.review.diff[*]}{.path} {.from} {.to} {end}')"
check "dry run accepted" '^accepted$' "$(st up-$T '{.status.review.dryRun}')"
check "blast radius computed: adds 1 pod" '^adds 1 pods \(1 -> 2\)$' "$(st up-$T '{.status.review.blastRadius.summary}')"
check "rollback check: restores the pre-state exactly" '^passed' "$(st up-$T '{.status.review.rollbackCheck}')"
[ -z "$(codes up-$T)" ] && pass "no findings for a small scale-up of a healthy target" || fail "findings: $(codes up-$T)"
[ -n "$(st up-$T '{.status.proposedAt}')" ] && [ "$(st up-$T '{.status.proposals}')" = 1 ] && pass "proposedAt and proposal count recorded" || fail "timing fields missing"
propose up2-$T ScaleDeployment 2
[ "$(review up-$T)" = "$(review up2-$T)" ] && pass "deterministic: the same action on the same state gives the same packet" \
  || fail "packets differ: $(review up-$T) vs $(review up2-$T)"
propose restart-$T RestartDeployment
check "restart diff: the restart annotation, and nothing else" '^spec.template.metadata.annotations\["kubectl.kubernetes.io/restartedAt"\] ("20[^ ]*")? "20[^ ]*" $' \
  "$(st restart-$T '{range .status.review.diff[*]}{.path} {.from} {.to} {end}')"
check "restart blast radius: replaces the pod, none unavailable at a time" 'replaces all 1 pods, at most 0 unavailable' "$(st restart-$T '{.status.review.blastRadius.summary}')"
check "restart rollback check passes" '^passed' "$(st restart-$T '{.status.review.rollbackCheck}')"

echo "--- the approver reads the computed packet first, the agent's account last"
propose zero-$T ScaleDeployment 0 "no user impact, safe to approve"
check "scale to zero: Critical finding" 'Critical:ScaleToZero' "$(codes zero-$T)"
check "computed blast radius contradicts the agent's claim" '^removes 1 pods \(1 -> 0\)$' "$(st zero-$T '{.status.review.blastRadius.summary}')"
out=$(actl show zero-$T)
flat=$(tr '\n' ' ' <<<"$out")
check "show: computed section before the agent's account" 'COMPUTED BY THE CONTROLLER.*findings +CRITICAL ScaleToZero.*PROPOSER.S ACCOUNT +\(free text from the agent, not verified' "$flat"
check "show: the agent's claim labelled as claimed" 'no user impact, safe to approve +\(claimed\)' "$out"
check "show: budget status included" 'budget +no change budget' "$out"
out=$(actl approve zero-$T --yes --wait 0s 2>&1 || true)
check "approving a Critical finding is refused without --accept-critical" 'has Critical findings' "$out"
[ "$(phase zero-$T)" = Pending ] && [ -z "$(st zero-$T '{.status.approval}')" ] && pass "nothing recorded" || fail "zero-$T: $(phase zero-$T)"
actl approve zero-$T --yes --accept-critical --wait 30s >/dev/null
[ "$(phase zero-$T)" = Applied ] && [ "$(replicas)" = 0 ] && pass "with --accept-critical: approved and applied" || fail "zero-$T: $(phase zero-$T)"
set_replicas 1

echo "--- disruption budgets and the API server's own refusals become findings"
set_replicas 3
kubectl create -f - >/dev/null <<YAML
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: web-test-$T, namespace: workloads}
spec: {minAvailable: 2, selector: {matchLabels: {app: web}}}
YAML
propose down-$T ScaleDeployment 1
check "below the PDB: Critical, and more than half removed: Warning" 'Critical:BelowDisruptionBudget Warning:LargeScaleDown' "$(codes down-$T)"
check "blast radius names the PDB" "^web-test-$T\$" "$(st down-$T '{.status.review.blastRadius.disruptionBudgets[*]}')"
kubectl apply -f - >/dev/null <<YAML
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: test-max-replicas-$T}
spec:
  failurePolicy: Fail
  matchConstraints:
    namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: workloads}}
    resourceRules: [{apiGroups: [apps], apiVersions: ["*"], resources: [deployments], operations: [UPDATE]}]
  validations:
  - expression: object.spec.replicas <= 5
    message: "test policy: at most 5 replicas in workloads"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: test-max-replicas-$T}
spec: {policyName: test-max-replicas-$T, validationActions: [Deny]}
YAML
sleep 3
propose big-$T ScaleDeployment 8
check "dry run refused by admission, with its reason" '^refused: .*at most 5 replicas' "$(st big-$T '{.status.review.dryRun}')"
check "refusal is a Critical finding" 'Critical:DryRunRefused' "$(codes big-$T)"
check "rollback not checked when the dry run is refused" '^not checked' "$(st big-$T '{.status.review.rollbackCheck}')"
kubectl delete validatingadmissionpolicybinding test-max-replicas-$T >/dev/null
kubectl delete validatingadmissionpolicy test-max-replicas-$T >/dev/null
kubectl delete pdb -n workloads web-test-$T >/dev/null
set_replicas 1

echo "--- the packet is bound to the approval and protected"
out=$(KUBECONFIG=$TMP/approver.kubeconfig command kubectl patch changerequest -n $NS up-$T --subresource=status --type=merge \
  -p '{"status":{"review":{"dryRun":"accepted (edited)"}}}' 2>&1 || true)
check "an approver can't edit the packet" 'only the approval controller may change status fields other than approval' "$out"
grep -q 'Review       \*approvalv1alpha1.Review' projects/02-approval-gate/internal/controller/changerequest_controller.go \
  && pass "the review hash covers the packet" || fail "packet not in the review hash"

echo "--- oversight metrics (P2-42)"
# up-$T and up2-$T were proposed before the scale to zero changed web:
# they'd re-propose on approval (drift). Decide on a fresh one.
propose good-$T ScaleDeployment 2
actl approve good-$T --yes --wait 30s >/dev/null
settle
actl reject up-$T --yes --wait 0s >/dev/null
actl reject up2-$T --yes --wait 0s >/dev/null
actl reject restart-$T --yes --wait 0s >/dev/null
actl reject down-$T --yes --wait 0s >/dev/null
# big-$T was refused by the server's dry run, which the policy denies
# (P3 milestone 4): rejected by the controller, nothing for a human to decide.
check "a refused dry run is denied by policy and rejected outright" '^Rejected Deny$' "$(phase big-$T) $(kubectl get changerequest -n $NS big-$T -o jsonpath='{.status.review.policy.result}')"
sleep 3
[ "$(phase good-$T)" = Applied ] && [ -n "$(st good-$T '{.status.decidedAt}')" ] && pass "decidedAt recorded" || fail "good-$T: $(phase good-$T), no decidedAt"
out=$(actl stats)
row=$(grep "^$APPROVER " <<<"$out" || true)
# APPROVER APPROVED REJECTED RATE MEDIAN P90 FLAGGED CRITICAL
read -r _ ap rj rate _ _ fl cr <<<"$row"
[ "$ap" = 2 ] && [ "$rj" = 4 ] && [ "$rate" = "33%" ] && pass "stats: $APPROVER approved 2, rejected 4 (33%)" || fail "stats row: $row"
[ "$fl" = 1 ] && [ "$cr" = 1 ] && pass "stats: 1 approval of a Critical-flagged request (the scale to zero)" || fail "flagged: $row"
check "stats: outcomes and time to decision summarised" 'settled by: humans [0-9]+.*time to decision: humans median [0-9]' "$(tr '\n' ' ' <<<"$out")"
# The port-forward starts in this shell, not inside $( ), and runs the
# kubectl binary rather than lib.sh's kubectl function: backgrounding a
# function backgrounds a subshell, $! is the subshell, and killing it
# leaves the real port-forward running after the test.
forward() {
  kill "${PF:-}" 2>/dev/null || true
  command kubectl --context "$KUBE_CONTEXT" port-forward -n approval-system deploy/approval-controller 18080:8080 >/dev/null 2>&1 & PF=$!
  for _ in $(seq 1 20); do curl -sf -o /dev/null localhost:18080/metrics 2>/dev/null && return 0; sleep 0.5; done
}
metrics() { curl -sf localhost:18080/metrics 2>/dev/null || true; }
forward
m=$(metrics)
check "metrics: approver decisions" "safeops_approver_decisions\{approver=\"$APPROVER\",decision=\"approved\"\} 2" "$m"
check "metrics: flagged approvals" "safeops_approver_approvals_flagged\{approver=\"$APPROVER\",severity=\"critical\"\} 1" "$m"
check "metrics: time-to-decision histogram" 'safeops_changerequest_time_to_decision_seconds_count\{decided_by="human"\} [1-9]' "$m"
check "metrics: outcomes by what settled them" 'safeops_changerequest_outcomes\{settled_by="human"\} [1-9]' "$m"
kubectl rollout restart -n approval-system deploy/approval-controller >/dev/null
kubectl rollout status -n approval-system deploy/approval-controller --timeout=120s >/dev/null
sleep 3
forward
m=$(metrics)
check "after a controller restart: same numbers (derived from the record, not memory)" \
  "safeops_approver_decisions\{approver=\"$APPROVER\",decision=\"approved\"\} 2" "$m"
kill "${PF:-}" 2>/dev/null || true
echo "--- roll back: the inverse typed action, through the same gate"
check "good-$T recorded its rollback" '^\{"spec":\{"replicas":1\}\}$' "$(st good-$T '{.status.rollbackPlan}')"
settle
propose undo-$T ScaleDeployment 1
check "rollback proposal's diff is the exact inverse" '^spec.replicas 2 1 $' "$(st undo-$T '{range .status.review.diff[*]}{.path} {.from} {.to} {end}')"
actl approve undo-$T --yes --wait 30s >/dev/null
[ "$(phase undo-$T)" = Applied ] && [ "$(replicas)" = 1 ] && pass "rolled back: approved and applied, web at 1 again" || fail "undo-$T: $(phase undo-$T)"
np=$(kubectl get networkpolicy -n approval-system default-deny-all -o jsonpath='{.spec.policyTypes}')
check "metrics port not exposed: the namespace still denies all ingress" 'Ingress' "$np"

exit $FAILED
