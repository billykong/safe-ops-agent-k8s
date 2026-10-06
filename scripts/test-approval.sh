#!/usr/bin/env bash
# P2 milestone 1: ChangeRequest CRD, approval controller, and the agent's
# fence. The agent proposes (as system:serviceaccount:agent:agent); a human
# (this kubeconfig's identity) approves through the status subresource; the
# controller applies. Each closure is checked with a negative control.
# Exits non-zero on any failure.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
AGENT=system:serviceaccount:agent:agent
CTRL=system:serviceaccount:approval-system:approval-controller
NS=approvals
T=$(date +%s)
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:250}"; fi; }

replicas() { kubectl get deploy -n workloads web -o jsonpath='{.spec.replicas}'; }
phase() { kubectl get changerequest -n $NS "$1" -o jsonpath='{.status.phase}'; }
st() { kubectl get changerequest -n $NS "$1" -o jsonpath="$2"; }
wait_phase() { # name phase-regex
  for _ in $(seq 1 30); do grep -qE "^($2)$" <<<"$(phase "$1")" && return 0; sleep 1; done; return 1
}
# cr NAME TYPE TARGET-NS SCOPE-NS [REPLICAS] -> manifest on stdout
cr() {
  local rep=""; [ -n "${5:-}" ] && rep=", replicas: $5"
  cat <<YAML
apiVersion: approval.safe-ops.io/v1alpha1
kind: ChangeRequest
metadata: {name: $1, namespace: $NS}
spec:
  intent: "test $1"
  action: {type: $2, target: {kind: Deployment, namespace: $3, name: web}$rep}
  blastRadius: "workloads/web"
  scope: {namespaces: [$4], kinds: [Deployment]}
  rollback: "apply rollbackPlan"
YAML
}
propose() { cr "$@" | kubectl create --as=$AGENT -f - >/dev/null; }
decide() { # name decision: a human writes the approval through the status subresource
  kubectl patch changerequest -n $NS "$1" --subresource=status --type=merge -p \
    "{\"status\":{\"approval\":{\"decision\":\"$2\",\"approver\":\"$(kubectl config view --minify -o jsonpath='{.users[0].name}')\",\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}}" >/dev/null
}
cleanup() { kubectl delete changerequest -n $NS -l test-run=$T --ignore-not-found --wait=false >/dev/null 2>&1 || true
            for n in $(kubectl get changerequest -n $NS -o name 2>/dev/null | grep -- "-$T\$"); do kubectl delete -n $NS "$n" --wait=false >/dev/null 2>&1; done; }
trap cleanup EXIT
kubectl scale deploy -n workloads web --replicas=1 >/dev/null

echo "--- CRD: proposals are well-formed and immutable (P2-01, P2-02)"
out=$(cr bad-$T ScaleDeployment workloads workloads | kubectl create --dry-run=server -f - 2>&1 || true)
check "ScaleDeployment without replicas rejected" 'ScaleDeployment needs replicas' "$out"
out=$(cr bad-$T ScaleDeployment workloads workloads 2 | sed 's/type: ScaleDeployment/type: DeleteNamespace/' | kubectl create --dry-run=server -f - 2>&1 || true)
check "unknown action type rejected" 'Unsupported value: "DeleteNamespace"' "$out"
propose imm-$T ScaleDeployment workloads workloads 1
out=$(kubectl patch changerequest -n $NS imm-$T --type=merge -p '{"spec":{"action":{"replicas":9}}}' 2>&1 || true)
check "spec change rejected, even for an admin" 'spec is immutable' "$out"

echo "--- agent's fence (P2-10, P2-14)"
can() { kubectl auth can-i "$@" --as=$AGENT 2>/dev/null || true; }
expect() { local want=$1 desc=$2; shift 2; [ "$(can "$@")" = "$want" ] && pass "$desc" || fail "$desc"; }
expect yes "agent may create changerequests"            create changerequests.approval.safe-ops.io -n $NS
expect no  "agent may not update changerequests"        update changerequests.approval.safe-ops.io -n $NS
expect no  "agent may not delete changerequests"        delete changerequests.approval.safe-ops.io -n $NS
expect no  "agent may not update changerequests/status" update changerequests.approval.safe-ops.io --subresource=status -n $NS
expect no  "agent may not patch changerequests/status"  patch changerequests.approval.safe-ops.io --subresource=status -n $NS
expect no  "agent may not patch deployments in workloads" patch deployments.apps -n workloads
expect no  "agent may not create pods in workloads"     create pods -n workloads
expect no  "agent may not touch the controller"         patch deployments.apps -n approval-system
expect no  "agent may not edit CRDs"                    update customresourcedefinitions.apiextensions.k8s.io
expect no  "agent may not edit RBAC"                    create rolebindings.rbac.authorization.k8s.io -n $NS
# Not just can-i: an actual self-approval attempt.
out=$(kubectl patch changerequest -n $NS imm-$T --as=$AGENT --subresource=status --type=merge \
  -p '{"status":{"approval":{"decision":"Approved","approver":"agent","time":"2026-01-01T00:00:00Z"}}}' 2>&1 || true)
