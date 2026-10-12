#!/usr/bin/env bash
# The local model server (P5 M1, P5-02): vLLM in Docker on the host,
# outside the cluster, on the host's GPU. The cluster reaches it through
# the LLM gateway only.
#
#   fetch    download the pinned weights and verify every file's SHA-256
#   verify [DIR]  re-check a copy of the weights (default: the served one)
#   up       verify the weights, then start the server
#   down     stop it (frees the GPU)
#   key      create the key and its Secrets, if missing
#   status
#
# The server:
# - runs on its own internal Docker network (safe-ops-models), which only
#   this cluster's node joins: no route to the internet, to the `ml`
#   cluster or to anything else on `kind`, and no published port (the
#   host itself still reaches it, at the bridge's address);
# - loads only the verified copy, read-only, offline, as safetensors,
#   never with remote code (P5-08);
# - has the GPU through /dev/dxg (WSL2), or `--gpus all` when the NVIDIA
#   toolkit's CDI spec exists, and nothing else: not privileged, all
#   capabilities dropped, a read-only root file system (P5-09);
# - checks a bearer key that only the LLM gateway mounts (Secret
#   gateways/local-model-key), so a pod that gets past the network policy
#   still can't use it (P5-07).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

CLUSTER=${CLUSTER:-safe-ops}
NODE=$CLUSTER-control-plane
NAME=safe-ops-model
NET=safe-ops-models
SUBNET=172.30.99.0/28
IP=172.30.99.10
PORT=8000
# vLLM 0.30.0 for CUDA 12.9, with its torch repaired: see
# projects/05-local-inference/server/Dockerfile. Built here on first use.
SERVER_DIR=projects/05-local-inference/server
IMAGE=safe-ops-vllm:0.30.0-cu129
LOCK=${MODEL_LOCK:-projects/05-local-inference/models/qwen2.5-1.5b-instruct-awq.sha256}
CACHE=${MODEL_CACHE:-$HOME/.cache/safe-ops-models}
WEIGHTS=$CACHE/$(basename "$LOCK" .sha256)
KEY_FILE=${LOCAL_MODEL_KEY_FILE:-$HOME/.config/safe-ops/local-model-key}

field() { sed -n "s/^# $1: //p" "$LOCK"; }
REPO=$(field repo)
REVISION=$(field revision)
SERVED=$(field served-name)

# verify DIR: exactly the lock's files, each with its hash, and a config
# that asks for no remote code.
verify() {
  local dir=$1
  [ -d "$dir" ] || { echo "verify: $dir doesn't exist" >&2; return 1; }
  local want have
  want=$(grep -v '^#' "$LOCK" | awk '{print $2}' | sort)
  have=$(cd "$dir" && find . -type f -printf '%P\n' | sort)
  if [ "$want" != "$have" ]; then
    echo "verify: $dir has other files than the lock lists:" >&2
    diff <(echo "$want") <(echo "$have") >&2 || true
    return 1
  fi
  grep -v '^#' "$LOCK" | (cd "$dir" && sha256sum --check --quiet --strict) || {
    echo "verify: $dir doesn't match $LOCK" >&2; return 1; }
  if grep -q '"auto_map"' "$dir/config.json" "$dir/tokenizer_config.json"; then
    echo "verify: the config asks for remote code (auto_map)" >&2; return 1
  fi
}

fetch() {
  if [ -d "$WEIGHTS" ] && verify "$WEIGHTS" 2>/dev/null; then
    echo "weights: $WEIGHTS verified"; return
  fi
  mkdir -p "$CACHE"
  local tmp; tmp=$(mktemp -d "$CACHE/.fetch.XXXXXX")
  trap 'rm -rf "$tmp"' RETURN
  for f in $(grep -v '^#' "$LOCK" | awk '{print $2}'); do
    echo "fetch: $REPO@${REVISION:0:12} $f"
    curl -sSfL --retry 3 -o "$tmp/$f" "https://huggingface.co/$REPO/resolve/$REVISION/$f"
  done
  verify "$tmp"
  chmod -R a-w "$tmp"
  rm -rf "$WEIGHTS" 2>/dev/null || { chmod -R u+w "$WEIGHTS"; rm -rf "$WEIGHTS"; }
  mv "$tmp" "$WEIGHTS"
  echo "weights: $WEIGHTS verified"
}

network() {
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create --internal --subnet "$SUBNET" "$NET" >/dev/null
  # Only this cluster's node joins. Cilium masquerades pod traffic out of
  # the node's new interface (devices: eth+ in cluster/cilium-values.yaml).
  if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$NODE" | grep -q "\"$NET\""; then
    docker network connect "$NET" "$NODE"
  fi
}

