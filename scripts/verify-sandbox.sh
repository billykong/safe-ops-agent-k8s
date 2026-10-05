#!/usr/bin/env bash
# Claim a sandbox from a warm pool and confirm it runs under the expected
# runtime and the hardening holds. Each check prints PASS/FAIL; the script
# exits non-zero if any check fails.
#
# Usage: scripts/verify-sandbox.sh [gvisor|kata]   (default gvisor)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NS=sandboxes
RUNTIME=${1:-gvisor}
case $RUNTIME in
  gvisor) POOL=python-gvisor ;;
  kata)   POOL=python-kata ;;
  *) echo "unknown runtime $RUNTIME"; exit 2 ;;
esac
CLAIM="verify-$(date +%s)"

cat <<YAML | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: $CLAIM, namespace: $NS}
spec:
  warmPoolRef: {name: $POOL}
YAML
trap 'kubectl delete sandboxclaim -n $NS $CLAIM --wait=false >/dev/null' EXIT

kubectl wait -n $NS sandboxclaim/$CLAIM --for=condition=Ready --timeout=120s
SB=$(kubectl get sandboxclaim -n $NS $CLAIM -o jsonpath='{.status.sandbox.name}')
echo "sandbox: $SB"

x() { kubectl exec -n $NS "$SB" -- "$@" 2>&1; }
FAILED=0
check() { # name, expected-regex, actual
  if grep -qE "$2" <<<"$3"; then echo "PASS  $1"; else echo "FAIL  $1: got: $3"; FAILED=1; fi
}

if [ "$RUNTIME" = gvisor ]; then
  check "runs under gVisor"         'gvisor'                  "$(x cat /proc/version)"
else
  # A Kata sandbox has its own guest kernel: not gVisor's, not the node's.
  NODE_KERNEL=$(docker exec "${CLUSTER:-safe-ops}-control-plane" uname -r)
  guest=$(x uname -r)
  check "runs in a Kata VM (guest kernel $guest, node $NODE_KERNEL)" '^ok$' \
    "$([ "$guest" != "$NODE_KERNEL" ] && ! grep -q gvisor <<<"$guest" && echo ok || echo "guest kernel $guest")"
  # Kata skips the pod's seccomp profile in the guest unless
  # disable_guest_seccomp = false (cluster/kata-values.yaml).
  check "pod seccomp applied in the guest" '^Seccomp:[[:space:]]+2$' "$(x grep '^Seccomp:' /proc/1/status)"
  # Host side: every Kata VMM must run inside kubelet's pod cgroups, so the
  # pod's memory/CPU limits and the node's no-swap setting apply to the VM.
  # Without sandbox_cgroup_only, kind's systemd-style path was created
  # literally at the cgroup root, with no limits at all.
  check "Kata VMMs run inside pod cgroups (kubelet.slice)" '^ok$' "$(docker exec "${CLUSTER:-safe-ops}-control-plane" sh -c '
    n=0; for p in $(pgrep -f "^/opt/kata/bin/cloud-hypervisor"); do n=$((n+1))
      cg=$(cut -d: -f3- /proc/$p/cgroup); case $cg in /kubelet.slice/*) ;; *) echo "vmm $p in $cg"; exit;; esac; done
    [ $n -gt 0 ] && echo ok || echo "no VMM found"')"
fi
check "non-root (uid 65534)"        '^65534$'                 "$(x id -u)"
check "no service-account token"    'No such file'            "$(x ls /var/run/secrets/kubernetes.io || true)"
check "read-only root filesystem"   '^[^ ]+ / [^ ]+ ro[, ]'   "$(x grep ' / ' /proc/mounts)"

# Each target must be unreachable: the internet, the API server, cluster DNS.
API_IP=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
DNS_IP=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
for target in "1.1.1.1:443" "$API_IP:443" "$DNS_IP:53"; do
  out=$(x python -c "
import socket
h, p = '${target%:*}', ${target#*:}
try:
    socket.create_connection((h, p), timeout=3); print('CONNECTED')
except Exception as e:
    print('blocked', type(e).__name__)
" || true)
  check "egress blocked to $target" '^blocked' "$out"
done

exit $FAILED
