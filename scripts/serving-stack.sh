#!/usr/bin/env bash
# The serving stack (P5 M3, P5-05): vLLM behind the Gateway API Inference
# Extension, scaled on queue depth.
#   - Gateway API (standard) and InferencePool CRDs;
#   - agentgateway, the Gateway implementation (namespace
#     agentgateway-system; writes only in namespace inference);
#   - KEDA (namespace keda; watches namespace inference only);
#   - projects/05-local-inference/serving/manifests/: the endpoint picker
#     and the InferencePool, the Gateway and its route, network policies,
#     the ScaledObject, and who may join the pool.
# Each download is pinned: a version and, for the CRDs, a SHA-256.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
D=projects/05-local-inference/serving
GATEWAY_API=v1.6.3
GATEWAY_API_SHA=356c2b8e286a964dc20995435659ad1095386329974793af10bbfe3eff977fe5
GIE=v1.6.2
GIE_SHA=38bfba9c452ab54b1afd1f4df15e75b3238c788d8ab007d2f469e6f7ae16fc9f
AGENTGATEWAY=v1.6.0
KEDA=2.21.0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

fetch() { # URL SHA256 FILE
  curl -sSfL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum --check --quiet --strict || { echo "$1: SHA-256 mismatch" >&2; exit 1; }
}

echo "--- CRDs: Gateway API $GATEWAY_API, InferencePool (GIE $GIE)"
fetch https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API/standard-install.yaml $GATEWAY_API_SHA "$TMP/gateway-api.yaml"
fetch https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$GIE/manifests.yaml $GIE_SHA "$TMP/gie.yaml"
kubectl apply --server-side -f "$TMP/gateway-api.yaml" -f "$TMP/gie.yaml" >/dev/null

echo "--- agentgateway $AGENTGATEWAY"
helm pull oci://cr.agentgateway.dev/charts/agentgateway-crds --version $AGENTGATEWAY -d "$TMP" >/dev/null 2>&1
helm pull oci://cr.agentgateway.dev/charts/agentgateway --version $AGENTGATEWAY -d "$TMP" >/dev/null 2>&1
helm template agentgateway-crds "$TMP/agentgateway-crds-$AGENTGATEWAY.tgz" | kubectl apply --server-side -f - >/dev/null
kubectl wait --for=condition=Established crd --all --timeout=60s >/dev/null
for ns in agentgateway-system keda; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace $ns pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
done
# The controller's write access is scoped to namespace inference, which
# must exist first (manifests/30-inference.yaml).
kubectl get namespace inference >/dev/null
helm template agentgateway "$TMP/agentgateway-$AGENTGATEWAY.tgz" -n agentgateway-system -f $D/agentgateway-values.yaml \
  --set controller.image.tag="$AGENTGATEWAY@sha256:d84259a7e2d87f8f39bae385d4b032d823c0a4450aecb32e0e31e2258449645b" \
  | kubectl apply -f - >/dev/null

echo "--- KEDA $KEDA"
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update kedacore >/dev/null
helm template keda kedacore/keda --version $KEDA -n keda -f $D/keda-values.yaml | kubectl apply --server-side -f - >/dev/null

echo "--- the stack (serving/manifests)"
kubectl apply -f $D/manifests/ > "$TMP/applied"
# The picker reads its plugins config at start only.
if grep -q '^configmap/local-model-epp configured' "$TMP/applied"; then
  kubectl -n inference rollout restart deploy/local-model-epp >/dev/null
fi
kubectl -n agentgateway-system rollout status deploy/agentgateway --timeout=180s
kubectl -n keda rollout status deploy/keda-operator --timeout=180s
kubectl -n keda rollout status deploy/keda-operator-metrics-apiserver --timeout=180s
kubectl -n inference rollout status deploy/local-model-epp --timeout=180s
for _ in $(seq 1 60); do kubectl -n inference get deploy inference-gateway >/dev/null 2>&1 && break; sleep 2; done
kubectl -n inference rollout status deploy/inference-gateway --timeout=180s