key() {
  if [ ! -s "$KEY_FILE" ]; then
    mkdir -p "$(dirname "$KEY_FILE")"
    (umask 077; head -c 32 /dev/urandom | base64 | tr -d '=+/\n' > "$KEY_FILE")
  fi
  chmod 600 "$KEY_FILE"
  # The gateway's copy: mounted by the LLM gateway only (P3 manifests);
  # and the in-cluster server's (P5 M2), if its namespace exists.
  local ns
  for ns in gateways inference; do
    kubectl get namespace $ns >/dev/null 2>&1 || continue
    kubectl -n $ns create secret generic local-model-key --from-file=api-key="$KEY_FILE" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
}

gpu_flags() {
  if ls /etc/cdi/nvidia*.yaml /var/run/cdi/nvidia*.yaml >/dev/null 2>&1; then
    echo "--gpus all"
  else
    # WSL2 without the NVIDIA toolkit: the GPU is /dev/dxg, and the
    # driver is /usr/lib/wsl: lib/ has libcuda.so, a stub that loads the
    # real driver from drivers/ (with lib/ alone, "Found no NVIDIA
    # driver"). That's all the toolkit would map in too. Docker 29 turns
    # --gpus into a CDI request, which fails without the toolkit's spec
    # ("no known GPU vendor found").
    local ld; ld=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" | sed -n 's/^LD_LIBRARY_PATH=//p')
    echo "--device /dev/dxg -v /usr/lib/wsl:/usr/lib/wsl:ro -e LD_LIBRARY_PATH=/usr/lib/wsl/lib${ld:+:$ld}"
  fi
}

up() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -t "$IMAGE" "$SERVER_DIR"
  fetch
  verify "$WEIGHTS"
  network
  key
  # shellcheck disable=SC2207
  local run=(--network "$NET" --ip "$IP"
    $(gpu_flags)
    --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges
    --read-only --tmpfs /tmp:rw,exec,size=2g --shm-size 1g
    --memory 6g --pids-limit 512
    -v "$WEIGHTS:/models/$SERVED:ro"
    -e HOME=/tmp -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e VLLM_NO_USAGE_STATS=1 -e DO_NOT_TRACK=1)
  local args=(--model "/models/$SERVED" --served-model-name "$SERVED"
    --load-format safetensors --dtype float16
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.80}" --max-model-len "${MAX_MODEL_LEN:-4096}"
    --max-num-seqs 4 --enforce-eager
    --enable-auto-tool-choice --tool-call-parser hermes
    --host 0.0.0.0 --port "$PORT")
  # A ready server with this exact configuration (image, flags, weights,
  # key) is kept: a restart takes minutes.
  local config
  config=$( { docker image inspect -f '{{.Id}}' "$IMAGE"; echo "${run[*]} ${args[*]}"; cat "$LOCK" "$KEY_FILE"; } | sha256sum | cut -c1-16)
  if [ "$(docker inspect -f '{{index .Config.Labels "safe-ops.io/config"}}' "$NAME" 2>/dev/null)" = "$config" ] && ready; then
    echo "ready: $SERVED (already running)"; return
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  local envf; envf=$(mktemp); trap 'rm -f "$envf"' RETURN
  printf 'VLLM_API_KEY=%s\n' "$(cat "$KEY_FILE")" > "$envf"
  docker run -d --name "$NAME" --label "safe-ops.io/config=$config" "${run[@]}" --env-file "$envf" "$IMAGE" "${args[@]}" >/dev/null
  echo "waiting for $SERVED at $IP:$PORT"
  for _ in $(seq 1 90); do
    if ready; then echo "ready: $SERVED"; return; fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != true ]; then
      docker logs --tail 40 "$NAME" >&2; echo "the server exited" >&2; return 1
    fi
    sleep 5
  done
  docker logs --tail 40 "$NAME" >&2; echo "not ready after 450s" >&2; return 1
}

# ready: /health answers 200 to the cluster's node, the path pods take.
ready() { docker exec "$NODE" curl -sf -m 3 -o /dev/null "http://$IP:$PORT/health"; }

down() { docker rm -f "$NAME" >/dev/null 2>&1 && echo "stopped $NAME" || echo "$NAME isn't running"; }

status() {
  local st; st=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null | tr -d '\n') || true
  echo "server: ${st:-absent}, $(ready && echo ready || echo 'not ready')"
  echo "model: $SERVED ($REPO@${REVISION:0:12}) at http://$IP:$PORT"
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/gpu memory: /' || true
}

case "${1:-}" in
  fetch) fetch ;;
  verify) verify "${2:-$WEIGHTS}" && echo "verified: ${2:-$WEIGHTS}" ;;
  up) up ;;
  key) key ;;
  down) down ;;
  status) status ;;
  *) echo "usage: $0 fetch|verify [DIR]|up|down|key|status" >&2; exit 2 ;;
esac
