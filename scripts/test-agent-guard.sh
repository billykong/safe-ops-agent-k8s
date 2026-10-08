#!/usr/bin/env bash
# P2 milestone 3: the agent-write-guard admission policy (P2-13). RBAC
# already keeps the agent from writing, so to test the backstop this
# temporarily widens the agent's RBAC to write almost anything (not
# impersonate/escalate/bind), checks the policy still refuses, and removes
# the widening. Also checks the agent's real work still passes, that other
# identities aren't affected, and that the permissions the guard can't see
# are absent. Prints GAP for the documented limit (docs/known-gaps.md
# GAP-02). Exits non-zero on any FAIL.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# Two agent identities, each allowed only its own job's writes.
AGENT=system:serviceaccount:agent:proposer
AS=--as=$AGENT
RUNNER=system:serviceaccount:agent:runner
RAS=--as=$RUNNER
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
gap() { echo "GAP $1  $2"; }
# kubectl 1.37 prints a dry-run patch as plain "patched" (nothing persists).
admitted() { grep -q -E 'created \(server dry run\)|deleted \(server dry run\)|patched( \(server dry run\))?$' <<<"$1"; }
guarded() { grep -q "agent-write-guard" <<<"$1"; }
# allowed DESC CMD...: must be admitted. denied DESC CMD...: must be refused
# by the guard. With IN=<function>, the function's output is the command's
# stdin. (Not `sh -c`: a child shell doesn't get lib.sh's context pinning,
# and silently talks to whatever cluster is current.)
run() { if [ -n "${IN:-}" ]; then "$IN" | "$@" 2>&1 || true; else "$@" 2>&1 || true; fi; }
allowed() { local d=$1; shift; out=$(run "$@"); admitted "$out" && pass "allowed: $d" || fail "allowed: $d: ${out:0:200}"; }
denied()  { local d=$1; shift; out=$(run "$@"); guarded "$out" && pass "refused by the guard: $d" || fail "not refused by the guard: $d: ${out:0:200}"; }

claim() { cat <<YAML
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: guard-probe, namespace: sandboxes}
spec: {warmPoolRef: {name: python-gvisor}}
YAML
}
proposal() { cat <<YAML
apiVersion: approval.safe-ops.io/v1alpha1
kind: ChangeRequest
metadata: {name: guard-probe, namespace: approvals}
spec:
  intent: x
  action: {type: ScaleDeployment, replicas: 2, target: {kind: Deployment, namespace: workloads, name: web}}
  blastRadius: x
  scope: {namespaces: [workloads], kinds: [Deployment]}
  rollback: x
YAML
}
pod() { cat <<YAML
apiVersion: v1
kind: Pod
metadata: {name: guard-probe, namespace: agent}
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
  - {name: c, image: python:3.13-slim, securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}}
YAML
}
allowed_work() { # $1: label suffix
  IN=claim allowed "runner: create a SandboxClaim in sandboxes$1" kubectl create $RAS --dry-run=server -f -
  IN=proposal allowed "proposer: create a ChangeRequest in approvals$1" kubectl create $AS --dry-run=server -f -
  for id in $AGENT $RUNNER; do
    out=$(kubectl auth whoami --as=$id 2>&1 || true)
    grep -q "$id" <<<"$out" && pass "allowed: ${id##*:} asks who it is (SelfSubjectReview)$1" || fail "whoami$1: ${out:0:200}"
  done
}

echo "--- the agent's own work still passes"
kubectl get validatingadmissionpolicybinding agent-write-guard >/dev/null && pass "guard is installed" || fail "guard not installed"
allowed_work ""

echo "--- what an admission guard can't see: these must never be granted"
can() { kubectl auth can-i "$@" $AS 2>/dev/null || true; }
never() { # for every agent identity
  local d=$1; shift
  for id in $AGENT $RUNNER; do
    [ "$(kubectl auth can-i "$@" --as=$id 2>/dev/null || true)" = no ] && pass "${id##*:} may not $d" || fail "${id##*:} MAY $d"
  done
}
never "impersonate users"                  impersonate users
never "impersonate groups"                 impersonate groups
never "impersonate service accounts"       impersonate serviceaccounts
never "escalate roles"                     escalate clusterroles.rbac.authorization.k8s.io
never "bind roles"                         bind clusterroles.rbac.authorization.k8s.io
never "write admission policies"           create validatingadmissionpolicies.admissionregistration.k8s.io
never "delete admission policies"          delete validatingadmissionpolicies.admissionregistration.k8s.io
never "delete policy bindings"             delete validatingadmissionpolicybindings.admissionregistration.k8s.io
never "write mutating policies"            create mutatingadmissionpolicies.admissionregistration.k8s.io
never "write webhook configurations"       create validatingwebhookconfigurations.admissionregistration.k8s.io
never "mint tokens for service accounts"   create serviceaccounts/token -n agent

