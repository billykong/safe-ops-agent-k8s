#!/usr/bin/env bash
# Milestone 6: DNS-scoped egress. Claims one sandbox from the pypi egress
# pool and one from the default pool (negative control), then probes both
# through their executors from an agent-identity pod. Host-side evidence: the
# DNS proxy's refusals in Hubble. Exits non-zero on any FAIL; a GAP is a
# known weakness that is reported, not failed (docs/known-gaps.md).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
NS=sandboxes
STAMP=$(date +%s)
CLAIMS="egress-pypi-$STAMP egress-default-$STAMP"
trap 'for c in $CLAIMS; do kubectl delete sandboxclaim -n $NS $c --wait=false >/dev/null 2>&1 || true; done
      kubectl delete pod -n agent egress-client --wait=false >/dev/null 2>&1 || true' EXIT

for pool in pypi default; do
  ref=python-gvisor; [ $pool = pypi ] && ref=python-gvisor-pypi
  kubectl apply -f - >/dev/null <<YAML
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: egress-$pool-$STAMP, namespace: $NS}
spec:
  warmPoolRef: {name: $ref}
YAML
done
ip_of() {
  kubectl wait -n $NS sandboxclaim/$1 --for=condition=Ready --timeout=120s >/dev/null
  kubectl get pod -n $NS "$(kubectl get sandboxclaim -n $NS $1 -o jsonpath='{.status.sandbox.name}')" -o jsonpath='{.status.podIP}'
}
PYPI_IP=$(ip_of egress-pypi-$STAMP)
DEFAULT_IP=$(ip_of egress-default-$STAMP)
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "pypi sandbox $PYPI_IP, default sandbox $DEFAULT_IP"

kubectl create configmap egress-client -n agent --from-file=scripts/egress_client.py \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl delete pod -n agent egress-client --ignore-not-found --wait=true >/dev/null
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: egress-client, namespace: agent, labels: {app: agent}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: client
    image: python:3.13-slim
    command: ["python", "/client/egress_client.py", "$PYPI_IP", "$DEFAULT_IP"]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
    volumeMounts: [{name: client, mountPath: /client}]
  volumes: [{name: client, configMap: {name: egress-client}}]
YAML
kubectl wait -n agent pod/egress-client --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s >/dev/null || true
out=$(kubectl logs -n agent egress-client)
echo "$out"

# Independent evidence: the DNS proxy itself refused the names off the list.
refused=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --ip "$PYPI_IP" --protocol dns --verdict DROPPED --since "$START" -o compact 2>/dev/null \
  | grep -c -E 'example\.com|secret-hunter2\.pypi\.org|github\.com' || true)
FAILED=0
if [ "$refused" -gt 0 ]; then echo "PASS  Hubble: DNS proxy refused $refused queries for names off the allowlist"
else echo "FAIL  Hubble: no DNS proxy refusals seen"; FAILED=1; fi
grep -q '^PASS' <<<"$out" || { echo "FAIL  client produced no results"; FAILED=1; }
grep -q '^FAIL' <<<"$out" && FAILED=1
exit $FAILED
