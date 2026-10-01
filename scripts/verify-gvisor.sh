#!/usr/bin/env bash
# Claim a sandbox from the warm pool and confirm it runs under gVisor and the
# hardening holds. gVisor reports a fixed fake kernel in /proc/version.
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

x() { kubectl exec -n $NS "$SB" -- "$@"; }
echo "--- kernel (expect gVisor's fake 4.4.0):";      x cat /proc/version
echo "--- uid (expect 65534):";                         x id -u
echo "--- SA token (expect absent):";                   x ls /var/run/secrets/kubernetes.io 2>&1 || true
echo "--- write to rootfs (expect read-only error):";  x touch /should-fail 2>&1 || true
echo "--- egress (expect timeout):"
x python -c "import socket; socket.create_connection(('1.1.1.1', 443), timeout=3)" 2>&1 | tail -1 || true
