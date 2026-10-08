#!/usr/bin/env bash
# P2: ChangeRequest CRD, approval controller, approval identity, hash
# binding and expiry. The agent proposes (as system:serviceaccount:agent:agent);
# a human approves with approvalctl, authenticated by a client certificate
# issued for this run (group safe-ops:approvers); the controller applies.
# Each closure is checked with a negative control. Exits non-zero on any
# failure.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
AGENT=system:serviceaccount:agent:proposer
CTRL=system:serviceaccount:approval-system:approval-controller
CLI=projects/02-approval-gate/bin/approvalctl
NS=approvals
T=$(date +%s)
APPROVER=approver-test-$T
TMP=$(mktemp -d)
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:250}"; fi; }
[ -x $CLI ] || { echo "build the CLI first: make p2"; exit 1; }

replicas() { kubectl get deploy -n workloads web -o jsonpath='{.spec.replicas}'; }
phase() { kubectl get changerequest -n $NS "$1" -o jsonpath='{.status.phase}'; }
st() { kubectl get changerequest -n $NS "$1" -o jsonpath="$2"; }
wait_phase() { # name phase-regex
  for _ in $(seq 1 30); do grep -qE "^($2)$" <<<"$(phase "$1")" && return 0; sleep 1; done; return 1
}
# cr NAME TYPE TARGET-NS SCOPE-NS [REPLICAS] [WINDOW-SECONDS] -> manifest on stdout
cr() {
  local rep="" win=""
  [ -n "${5:-}" ] && rep=", replicas: $5"
  [ -n "${6:-}" ] && win="  approvalWindowSeconds: $6"
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
$win
YAML
}
propose() { cr "$@" | kubectl create --as=$AGENT -f - >/dev/null; }
# The human approver: certificate-authenticated, via approvalctl.
actl() { KUBECONFIG=$TMP/approver.kubeconfig $CLI "$@"; }
decide() { actl "$( [ "$2" = Approved ] && echo approve || echo reject )" "$1" --yes --wait 0s >/dev/null; }
# raw_decide NAME DECISION HASH APPROVER-FIELD [kubectl identity args...]: a
# hand-made status write, to probe the admission policies.
raw_decide() {
  local name=$1 d=$2 h=$3 who=$4; shift 4
  local body="{\"status\":{\"approval\":{\"decision\":\"$d\",\"approver\":\"$who\",\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"reviewHash\":\"$h\"}}}"
  if [ "${1:-}" = approver ]; then
    KUBECONFIG=$TMP/approver.kubeconfig command kubectl patch changerequest -n $NS "$name" --subresource=status --type=merge -p "$body" 2>&1
  else
    kubectl patch changerequest -n $NS "$name" "$@" --subresource=status --type=merge -p "$body" 2>&1
  fi
}
ZERO=sha256:$(printf '0%.0s' $(seq 1 64))
cleanup() {
  for n in $(kubectl get changerequest -n $NS -o name 2>/dev/null | grep -- "-$T\$"); do kubectl delete -n $NS "$n" --wait=false >/dev/null 2>&1; done
  rm -rf "$TMP"
}
trap cleanup EXIT
kubectl scale deploy -n workloads web --replicas=1 >/dev/null
./scripts/new-approver.sh $APPROVER $TMP/approver.kubeconfig 1 >/dev/null

echo "--- CRD: proposals are well-formed and immutable (P2-01, P2-02)"
out=$(cr bad-$T ScaleDeployment workloads workloads | kubectl create --dry-run=server -f - 2>&1 || true)
check "ScaleDeployment without replicas rejected" 'ScaleDeployment needs replicas' "$out"
out=$(cr bad-$T ScaleDeployment workloads workloads 2 | sed 's/type: ScaleDeployment/type: DeleteNamespace/' | kubectl create --dry-run=server -f - 2>&1 || true)
check "unknown action type rejected" 'Unsupported value: "DeleteNamespace"' "$out"
out=$(cr bad-$T ScaleDeployment workloads workloads 2 999999 | kubectl create --dry-run=server -f - 2>&1 || true)
check "approval window over a day rejected" 'approvalWindowSeconds' "$out"
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
expect no  "agent may not edit admission policies"      update validatingadmissionpolicies.admissionregistration.k8s.io
expect no  "agent may not create CSRs (mint an approver)" create certificatesigningrequests.certificates.k8s.io
wait_phase imm-$T Pending >/dev/null
out=$(raw_decide imm-$T Approved "$(st imm-$T '{.status.reviewHash}')" agent --as=$AGENT || true)
check "agent's self-approval attempt is forbidden" 'forbidden' "$out"

