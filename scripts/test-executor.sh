#!/usr/bin/env bash
# End-to-end test of the sandbox executor: claim a sandbox, call it from an
# agent-identity client pod (must work), and from two non-agent pods (must be
# blocked by NetworkPolicy). Exits non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")"
NS=sandboxes
CLAIM="exec-test-$(date +%s)"
FAILED=0

kubectl create namespace agent --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace agent pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
for ns in agent default; do
  kubectl create configmap executor-client -n $ns --from-file=executor_client.py \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: $CLAIM, namespace: $NS}
spec:
  warmPoolRef: {name: python-gvisor}
YAML
cleanup() {
  kubectl delete sandboxclaim -n $NS $CLAIM --wait=false >/dev/null 2>&1 || true
  kubectl delete pod -n agent -l exec-test=1 --wait=false >/dev/null 2>&1 || true
  kubectl delete pod -n default -l exec-test=1 --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl wait -n $NS sandboxclaim/$CLAIM --for=condition=Ready --timeout=120s >/dev/null
SB=$(kubectl get sandboxclaim -n $NS $CLAIM -o jsonpath='{.status.sandbox.name}')
IP=$(kubectl get pod -n $NS "$SB" -o jsonpath='{.status.podIP}')
URL="http://$IP:8888"
echo "sandbox: $SB ($URL)"

# client NAME NAMESPACE LABELS MODE -> prints the pod's log
client() {
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $2
  labels: {exec-test: "1", $3}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
  - name: client
    image: python:3.13-slim
    command: ["python", "/client/executor_client.py", "$URL", "$4"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: {drop: ["ALL"]}
    volumeMounts: [{name: client, mountPath: /client}]
  volumes: [{name: client, configMap: {name: executor-client}}]
YAML
  kubectl wait -n "$2" pod/"$1" --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null || true
  kubectl logs -n "$2" "$1"
}

echo "--- as the agent (agent/app=agent): full API"
out=$(client agent-client agent "app: agent" full)
echo "$out"
grep -q FAIL <<<"$out" && FAILED=1
grep -q PASS <<<"$out" || FAILED=1

expect_blocked() { # name, output
  if grep -q '^UNREACHABLE' <<<"$2"; then echo "PASS  blocked: $1"; else echo "FAIL  not blocked: $1: $2"; FAILED=1; fi
}
expect_blocked "agent namespace without app=agent label" "$(client unlabelled agent "role: other" reach)"
expect_blocked "app=agent label in another namespace"    "$(client wrong-ns default "app: agent" reach)"

exit $FAILED
