#!/usr/bin/env bash
# P5 milestone 4: GPU metrics (P5-06). Checks:
#  - the exporter: NVIDIA's DCGM exporter as a restricted pod on its own
#    time slice of the GPU, pinned by digest, no privilege, no host path,
#    no API token;
#  - it reads the GPU: Prometheus scrapes it, and its numbers agree with
#    nvidia-smi on the host (memory, temperature, driver); every device
#    counter on its list (no profiling ones here: README, finding 22);
#  - under load through the LLM gateway, utilization and power rise;
#  - only Prometheus reaches it: pods in namespace inference and in agent
#    can't connect, and a pod can't wear its label (admission);
#  - the alerts are loaded and quiet, and Grafana's dashboard answers;
#  - with the Docker server holding the GPU (the fallback), the exporter
#    still reports it, and back.
# Needs `make p2 p3 durable p4 evals p5`, the LLM gateway in mock mode.
# Takes about 6 minutes, most of it the fallback's two switches.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
T=$(date +%s)
MODEL=qwen2.5-1.5b-instruct
NS=inference
TMP=$(mktemp -d)
FAILED=0
PFS=()
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:400}"; fi; }
forward() { # NAMESPACE TARGET PORT LOCAL
  command kubectl --context "$KUBE_CONTEXT" port-forward -n "$1" "$2" "$4:$3" >/dev/null 2>&1 & PFS+=($!)
  for _ in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/$4) 2>/dev/null && return 0; sleep 1; done
  echo "port-forward to $2 didn't come up"; exit 1
}
token() { kubectl exec -n agent "$W" -- cat /var/run/secrets/safe-ops.io/llm-gateway/token > $TMP/tok.new && mv $TMP/tok.new $TMP/tok; }
msg() { # BODY -> "CODE BODY", as the agent's identity, through the LLM gateway
  local out=$TMP/out.$BASHPID   # per caller: the load runs three at once
  curl -s -o $out -w '%{http_code}' -H "Authorization: Bearer $(cat $TMP/tok)" -H 'content-type: application/json' \
    --max-time 180 --data "$1" localhost:$GWPORT/v1/messages; echo " $(cat $out 2>/dev/null)"
}
req() { # USER-TEXT MAX-TOKENS
  python3 -c 'import json, sys; print(json.dumps({"model": sys.argv[1], "max_tokens": int(sys.argv[3]), "messages": [{"role": "user", "content": sys.argv[2]}]}))' $MODEL "$1" "$2"
}
prom() { # QUERY -> the first value, or "-"
  kubectl exec -n observability "$PROM" -- wget -qO- "http://127.0.0.1:9090/api/v1/query?query=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")" \
    | python3 -c 'import json, sys; r = json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "-")'
}
near() { # A B TOLERANCE -> ok, or the two values
  python3 -c 'import sys; a, b, t = sys.argv[1:4]; print("ok" if a != "-" and b != "-" and abs(float(a) - float(b)) <= float(t) else a + " vs " + b)' "$1" "$2" "$3"
}
smi() { nvidia-smi --query-gpu="$1" --format=csv,noheader,nounits | head -1 | tr -d ' '; }
# A pod that passes Pod Security "restricted". pod NAME NAMESPACE COMMAND [LABELS-JSON]
pod() {
  python3 - "$@" <<'EOF'
import json, sys
name, ns, cmd = sys.argv[1:4]
labels = {"safe-ops.io/test-gpu-metrics": name}
labels.update(json.loads(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else {})
print(json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": ns, "labels": labels}, "spec": {
  "restartPolicy": "Never", "automountServiceAccountToken": False,
  "securityContext": {"runAsNonRoot": True, "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{"name": "c", "image": "python:3.13-slim", "imagePullPolicy": "IfNotPresent", "command": ["sh", "-c", cmd],
                  "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}}}]}}))
EOF
}
run_pod() { # same args as pod: create it, wait for it to end, print its log (or why it didn't run)
  local out; out=$(pod "$@" | kubectl create -f - 2>&1) || { echo "refused: $out"; return; }
  for _ in $(seq 1 60); do
    case "$(kubectl get pod -n "$2" "$1" -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac; sleep 2
  done
  kubectl logs -n "$2" "$1" 2>&1; kubectl delete pod -n "$2" "$1" --wait=false >/dev/null 2>&1 || true
}
probe() { # NAMESPACE IP PORT
  run_pod probe-$1-$T "$1" "python3 -c 'import socket
try: socket.create_connection((\"$2\", $3), timeout=5); print(\"connected\")
except Exception as e: print(\"refused:\", type(e).__name__)'" | grep -E 'connected|refused' || echo "no result"
}
LOADS=()
cleanup() {
  for p in "${LOADS[@]}" "${PFS[@]}"; do kill "$p" 2>/dev/null || true; done
  kubectl delete pod -A -l safe-ops.io/test-gpu-metrics --wait=false >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status"; exit 1; }
./scripts/llm-gateway-mode.sh mock >/dev/null
[[ "$(scripts/local-model-mode.sh status)" =~ ^cluster:\ [12]\ ready$ ]] || scripts/local-model-mode.sh cluster
PROM=$(kubectl get pod -n observability -l app=prometheus -o jsonpath='{.items[0].metadata.name}')

echo "=== The exporter (P5-06)"
kubectl rollout status -n $NS deploy/gpu-metrics --timeout=120s >/dev/null || true
P=$(kubectl get pod -n $NS -l app=gpu-metrics -o jsonpath='{.items[0].metadata.name}')
J=$(kubectl get pod -n $NS "$P" -o json)
f() { python3 -c 'import json,sys; p=json.loads(sys.stdin.read()); c=p["spec"]["containers"][0]; print(eval(sys.argv[1]))' "$1" <<<"$J"; }
check "the DCGM exporter runs in namespace $NS (Pod Security restricted)" '^Running restricted$' \
  "$(f 'p["status"]["phase"]') $(kubectl get ns $NS -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
check "... its image pinned by digest" '^nvcr\.io/nvidia/k8s/dcgm-exporter:[^@]+@sha256:[0-9a-f]{64}$' "$(f 'c["image"]')"
check "... holding one time slice of the GPU (nvidia.com/gpu: 1), as vLLM does" '^1$' "$(f 'c["resources"]["limits"]["nvidia.com/gpu"]')"
check "... with no privilege: non-root, no escalation, all capabilities dropped, read-only root" '^True False \[.ALL.\] True False$' \
  "$(f 'p["spec"]["securityContext"]["runAsNonRoot"], c["securityContext"]["allowPrivilegeEscalation"], c["securityContext"]["capabilities"]["drop"], c["securityContext"]["readOnlyRootFilesystem"], c["securityContext"].get("privileged", False)' | tr -d '(),')"
check "... no host path, no API token" '^0 False$' \
  "$(f 'len([v for v in p["spec"]["volumes"] if "hostPath" in v]), p["spec"]["automountServiceAccountToken"]' | tr -d '(),')"
check "the GPU's three slices: KEDA's two vLLM replicas at most, and the exporter" '^3 2$' \
  "$(kubectl get node safe-ops-control-plane -o jsonpath='{.status.allocatable.nvidia\.com/gpu}') $(kubectl get scaledobject -n $NS local-model -o jsonpath='{.spec.maxReplicaCount}')"

echo "=== It reads the GPU"
check "Prometheus scrapes it (up{job=\"gpu\"})" '^1$' "$(prom 'up{job="gpu"}')"
HOST=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -1 | sed 's/, / /')
check "... the host's GPU, by name and driver version, as nvidia-smi reports them ($HOST)" "^${HOST}$" \
  "$(kubectl exec -n observability "$PROM" -- wget -qO- 'http://127.0.0.1:9090/api/v1/query?query=DCGM_FI_DEV_GPU_TEMP' \
     | python3 -c 'import json,sys; m=json.load(sys.stdin)["data"]["result"][0]["metric"]; print(m["modelName"], m["DCGM_FI_DRIVER_VERSION"])')"
check "GPU memory used agrees with nvidia-smi on the host (within 64 MiB)" '^ok$' "$(near "$(prom 'DCGM_FI_DEV_FB_USED')" "$(smi memory.used)" 64)"
check "... and the total (used, reserved, free) with its total" '^ok$' \
  "$(near "$(prom 'DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE + DCGM_FI_DEV_FB_RESERVED')" "$(smi memory.total)" 64)"
check "temperature agrees with nvidia-smi (within 5C)" '^ok$' "$(near "$(prom 'DCGM_FI_DEV_GPU_TEMP')" "$(smi temperature.gpu)" 5)"
check "it reports all 13 device counters on its list (this driver has no profiling ones)" '^13$' \
  "$(prom 'count(count by (__name__) ({job="gpu", __name__=~"DCGM_FI_DEV_.*"}))')"

echo "=== Under load"
W=$(kubectl get pod -n agent -l app=agent-worker -o jsonpath='{.items[0].metadata.name}')
token
GWPORT=38191; forward gateways svc/llm-gateway 8080 $GWPORT
idle=$(prom 'max_over_time(DCGM_FI_DEV_POWER_USAGE[1m])')
# Three at a time, below KEDA's four in flight: the GPU busy, no scale-up.
# The gateway's per-identity request rate may refuse some (429): paced.
for i in 1 2 3; do
  (end=$((SECONDS + 75)); while [ $SECONDS -lt $end ]; do msg "$(req "Write a long story about GPU number $i." 300)" | cut -c1-3 >> $TMP/load; sleep 1; done) & LOADS+=($!)
done
sleep 80; for p in "${LOADS[@]}"; do wait "$p" 2>/dev/null || true; done; LOADS=()
sleep 20   # the exporter's 10s sample and Prometheus's 15s scrape
check "the load was answered through the LLM gateway (200), or held to its rate limit (429), nothing else" '^200 [1-9][0-9]*( 429 [0-9]+)?$' \
  "$(sort $TMP/load | uniq -c | awk '{print $2, $1}' | tr '\n' ' ' | sed 's/ $//')"
check "GPU utilization rose under it (above 30% at its peak)" '^ok$' \
  "$(python3 -c 'import sys; v=sys.argv[1]; print("ok" if v != "-" and float(v) > 30 else v)' "$(prom 'max_over_time(DCGM_FI_DEV_GPU_UTIL[2m])')")"
check "... and power draw too (peak above the idle minute before)" '^ok$' \
  "$(python3 -c 'import sys; a, b = sys.argv[1:3]; print("ok" if "-" not in (a, b) and float(b) > float(a) + 2 else a + " -> " + b)' "$idle" "$(prom 'max_over_time(DCGM_FI_DEV_POWER_USAGE[2m])')")"
check "... with one vLLM replica still: three in flight is below KEDA's target" '^1$' "$(kubectl get deploy -n $NS local-model -o jsonpath='{.spec.replicas}')"

echo "=== Only Prometheus reaches it (P5-07)"
IP=$(kubectl get pod -n $NS "$P" -o jsonpath='{.status.podIP}')
check "a pod in $NS can't connect to the exporter" '^refused' "$(probe $NS "$IP" 9400)"
check "... nor the agent's namespace" '^refused' "$(probe agent "$IP" 9400)"
check "a pod can't wear the exporter's label (app=gpu-metrics) to pass for it" '^refused: .*inference-pool-membership' \
  "$(run_pod impostor-$T $NS 'sleep 1' '{"app": "gpu-metrics"}' | tr '\n' ' ')"

echo "=== Alerts and the dashboard"
rules=$(kubectl exec -n observability "$PROM" -- wget -qO- 'http://127.0.0.1:9090/api/v1/rules' \
  | python3 -c 'import json,sys; [print(r["name"], r["state"]) for g in json.load(sys.stdin)["data"]["groups"] if g["name"]=="local-inference" for r in g["rules"]]')
for a in GPUMetricsDown GPUMemoryNearlyFull GPUHot LocalModelAtCapacity; do
  check "Prometheus has the alert $a, not firing" "^$a inactive$" "$(grep "^$a " <<<"$rules")"
done
forward observability svc/grafana 3000 23100
dash=$(curl -s localhost:23100/api/dashboards/uid/local-inference)
titles=$(python3 -c 'import json,sys; [print(p["title"]) for p in json.load(sys.stdin)["dashboard"]["panels"]]' <<<"$dash" 2>/dev/null || true)
for t in "GPU utilization" "GPU memory used" "GPU temperature" "Requests in flight in the pool"; do
  check "Grafana's local-inference dashboard has '$t'" "^$t$" "$titles"
done
q=$(python3 -c 'import json,sys; print([t["expr"] for p in json.load(sys.stdin)["dashboard"]["panels"] if p["title"]=="GPU memory used" for t in p["targets"]][0])' <<<"$dash")
check "... and answers 'GPU memory used' with a share" '^ok$' \
  "$(python3 -c 'import json,sys; print(json.dumps({"from":"now-15m","to":"now","queries":[{"refId":"A","datasource":{"type":"prometheus","uid":"prometheus"},"expr":sys.argv[1],"instant":True}]}))' "$q" \
     | curl -s -H 'Content-Type: application/json' localhost:23100/api/ds/query -d @- \
     | python3 -c 'import json,sys; f=json.load(sys.stdin)["results"]["A"]["frames"]; v=f[0]["data"]["values"][1][0] if f and f[0]["data"]["values"] else None; print("ok" if v is not None and 0 < v <= 1 else v)')"

echo "=== The fallback: the GPU in Docker, still measured"
scripts/local-model-mode.sh docker > $TMP/docker.log 2>&1 && pass "switched to the Docker server outside the cluster" || fail "docker mode: $(tail -5 $TMP/docker.log)"
sleep 30
check "... no vLLM pod in the cluster, the exporter still up" '^0 1$' \
  "$(kubectl get pods -n $NS -l app=local-model --no-headers 2>/dev/null | wc -l) $(prom 'up{job="gpu"}')"
check "... and its memory figure is the Docker server's (agrees with nvidia-smi, over 1 GB)" '^ok$' \
  "$(python3 -c 'import sys; a, b = sys.argv[1:3]; print("ok" if "-" not in (a, b) and abs(float(a) - float(b)) <= 64 and float(a) > 1000 else a + " vs " + b)' "$(prom 'DCGM_FI_DEV_FB_USED')" "$(smi memory.used)")"
scripts/local-model-mode.sh cluster > $TMP/cluster.log 2>&1 && pass "switched back to the cluster" || fail "cluster mode: $(tail -5 $TMP/cluster.log)"

[ $FAILED = 0 ] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