echo "--- backstop: RBAC widened to write almost anything, the guard still refuses"
cleanup() { kubectl delete clusterrolebinding test-agent-widened --ignore-not-found >/dev/null 2>&1 || true
            kubectl delete clusterrole test-agent-widened --ignore-not-found >/dev/null 2>&1 || true
            kubectl delete changerequest -n approvals guard-probe-real --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
# A real ChangeRequest for the status/delete probes (as the agent: allowed).
proposal | sed 's/name: guard-probe,/name: guard-probe-real,/' | kubectl create $AS -f - >/dev/null
trap cleanup EXIT
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: test-agent-widened}
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["get", "list", "create", "update", "patch", "delete", "deletecollection"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["get", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: test-agent-widened}
subjects:
- {kind: ServiceAccount, name: proposer, namespace: agent}
- {kind: ServiceAccount, name: runner, namespace: agent}
- {kind: ServiceAccount, name: default, namespace: agent}   # an identity with no job at all
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: test-agent-widened}
YAML
for _ in $(seq 1 20); do [ "$(can patch deployments.apps -n workloads)" = yes ] && break; sleep 1; done
[ "$(can patch deployments.apps -n workloads)" = yes ] && pass "widening in effect: RBAC now lets the agent patch workloads" || fail "widening not in effect"
denied "patch workloads/web"                 kubectl patch deploy -n workloads web $AS --dry-run=server --type=merge -p '{"spec":{"replicas":9}}'
denied "scale workloads/web (scale subresource)" kubectl scale deploy -n workloads web --replicas=9 $AS --dry-run=server
denied "delete the workloads namespace"      kubectl delete namespace workloads $AS --dry-run=server
IN=pod denied "create a pod"                 kubectl create $AS --dry-run=server -f -
denied "create a secret"                     kubectl create secret generic guard-probe -n agent --from-literal=k=v $AS --dry-run=server
# Two policies refuse this (the guard and changerequest-approval-authority);
# the API server reports whichever denies first.
out=$(kubectl patch changerequest -n approvals guard-probe-real $AS --subresource=status --type=merge -p '{"status":{"message":"x"}}' --dry-run=server 2>&1 || true)
grep -qE "agent-write-guard|changerequest-approval-authority" <<<"$out" && pass "refused at admission: write its ChangeRequest's status" || fail "status write not refused: ${out:0:200}"
denied "delete a ChangeRequest"              kubectl delete changerequest -n approvals guard-probe-real $AS --dry-run=server
denied "edit the approval controller"        kubectl patch deploy -n approval-system approval-controller $AS --dry-run=server --type=merge -p '{"spec":{"replicas":0}}'
denied "cordon the node"                     kubectl patch node "$(kubectl get node -o name | head -1 | cut -d/ -f2)" $AS --dry-run=server --type=merge -p '{"spec":{"unschedulable":true}}'
denied "remove its own RBAC widening"        kubectl delete clusterrolebinding test-agent-widened $AS --dry-run=server
SBX=$(kubectl get pod -n sandboxes -o jsonpath='{.items[0].metadata.name}')
denied "exec into a sandbox (CONNECT pods/exec)" kubectl exec -n sandboxes "$SBX" $AS -- true
allowed_work " (still, while widened)"
echo "--- each identity only its own job, even widened"
IN=proposal denied "runner proposing a ChangeRequest"   kubectl create $RAS --dry-run=server -f -
IN=claim denied "proposer claiming a sandbox"            kubectl create $AS --dry-run=server -f -
denied "an identity added later (agent/default) writing anything" \
  kubectl create configmap guard-probe -n agent --from-literal=k=v --as=system:serviceaccount:agent:default --dry-run=server
IN=claim denied "an identity added later claiming a sandbox" kubectl create --as=system:serviceaccount:agent:default --dry-run=server -f -
out=$(kubectl delete validatingadmissionpolicy agent-write-guard $AS --dry-run=server 2>&1 || true)
if admitted "$out"; then gap GAP-02 "with RBAC on admission policies the agent could delete the guard itself (not applied to admission configuration)"
else pass "guard refused deleting itself (if this ever passes, update GAP-02)"; fi
cleanup
[ "$(can patch deployments.apps -n workloads)" = no ] && pass "widening removed" || fail "widening still in effect"

echo "--- scoped to the agent's identity"
# Patches that change something, so the server really runs admission.
allowed "a cluster admin may patch workloads/web" kubectl patch deploy -n workloads web --dry-run=server --type=merge -p '{"spec":{"replicas":2}}'
allowed "the approval controller may patch workloads/web" \
  kubectl patch deploy -n workloads web --as=system:serviceaccount:approval-system:approval-controller --dry-run=server --type=merge -p '{"spec":{"replicas":2}}'

exit $FAILED