echo "--- controller's own reach (P2-03: never cluster-admin)"
cc() { kubectl auth can-i "$@" --as=$CTRL 2>/dev/null || true; }
[ "$(cc patch deployments.apps -n workloads)" = yes ] && pass "controller may patch deployments in workloads" || fail "controller can't patch workloads"
[ "$(cc patch deployments.apps -n kube-system)" = no ] && pass "controller may not patch deployments elsewhere" || fail "controller can patch kube-system"
[ "$(cc delete deployments.apps -n workloads)" = no ] && pass "controller may not delete deployments" || fail "controller can delete"
[ "$(cc create pods -n workloads)" = no ] && pass "controller may not create pods" || fail "controller can create pods"
[ "$(cc update changerequests.approval.safe-ops.io -n $NS)" = no ] && pass "controller may not edit proposals" || fail "controller can edit proposals"

echo "--- propose, review, approve with approvalctl, apply (P2-41)"
propose scale-$T ScaleDeployment workloads workloads 2
wait_phase scale-$T Pending && pass "proposal recorded: Pending" || fail "proposal not Pending: $(phase scale-$T)"
check "pre-state recorded" '"replicas":1' "$(st scale-$T '{.status.preState}')"
check "exact plan recorded" '^\{"spec":\{"replicas":2\}\}$' "$(st scale-$T '{.status.plan}')"
check "exact rollback recorded" '^\{"spec":\{"replicas":1\}\}$' "$(st scale-$T '{.status.rollbackPlan}')"
check "review hash and expiry recorded" '^sha256:[0-9a-f]{64} 20' "$(st scale-$T '{.status.reviewHash} {.status.expiresAt}')"
out=$(actl show scale-$T)
check "approvalctl show: the exact plan and hash" "plan +\{\"spec\":\{\"replicas\":2\}\}.*" "$(tr '\n' ' ' <<<"$out")"
sleep 2
[ "$(replicas)" = 1 ] && pass "nothing applied before approval" || fail "target changed before approval: $(replicas)"
decide scale-$T Approved
wait_phase scale-$T Applied && pass "approved with approvalctl: Applied" || fail "not applied: $(phase scale-$T) $(st scale-$T '{.status.message}')"
[ "$(replicas)" = 2 ] && pass "target scaled to 2" || fail "replicas $(replicas)"
[ "$(st scale-$T '{.status.approval.approver}')" = "$APPROVER" ] && pass "approver recorded from the certificate identity ($APPROVER)" \
  || fail "approver is '$(st scale-$T '{.status.approval.approver}')'"
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

echo "--- who may approve, and as whom (P2-11)"
propose who-$T ScaleDeployment workloads workloads 3
wait_phase who-$T Pending >/dev/null
H=$(st who-$T '{.status.reviewHash}')
out=$(raw_decide who-$T Approved "$H" kubernetes-admin || true)
check "cluster admin outside safe-ops:approvers can't approve" 'needs an authenticated human in group safe-ops:approvers' "$out"
# Not the agent's SA: agent-write-guard would refuse that first, and this
# checks the approval policy itself.
out=$(raw_decide who-$T Approved "$H" robot --as=system:serviceaccount:approvals:default --as-group=safe-ops:approvers --as-group=system:authenticated || true)
check "a service account in the approvers group still can't approve" 'not a service account' "$out"
out=$(raw_decide who-$T Approved "$H" controller --as=$CTRL || true)
check "the controller can't approve" 'needs an authenticated human' "$out"
out=$(KUBECONFIG=$TMP/approver.kubeconfig command kubectl patch changerequest -n $NS who-$T --subresource=status --type=merge -p '{"status":{"plan":"{\"spec\":{\"replicas\":40}}"}}' 2>&1 || true)
check "an approver can't rewrite the plan" 'only the approval controller may change status fields other than approval' "$out"
out=$(KUBECONFIG=$TMP/approver.kubeconfig command kubectl patch changerequest -n $NS rej-$T --subresource=status --type=merge -p '{"status":{"approval":null}}' 2>&1 || true)
check "an approver can't withdraw a decision" 'only the approval controller may withdraw' "$out"
raw_decide who-$T Approved "$H" mallory approver >/dev/null
wait_phase who-$T Applied >/dev/null || true
[ "$(st who-$T '{.status.approval.approver}')" = "$APPROVER" ] && pass "a spoofed approver name is overwritten with the authenticated user" \
  || fail "approver recorded as '$(st who-$T '{.status.approval.approver}')'"
[ "$(replicas)" = 3 ] && pass "and the genuine approval applied" || fail "replicas $(replicas)"

