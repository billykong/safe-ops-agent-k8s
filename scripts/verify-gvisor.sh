#!/usr/bin/env bash
# Claim a sandbox from the warm pool and confirm it runs under gVisor and the
# hardening holds. Each check prints PASS/FAIL; the script exits non-zero if
# any check fails.
set -euo pipefail
NS=sandboxes
CLAIM="verify-$(date +%s)"

cat <<YAML | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: $CLAIM, namespace: $NS}
spec:
  warmPoolRef: {name: python-gvisor}
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

check "runs under gVisor"           'gvisor'                  "$(x cat /proc/version)"
check "non-root (uid 65534)"        '^65534$'                 "$(x id -u)"
check "no service-account token"    'No such file'            "$(x ls /var/run/secrets/kubernetes.io || true)"
check "read-only root filesystem"   '^none / [^ ]+ ro[, ]'    "$(x grep ' / ' /proc/mounts)"

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
