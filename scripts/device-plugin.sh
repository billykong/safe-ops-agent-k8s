#!/usr/bin/env bash
# The NVIDIA device plugin (P5 M2): the chart rendered with
# projects/05-local-inference/device-plugin/values.yaml, then patched for
# WSL2 (kustomize-patch.yaml), applied to namespace gpu-system. Needs
# scripts/node-gpu.sh first.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
D=projects/05-local-inference/device-plugin
CHART_VERSION=0.20.1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
helm repo update nvdp >/dev/null
helm template nvdp nvdp/nvidia-device-plugin --version $CHART_VERSION -n gpu-system -f $D/values.yaml > "$TMP/chart.yaml"
cp $D/kustomize-patch.yaml "$TMP/"
cat > "$TMP/kustomization.yaml" <<YAML
resources: [chart.yaml]
patches: [{path: kustomize-patch.yaml}]
YAML
kubectl create namespace gpu-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# The plugin mounts host paths and runs privileged (values.yaml says why).
kubectl label namespace gpu-system pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
kubectl apply -k "$TMP"
kubectl -n gpu-system rollout status ds/nvdp-nvidia-device-plugin --timeout=180s