# Regression: an approval that doesn't round-trip through the controller's
# Go type ("comment": "" is dropped by omitempty) once made every controller
# status write look like an approval change, which the policy refuses.
propose cmt-$T ScaleDeployment workloads workloads 3
wait_phase cmt-$T Pending >/dev/null
KUBECONFIG=$TMP/approver.kubeconfig command kubectl patch changerequest -n $NS cmt-$T --subresource=status --type=merge -p \
  "{\"status\":{\"approval\":{\"decision\":\"Approved\",\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"reviewHash\":\"$(st cmt-$T '{.status.reviewHash}')\",\"comment\":\"\"}}}" >/dev/null
wait_phase cmt-$T Applied && pass "an approval with an empty comment still applies" || fail "empty-comment approval stuck: $(phase cmt-$T)"

echo "--- approval bound to the reviewed packet's hash (P2-12)"
propose hash-$T ScaleDeployment workloads workloads 6
wait_phase hash-$T Pending >/dev/null
raw_decide hash-$T Approved "$ZERO" x approver >/dev/null
sleep 3
[ "$(phase hash-$T)" = Pending ] && [ -z "$(st hash-$T '{.status.approval}')" ] && [ "$(replicas)" = 3 ] \
  && pass "approval with another hash discarded, nothing applied" || fail "hash: $(phase hash-$T), approval '$(st hash-$T '{.status.approval}')', replicas $(replicas)"
check "the discard is explained" 'discarded an approval .* review again' "$(st hash-$T '{.status.message}')"

echo "--- expiry (P2-12)"
propose exp-$T ScaleDeployment workloads workloads 7 10
wait_phase exp-$T Pending >/dev/null
sleep 12
wait_phase exp-$T Expired && pass "unanswered request expired on time" || fail "expiry: $(phase exp-$T)"
out=$(actl approve exp-$T --yes 2>&1 || true)
check "approvalctl refuses an expired request" 'is Expired' "$out"
raw_decide exp-$T Approved "$(st exp-$T '{.status.reviewHash}')" x approver >/dev/null || true
sleep 3
[ "$(phase exp-$T)" = Expired ] && [ "$(replicas)" = 3 ] && pass "a late approval applies nothing" || fail "late approval: $(phase exp-$T), replicas $(replicas)"

echo "--- out of declared scope: rejected even if approved (P2-07)"
propose scope-$T ScaleDeployment workloads some-other-ns 4
wait_phase scope-$T Rejected && pass "out-of-scope proposal rejected by the controller" || fail "scope: $(phase scope-$T)"
raw_decide scope-$T Approved "$ZERO" x approver >/dev/null || true; sleep 3
[ "$(phase scope-$T)" = Rejected ] && [ "$(replicas)" = 3 ] && pass "a later approval doesn't revive it" || fail "scope after approval: $(phase scope-$T), replicas $(replicas)"

echo "--- drift after review: re-approval required (P2-04)"
propose drift-$T ScaleDeployment workloads workloads 4
wait_phase drift-$T Pending >/dev/null
H1=$(st drift-$T '{.status.reviewHash}')
kubectl scale deploy -n workloads web --replicas=5 >/dev/null   # someone else changes the target after review
decide drift-$T Approved
wait_phase drift-$T NeedsReapproval && pass "drift detected: NeedsReapproval" || fail "drift: $(phase drift-$T)"
[ "$(replicas)" = 5 ] && pass "stale approval applied nothing" || fail "replicas $(replicas)"
[ -z "$(st drift-$T '{.status.approval}')" ] && pass "stale approval cleared" || fail "approval still set"
[ "$(st drift-$T '{.status.reviewHash}')" != "$H1" ] && pass "re-plan has a new review hash" || fail "hash unchanged after re-plan"
check "plan re-proposed from live state (rollback to 5)" '^\{"spec":\{"replicas":5\}\}$' "$(st drift-$T '{.status.rollbackPlan}')"
raw_decide drift-$T Approved "$H1" x approver >/dev/null; sleep 3
[ "$(phase drift-$T)" = NeedsReapproval ] && [ "$(replicas)" = 5 ] && pass "re-sending the old approval (old hash) doesn't apply" || fail "old hash: $(phase drift-$T), replicas $(replicas)"
decide drift-$T Approved
wait_phase drift-$T Applied && [ "$(replicas)" = 4 ] && pass "fresh approval of the new packet applies" || fail "re-approval: $(phase drift-$T), replicas $(replicas)"

echo "--- target missing"
cr gone-$T ScaleDeployment workloads workloads 2 | sed 's/name: web}/name: no-such-deploy}/' | kubectl create --as=$AGENT -f - >/dev/null
wait_phase gone-$T Failed && check "missing target: Failed with a reason" 'not found' "$(st gone-$T '{.status.message}')" || fail "missing target: $(phase gone-$T)"

kubectl scale deploy -n workloads web --replicas=1 >/dev/null
exit $FAILED
