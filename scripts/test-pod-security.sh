#!/usr/bin/env bash
# Pod Security "restricted" must be enforced, not just labelled, in the
# sandboxes and agent namespaces. Server-side dry runs of pods that break one
# rule each must be denied by PodSecurity; a compliant pod must be admitted
# (positive control). Then the path that matters for sandboxes: a Sandbox
# whose template breaks the policy must not get a pod, even though the
# controller, not a user, creates it. Exits non-zero on any failure.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

# pod NS NAME POD-SPEC-PATCH(json): a restricted-compliant pod, patched.
pod() {
  python3 - "$1" "$2" "$3" <<'EOF'
import json, sys
ns, name, patch = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
pod = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": ns},
       "spec": {"securityContext": {"runAsNonRoot": True, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
                "containers": [{"name": "c", "image": "python:3.13-slim", "command": ["sleep", "1"],
                                "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}}}]}}
def merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict): merge(a[k], v)
        elif v is None: a.pop(k, None)
        else: a[k] = v
merge(pod["spec"], patch.get("spec", {}))
merge(pod["spec"]["containers"][0], patch.get("container", {}))
print(json.dumps(pod))
EOF
}
try() { # ns name patch -> server's answer
  pod "$1" "$2" "$3" | kubectl create --dry-run=server -f - 2>&1 || true
}

CASES=(
  # privileged needs allowPrivilegeEscalation unset: with it false, plain
  # validation rejects the pod before PodSecurity ever sees it.
  'privileged container|{"container": {"securityContext": {"privileged": true, "allowPrivilegeEscalation": null}}}'
  'host network|{"spec": {"hostNetwork": true}}'
  'host PID|{"spec": {"hostPID": true}}'
  'hostPath volume|{"spec": {"volumes": [{"name": "h", "hostPath": {"path": "/"}}]}}'
  'runs as root|{"spec": {"securityContext": {"runAsNonRoot": null, "runAsUser": 0}}}'
  'privilege escalation allowed|{"container": {"securityContext": {"allowPrivilegeEscalation": true}}}'
  'adds NET_RAW|{"container": {"securityContext": {"capabilities": {"drop": ["ALL"], "add": ["NET_RAW"]}}}}'
  'no seccomp profile|{"spec": {"securityContext": {"seccompProfile": null}}}'
  'unconfined seccomp|{"spec": {"securityContext": {"seccompProfile": {"type": "Unconfined"}}}}'
)

for ns in sandboxes agent; do
  echo "--- namespace $ns"
  label=$(kubectl get ns $ns -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
  [ "$label" = restricted ] && pass "labelled enforce=restricted" || fail "enforce label is '$label'"
  out=$(try $ns pss-ok '{}')
  grep -q 'created (server dry run)' <<<"$out" && pass "compliant pod admitted (positive control)" || fail "compliant pod rejected: $out"
  for c in "${CASES[@]}"; do
    desc=${c%%|*}; patch=${c#*|}
    out=$(try $ns pss-bad "$patch")
    grep -q 'violates PodSecurity "restricted' <<<"$out" && pass "denied: $desc" || fail "not denied by PodSecurity: $desc: ${out:0:200}"
  done
done

echo "--- through the controller: a Sandbox with a privileged template"
SB=pss-test-$(date +%s)
trap 'kubectl delete sandbox -n sandboxes $SB --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
pod sandboxes x '{"container": {"securityContext": {"privileged": true, "allowPrivilegeEscalation": null}}}' | python3 -c '
import json, sys
p = json.load(sys.stdin)
print(json.dumps({"apiVersion": "agents.x-k8s.io/v1beta1", "kind": "Sandbox",
                  "metadata": {"name": sys.argv[1], "namespace": "sandboxes"},
                  "spec": {"podTemplate": {"spec": p["spec"]}}}))' "$SB" | kubectl apply -f - >/dev/null
sleep 10
pods=$(kubectl get pod -n sandboxes "$SB" --ignore-not-found -o name)
[ -z "$pods" ] && pass "controller could not create the pod" || fail "pod $pods exists"
ev=$(kubectl get events -n sandboxes --field-selector involvedObject.name=$SB -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null)
st=$(kubectl get sandbox -n sandboxes $SB -o jsonpath='{range .status.conditions[*]}{.message}{"\n"}{end}' 2>/dev/null)
grep -q 'violates PodSecurity' <<<"$ev$st" && pass "denial reported by PodSecurity" \
  || fail "no PodSecurity denial in events or status: ${ev:0:200} ${st:0:200}"

exit $FAILED
