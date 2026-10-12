#!/usr/bin/env bash
# Where the local model runs: inside the cluster on the GPU through the
# device plugin (P5 M2, the default), or outside it in Docker (P5 M1, the
# fallback). The GPU has 4 GB, so one at a time: this stops one, starts the
# other and points the LLM gateway's route at it.
#   scripts/local-model-mode.sh cluster|docker|status
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
MODEL=qwen2.5-1.5b-instruct
LOCK=projects/05-local-inference/models/qwen2.5-1.5b-instruct-awq.sha256
WEIGHTS=${MODEL_CACHE:-$HOME/.cache/safe-ops-models}/qwen2.5-1.5b-instruct-awq
NODE=${CLUSTER:-safe-ops}-control-plane
NODE_WEIGHTS=/var/lib/safe-ops-models/qwen2.5-1.5b-instruct-awq
CLUSTER_URL=http://local-model.inference.svc.cluster.local:8000
DOCKER_URL=http://172.30.99.10:8000

route() { # URL: the gateway's route for the local model (restarts it)
  [ "$(current)" = "$1" ] && return
  kubectl set env -n gateways deploy/llm-gateway "ROUTES=$MODEL=$1" >/dev/null
  kubectl rollout status -n gateways deploy/llm-gateway --timeout=120s >/dev/null
  # The old pod takes up to 30s to go; until then a port-forward to the
  # Service may still pick it.
  for _ in $(seq 1 60); do [ "$(kubectl get pods -n gateways -l app=llm-gateway --no-headers | wc -l)" = 1 ] && break; sleep 1; done
}
current() {
  kubectl get deploy -n gateways llm-gateway -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROUTES")].value}' | sed "s|^$MODEL=||"
}

# The verified weights into the node, for the in-cluster server's volume.
# The pod verifies them again at every start.
node_weights() {
  scripts/model-server.sh fetch >/dev/null
  local want; want=$(sha256sum "$LOCK" | cut -c1-16)
  [ "$(docker exec "$NODE" cat "$NODE_WEIGHTS.lock" 2>/dev/null)" = "$want" ] && return
  echo "copying the verified weights into $NODE"
  docker exec "$NODE" sh -c "rm -rf '$NODE_WEIGHTS' && mkdir -p '$(dirname "$NODE_WEIGHTS")'"
  docker cp "$WEIGHTS" "$NODE:$NODE_WEIGHTS"
  docker exec "$NODE" sh -c "chown -R root:root '$NODE_WEIGHTS' && chmod 755 '$NODE_WEIGHTS' && chmod 444 '$NODE_WEIGHTS'/* && echo $want > '$NODE_WEIGHTS.lock'"
}

case "${1:-status}" in
  cluster)
    scripts/model-server.sh down >/dev/null
    node_weights
    kubectl create configmap -n inference local-model-lock --from-file=lock.sha256="$LOCK" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    scripts/model-server.sh key
    kubectl scale deploy -n inference local-model --replicas=1 >/dev/null
    echo "waiting for the in-cluster server (a few minutes on a cold start)"
    kubectl rollout status -n inference deploy/local-model --timeout=600s >/dev/null
    route "$CLUSTER_URL"
    echo "local model: in the cluster ($CLUSTER_URL)" ;;
  docker)
    kubectl scale deploy -n inference local-model --replicas=0 >/dev/null 2>&1 || true
    kubectl wait -n inference --for=delete pod -l app=local-model --timeout=120s >/dev/null 2>&1 || true
    scripts/model-server.sh up
    route "$DOCKER_URL"
    echo "local model: outside the cluster, in Docker ($DOCKER_URL)" ;;
  status)
    case "$(current)" in
      "$CLUSTER_URL") echo "cluster: $(kubectl get deploy -n inference local-model -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0) ready" ;;
      "$DOCKER_URL") echo "docker: $(scripts/model-server.sh status | head -1)" ;;
      *) echo "unknown route: $(current)" ;;
    esac ;;
  *) echo "usage: $0 cluster|docker|status" >&2; exit 2 ;;
esac
