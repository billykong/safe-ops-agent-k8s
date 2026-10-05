#!/usr/bin/env bash
# Milestone 5: startup latency (warm-pool claim vs cold Sandbox, gVisor and
# runc) and runtime overhead (gVisor vs runc on the same template). The
# client runs in-cluster as a bench identity in the agent namespace, so it
# sees what the agent sees. Writes
# projects/01-sandboxed-code-exec/results/benchmarks.md, with the raw samples
# in benchmarks.jsonl (re-render with bench/report.py).
#
# Usage: scripts/bench.sh [WARM_SAMPLES] [COLD_SAMPLES] [OVERHEAD_REPS] [BURST]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
WARM=${1:-10} COLD=${2:-8} REPS=${3:-7} BURST=${4:-4}
# Kata joins the comparison when `make kata` has installed it.
RUNTIMES=gvisor,runc
kubectl get runtimeclass kata-clh >/dev/null 2>&1 && RUNTIMES=$RUNTIMES,kata
P1=projects/01-sandboxed-code-exec
REPORT=$P1/results/benchmarks.md
RAW=$P1/results/benchmarks.jsonl
TMP=$(mktemp -d)
cleanup() {
  kubectl delete pod -n agent bench-client --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete sandbox -n sandboxes -l bench=p1 --wait=false >/dev/null 2>&1 || true
  for c in $(kubectl get sandboxclaim -n sandboxes -o name 2>/dev/null | grep '/bench-'); do
    kubectl delete -n sandboxes "$c" --wait=false >/dev/null 2>&1 || true
  done
  kubectl delete -f $P1/bench/rbac.yaml --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete configmap -n agent bench-client --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

kubectl apply -f $P1/bench/rbac.yaml >/dev/null
kubectl create configmap bench-client -n agent --from-file=$P1/bench/bench_client.py \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl delete pod -n agent bench-client --ignore-not-found --wait=true >/dev/null
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: bench-client, namespace: agent, labels: {app: agent}}
spec:
  serviceAccountName: bench
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: client
    image: python:3.13-slim
    command: ["python", "/client/bench_client.py", "$WARM", "$COLD", "$REPS", "$BURST", "$RUNTIMES"]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
    volumeMounts: [{name: client, mountPath: /client}]
  volumes: [{name: client, configMap: {name: bench-client}}]
YAML
echo "bench ($RUNTIMES): $WARM warm claims, $COLD cold starts per runtime, burst of $BURST, $REPS overhead reps"
kubectl wait -n agent pod/bench-client --for=jsonpath='{.status.phase}'=Running --timeout=120s >/dev/null
cat > "$TMP/progress.py" <<'EOF'
import json, sys
for line in sys.stdin:
    try:
        r = json.loads(line)
    except ValueError:
        print("  " + line.rstrip(), flush=True)  # e.g. a traceback from the client
        continue
    if r["kind"] == "latency":
        print(f"  {r['mode']:13} {r['runtime']:6} ready {r['ready_ms']:7.0f} ms  first run {r['first_run_ms']:7.0f} ms", flush=True)
    elif r["kind"] == "burst":
        print(f"  burst {r['i']+1}/{r['n']} (pool {r['pool']}) ready {r['ready_ms']:7.0f} ms  first run {r['first_run_ms']:7.0f} ms", flush=True)
    elif r["kind"] == "overhead" and r["workload"] == "empty-run":
        print(f"  overhead rep {r['rep']} {r['runtime']}", flush=True)
    elif r["kind"] == "error":
        print("  ERROR", line.strip(), flush=True)
EOF
# Live progress is best-effort (a log follow can drop); the results are the
# full log once the pod has finished.
kubectl logs -n agent bench-client -f | python3 "$TMP/progress.py" || true
kubectl wait -n agent pod/bench-client --for=jsonpath='{.status.phase}'=Succeeded --timeout=1200s >/dev/null || true
phase=$(kubectl get pod -n agent bench-client -o jsonpath='{.status.phase}')
kubectl logs -n agent bench-client > "$TMP/results.jsonl"
[ "$phase" = Succeeded ] || { echo "bench client $phase"; tail -5 "$TMP/results.jsonl"; exit 1; }

# Record the environment with the samples, then render the report from them.
python3 - "$(docker exec "${CLUSTER:-safe-ops}-control-plane" runsc --version | head -1)" \
  "$(lscpu | sed -n 's/^Model name: *//p')" "$(nproc)" "$(uname -r)" >> "$TMP/results.jsonl" <<'EOF'
import datetime, json, sys
runsc, cpu, ncpu, kernel = sys.argv[1:5]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
print(json.dumps({"kind": "env", "time": now, "runsc": runsc, "cpu": cpu, "ncpu": ncpu, "kernel": kernel}))
EOF
cp "$TMP/results.jsonl" $RAW
python3 $P1/bench/report.py $RAW $REPORT
