#!/usr/bin/env bash
# P5 milestone 2: the GPU inside the cluster (P5-03, P5-07..P5-09). Checks:
#  - the node: the WSL driver, the toolkit's CDI hook, the device plugin
#    registered and advertising nvidia.com/gpu;
#  - the local model as a restricted pod: no privilege, the GPU as a CDI
#    device, weights verified before it starts (and refused when they
#    don't match);
#  - who may get the GPU: only namespace inference; not the code sandbox,
#    not a pod by CDI annotation (refused by admission, and ignored by
#    containerd with the policy removed); one GPU, so a second claim waits;
#  - through the LLM gateway only: an answer and a forced tool call for the
#    agent's identity; pods elsewhere can't connect; the server wants its
#    key; one eval scenario judged by the in-cluster model;
#  - the fallback: switch to the Docker server outside the cluster and back.
# Needs `make p2 p3 durable p4 evals p5`, the LLM gateway in mock mode.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
T=$(date +%s)
MODEL=qwen2.5-1.5b-instruct
NODE=safe-ops-control-plane
NS=inference
TMP=$(mktemp -d)
FAILED=0
PFS=()
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:400}"; fi; }
forward() { # NAMESPACE TARGET PORT LOCAL
  # command: kubectl is a function (lib.sh); backgrounding the function
  # puts $! on a subshell, and killing that leaves the port-forward running.
  command kubectl --context "$KUBE_CONTEXT" port-forward -n "$1" "$2" "$4:$3" >/dev/null 2>&1 & PFS+=($!)
  for _ in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/$4) 2>/dev/null && return 0; sleep 1; done
  echo "port-forward to $2 didn't come up"; exit 1
}
msg() { # BODY -> "CODE BODY", as the agent's identity, through the gateway
  curl -s -o $TMP/out -w '%{http_code}' -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
    --max-time 120 --data "$1" localhost:$GWPORT/v1/messages; echo " $(cat $TMP/out)"
}
req() { # MODEL USER-TEXT [EXTRA-JSON]
  python3 -c 'import json, sys; b = {"model": sys.argv[1], "max_tokens": 200, "messages": [{"role": "user", "content": sys.argv[2]}]}; b.update(json.loads(sys.argv[3])); print(json.dumps(b))' "$1" "$2" "${3:-{\}}"
}
# A pod that passes Pod Security "restricted", so admission policy is what
# decides. pod NAME NAMESPACE COMMAND [EXTRA-JSON merged into the spec] [ANNOTATIONS-JSON]
pod() {
  python3 - "$@" <<'EOF'
import json, sys
name, ns, cmd = sys.argv[1:4]
extra = json.loads(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else {}
ann = json.loads(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else {}
c = {"name": "c", "image": "ubuntu:24.04", "imagePullPolicy": "IfNotPresent", "command": ["sh", "-c", cmd],
     "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}}}
c.update(extra.pop("container", {}))
spec = {"restartPolicy": "Never", "automountServiceAccountToken": False, "containers": [c],
        "securityContext": {"runAsNonRoot": True, "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}}}
spec.update(extra)
print(json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": ns, "annotations": ann,
                  "labels": {"safe-ops.io/test-gpu": sys.argv[1]}}, "spec": spec}))
EOF
}
run_pod() { # same args as pod: create it, wait for it to end, print its log (or why it didn't run)
  local out; out=$(pod "$@" | kubectl create -f - 2>&1) || { echo "refused: $out"; return; }
  for _ in $(seq 1 60); do
    case "$(kubectl get pod -n "$2" "$1" -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac; sleep 2
  done
  kubectl logs -n "$2" "$1" 2>&1; kubectl delete pod -n "$2" "$1" --wait=false >/dev/null 2>&1 || true
}
GPU='{"container": {"resources": {"limits": {"nvidia.com/gpu": "1"}}}}'
cleanup() {
  for p in "${PFS[@]}"; do kill "$p" 2>/dev/null || true; done
  kubectl apply -f projects/05-local-inference/manifests/20-gpu-admission.yaml >/dev/null 2>&1 || true
  kubectl delete pod -A -l safe-ops.io/test-gpu --wait=false >/dev/null 2>&1 || true
  kubectl delete configmap -n $NS local-model-lock-bad-$T --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status"; exit 1; }
./scripts/llm-gateway-mode.sh mock >/dev/null
[[ "$(scripts/local-model-mode.sh status)" == "cluster: 1 ready" ]] || scripts/local-model-mode.sh cluster

echo "=== The GPU in the node (P5-03)"
check "the node has the host's WSL driver, current" '\(current\)' "$(scripts/node-gpu.sh status)"
check "... and the NVIDIA toolkit's CDI hook, pinned" 'NVIDIA CDI Hook version 1\.20\.1' "$(docker exec $NODE /usr/local/nvidia-toolkit/bin/nvidia-cdi-hook --version 2>&1 | head -1)"
check "the device plugin registered nvidia.com/gpu with the kubelet" 'Registered device plugin for .nvidia.com/gpu.' \
  "$(kubectl logs -n gpu-system ds/nvdp-nvidia-device-plugin 2>&1 | grep Registered | tail -1)"
check "the node advertises one GPU" '^1$' "$(kubectl get node $NODE -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')"
check "the plugin's CDI spec gives /dev/dxg and the WSL driver" 'k8s.device-plugin.nvidia.com/gpu.*"/dev/dxg".*/usr/lib/wsl/drivers' \
  "$(docker exec $NODE cat /var/run/cdi/k8s.device-plugin.nvidia.com-gpu.json | tr -d '\n ')"

echo "=== The local model, a restricted pod on the GPU (P5-03, P5-09)"
P=$(kubectl get pod -n $NS -l app=local-model -o jsonpath='{.items[0].metadata.name}')
J=$(kubectl get pod -n $NS "$P" -o json)
f() { python3 -c 'import json,sys; p=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1" <<<"$J"; }
check "vLLM runs in namespace $NS, which enforces Pod Security restricted" '^restricted$' \
  "$(kubectl get ns $NS -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
check "... asking for one GPU" '^1$' "$(f 'p["spec"]["containers"][0]["resources"]["limits"]["nvidia.com/gpu"]')"
check "... not privileged, all capabilities dropped, non-root, read-only root" '^False \[.ALL.\] 1000 True$' \
  "$(f 'p["spec"]["containers"][0]["securityContext"].get("privileged", False), p["spec"]["containers"][0]["securityContext"]["capabilities"]["drop"], p["spec"]["securityContext"]["runAsUser"], p["spec"]["containers"][0]["securityContext"]["readOnlyRootFilesystem"]' | tr -d '(),')"
check "... no host path in its spec (the weights are a pre-bound volume)" '^0$' "$(f 'sum("hostPath" in v for v in p["spec"]["volumes"])')"
check "... its weights verified before it started" 'weights verified' "$(kubectl logs -n $NS "$P" -c verify-weights 2>&1)"
check "... and CUDA sees the GPU inside it" 'True NVIDIA GeForce RTX 3050' \
  "$(kubectl exec -n $NS "$P" -c vllm -- python3 -c 'import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))' 2>&1 | tail -1)"
check "... using its memory (MiB, as the host sees it)" '^[1-9][0-9]{3}$' "$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' ')"
# Weights that don't match the lock: the same check, against a lock with one hash changed.
sed '0,/^[0-9a-f]\{64\}  config.json$/s//0000000000000000000000000000000000000000000000000000000000000000  config.json/' \
  projects/05-local-inference/models/qwen2.5-1.5b-instruct-awq.sha256 > $TMP/bad.sha256
kubectl create configmap -n $NS local-model-lock-bad-$T --from-file=lock.sha256=$TMP/bad.sha256 >/dev/null
VERIFY=$(kubectl get deploy -n $NS local-model -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["spec"]["template"]["spec"]["initContainers"][0]["command"][2])')
out=$(run_pod verify-$T $NS "$VERIFY" "$(python3 -c 'import json,sys; print(json.dumps({"container": {"image": "safe-ops-vllm:0.30.0-cu129", "imagePullPolicy": "Never", "volumeMounts": [{"name": "w", "mountPath": "/models/qwen2.5-1.5b-instruct", "readOnly": True}, {"name": "l", "mountPath": "/lock", "readOnly": True}]}, "volumes": [{"name": "w", "persistentVolumeClaim": {"claimName": "local-model-weights", "readOnly": True}}, {"name": "l", "configMap": {"name": sys.argv[1]}}]}))' local-model-lock-bad-$T)")
check "weights that don't match the lock stop the server before it starts" 'config.json: FAILED' "$out"

echo "=== Who may get the GPU (P5-09)"
check "a pod in another namespace asking for it is refused (default)" 'refused: .*is for namespace inference only' \
  "$(run_pod gpu-$T default 'ls /dev/dxg' "$GPU")"
check "... and the code sandbox (namespace sandboxes, gVisor)" 'refused: .*is for namespace inference only' \
  "$(run_pod gpu-$T sandboxes 'ls /dev/dxg' "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["runtimeClassName"]="gvisor"; print(json.dumps(d))' "$GPU")")"
ANN='{"cdi.k8s.io/x": "k8s.device-plugin.nvidia.com/gpu=all"}'
check "a pod asking containerd for the GPU by CDI annotation is refused" 'refused: .*CDI devices by annotation' \
  "$(run_pod cdi-$T default 'ls /dev/dxg' '' "$ANN")"
kubectl delete validatingadmissionpolicybinding gpu-only-for-inference >/dev/null; sleep 3
check "... and with the policy removed, containerd ignores the annotation: no GPU" 'No such file' \
  "$(run_pod cdi2-$T default 'ls /dev/dxg 2>&1' '' "$ANN")"
kubectl apply -f projects/05-local-inference/manifests/20-gpu-admission.yaml >/dev/null; sleep 3
check "... (the policy restored)" '^gpu-only-for-inference$' "$(kubectl get validatingadmissionpolicybinding gpu-only-for-inference -o name | cut -d/ -f2)"
check "a pod in $NS that doesn't ask for the GPU doesn't get it" 'No such file' "$(run_pod nogpu-$T $NS 'ls /dev/dxg 2>&1')"
pod second-$T $NS 'sleep 5' "$GPU" | kubectl create -f - >/dev/null; sleep 8
check "one GPU: a second claim waits while vLLM holds it (Pending, insufficient nvidia.com/gpu)" 'Pending.*Insufficient nvidia.com/gpu' \
  "$(kubectl get pod -n $NS second-$T -o jsonpath='{.status.phase} {.status.conditions[0].message}')"
kubectl delete pod -n $NS second-$T --wait=false >/dev/null

echo "=== Through the LLM gateway only (P5-07)"
check "the gateway routes the local model to the in-cluster server" "^cluster: 1 ready$" "$(scripts/local-model-mode.sh status)"
W=$(kubectl get pod -n agent -l app=agent-worker -o jsonpath='{.items[0].metadata.name}')
TOK=$(kubectl exec -n agent "$W" -- cat /var/run/secrets/safe-ops.io/llm-gateway/token)
GWPORT=38081; forward gateways svc/llm-gateway 8080 $GWPORT
out=$(msg "$(req $MODEL 'Answer with one word: what is the capital of France?')")
check "the agent's identity gets an answer from the in-cluster model (200)" "^200 .*\"type\": ?\"text\".*\"model\": ?\"$MODEL\"" "$out"
JUDGE='{"tools": [{"name": "record_verdict", "description": "Record the grade.", "input_schema": {"type": "object", "additionalProperties": false, "required": ["verdict", "rationale"], "properties": {"verdict": {"type": "string", "enum": ["pass", "fail"]}, "rationale": {"type": "string"}}}}], "tool_choice": {"type": "tool", "name": "record_verdict"}}'
check "... and a forced tool call with a valid verdict" '"name": ?"record_verdict".*"verdict": ?"(pass|fail)"' \
  "$(msg "$(req $MODEL 'The task: restart web. The outcome: RestartDeployment. Grade it.' "$JUDGE")")"
# By the Service's address, not its name: the agent's namespace may only
# resolve the gateways' names, and the point is the connection.
SVC_IP=$(kubectl get svc -n $NS local-model -o jsonpath='{.spec.clusterIP}')
connect='import socket
try: socket.create_connection(("'$SVC_IP'", 8000), timeout=5); print("connected")
except Exception as e: print("refused:", type(e).__name__)'
probe() { # NAMESPACE [LABELS-JSON]
  run_pod probe-$T "$1" "python3 -c '$connect'" "{\"container\": {\"image\": \"python:3.13-slim\"}}" | grep -E 'connected|refused' || echo "no result"
}
check "a pod in a namespace with no network policy (default) can't connect" 'refused' "$(probe default)"
check "... nor one in the agent's namespace" 'refused' "$(probe agent)"
check "... nor another pod in $NS" 'refused' "$(probe $NS)"
check "the server refuses a request without its key (401)" '^401$' \
  "$(kubectl exec -n $NS "$P" -c vllm -- python3 -c 'import urllib.request, urllib.error
try: urllib.request.urlopen("http://127.0.0.1:8000/v1/models", timeout=5); print(200)
except urllib.error.HTTPError as e: print(e.code)' 2>&1 | tail -1)"
RUN=gj-$T
JUDGE_MODEL=$MODEL scripts/eval-run.sh $RUN incident-restart > $TMP/run.log 2>&1 && pass "an eval scenario judged by the in-cluster model completes" \
  || fail "eval run: $(tail -5 $TMP/run.log)"
check "... with a verdict, not an error" '^(pass|fail) qwen2.5-1.5b-instruct$' \
  "$(kubectl get evalrun -n evals $RUN -o jsonpath='{.spec.scenarios[0].judge.verdict} {.spec.judge.model}' 2>/dev/null)"

echo "=== The fallback: outside the cluster, and back"
# Each switch restarts the gateway: a new port-forward on a fresh local
# port (a killed one can still hold the old port for a moment), and a fresh
# token (the agent's is short-lived, and this suite is long).
reforward() {
  for p in "${PFS[@]}"; do kill "$p" 2>/dev/null || true; done; PFS=()
  GWPORT=$((GWPORT + 1)); forward gateways svc/llm-gateway 8080 $GWPORT
  TOK=$(kubectl exec -n agent "$W" -- cat /var/run/secrets/safe-ops.io/llm-gateway/token)
}
scripts/local-model-mode.sh docker > $TMP/docker.log 2>&1 && pass "switched to the Docker server (the in-cluster one stopped first)" || fail "docker mode: $(tail -5 $TMP/docker.log)"
check "... the in-cluster server is at zero" '^0$' "$(kubectl get deploy -n $NS local-model -o jsonpath='{.spec.replicas}')"
reforward
check "... and the gateway answers from it" '^200 ' "$(msg "$(req $MODEL 'Say hi.')")"
scripts/local-model-mode.sh cluster > $TMP/cluster.log 2>&1 && pass "switched back to the cluster (the Docker server stopped first)" || fail "cluster mode: $(tail -5 $TMP/cluster.log)"
check "... the Docker server is gone" 'absent' "$(scripts/model-server.sh status | head -1)"
reforward
check "... and the gateway answers from the cluster again" '^200 ' "$(msg "$(req $MODEL 'Say hi.')")"

echo
[ $FAILED = 0 ] && echo "ALL PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