check "agent's self-approval attempt is forbidden" 'forbidden' "$out"

echo "--- controller's own reach (P2-03: never cluster-admin)"
cc() { kubectl auth can-i "$@" --as=$CTRL 2>/dev/null || true; }
[ "$(cc patch deployments.apps -n workloads)" = yes ] && pass "controller may patch deployments in workloads" || fail "controller can't patch workloads"
[ "$(cc patch deployments.apps -n kube-system)" = no ] && pass "controller may not patch deployments elsewhere" || fail "controller can patch kube-system"
[ "$(cc delete deployments.apps -n workloads)" = no ] && pass "controller may not delete deployments" || fail "controller can delete"
[ "$(cc create pods -n workloads)" = no ] && pass "controller may not create pods" || fail "controller can create pods"
[ "$(cc update changerequests.approval.safe-ops.io -n $NS)" = no ] && pass "controller may not edit proposals" || fail "controller can edit proposals"

echo "--- propose, approve, apply"
propose scale-$T ScaleDeployment workloads workloads 2
wait_phase scale-$T Pending && pass "proposal recorded: Pending" || fail "proposal not Pending: $(phase scale-$T)"
check "pre-state recorded" '"replicas":1' "$(st scale-$T '{.status.preState}')"
check "exact plan recorded" '^\{"spec":\{"replicas":2\}\}$' "$(st scale-$T '{.status.plan}')"
check "exact rollback recorded" '^\{"spec":\{"replicas":1\}\}$' "$(st scale-$T '{.status.rollbackPlan}')"
sleep 3
[ "$(replicas)" = 1 ] && pass "nothing applied before approval" || fail "target changed before approval: $(replicas)"
decide scale-$T Approved
wait_phase scale-$T Applied && pass "approved: Applied" || fail "not applied: $(phase scale-$T) $(st scale-$T '{.status.message}')"
[ "$(replicas)" = 2 ] && pass "target scaled to 2" || fail "replicas $(replicas)"
check "appliedAt recorded" '^20[0-9]{2}-' "$(st scale-$T '{.status.appliedAt}')"

propose rej-$T ScaleDeployment workloads workloads 5
wait_phase rej-$T Pending >/dev/null; decide rej-$T Rejected
wait_phase rej-$T Rejected && [ "$(replicas)" = 2 ] && pass "rejected: nothing applied" || fail "reject: $(phase rej-$T), replicas $(replicas)"

propose rst-$T RestartDeployment workloads workloads
wait_phase rst-$T Pending >/dev/null; decide rst-$T Approved
wait_phase rst-$T Applied >/dev/null || true
planned=$(st rst-$T '{.status.plan}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["spec"]["template"]["metadata"]["annotations"]["kubectl.kubernetes.io/restartedAt"])' 2>/dev/null || true)
live=$(kubectl get deploy -n workloads web -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')
[ "$(phase rst-$T)" = Applied ] && [ -n "$planned" ] && [ "$planned" = "$live" ] \
  && pass "restart applied with the exact recorded timestamp ($live)" || fail "restart: $(phase rst-$T), planned '$planned', live '$live'"

echo "--- out of declared scope: rejected even if approved (P2-07)"
propose scope-$T ScaleDeployment workloads some-other-ns 4
wait_phase scope-$T Rejected && pass "out-of-scope proposal rejected by the controller" || fail "scope: $(phase scope-$T)"
decide scope-$T Approved; sleep 3
[ "$(phase scope-$T)" = Rejected ] && [ "$(replicas)" = 2 ] && pass "a later approval doesn't revive it" || fail "scope after approval: $(phase scope-$T), replicas $(replicas)"

echo "--- drift after review: re-approval required (P2-04)"
propose drift-$T ScaleDeployment workloads workloads 4
wait_phase drift-$T Pending >/dev/null
kubectl scale deploy -n workloads web --replicas=3 >/dev/null   # someone else changes the target after review
decide drift-$T Approved
wait_phase drift-$T NeedsReapproval && pass "drift detected: NeedsReapproval" || fail "drift: $(phase drift-$T)"
[ "$(replicas)" = 3 ] && pass "stale approval applied nothing" || fail "replicas $(replicas)"
[ -z "$(st drift-$T '{.status.approval}')" ] && pass "stale approval cleared" || fail "approval still set"
check "plan re-proposed from live state (rollback to 3)" '^\{"spec":\{"replicas":3\}\}$' "$(st drift-$T '{.status.rollbackPlan}')"
decide drift-$T Approved
wait_phase drift-$T Applied && [ "$(replicas)" = 4 ] && pass "fresh approval applies" || fail "re-approval: $(phase drift-$T), replicas $(replicas)"

echo "--- target missing"
cr gone-$T ScaleDeployment workloads workloads 2 | sed 's/name: web}/name: no-such-deploy}/' | kubectl create --as=$AGENT -f - >/dev/null
wait_phase gone-$T Failed && check "missing target: Failed with a reason" 'not found' "$(st gone-$T '{.status.message}')" || fail "missing target: $(phase gone-$T)"

kubectl scale deploy -n workloads web --replicas=1 >/dev/null
exit $FAILED
