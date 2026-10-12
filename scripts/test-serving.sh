#!/usr/bin/env bash
# P5 milestone 3: the serving stack (P5-05; P5-07 still). Checks:
#  - the stack: Gateway API and InferencePool CRDs, agentgateway's Gateway
#    and route to the pool, accepted and programmed; the proxy on a
#    ClusterIP only; every image pinned by digest;
#  - least privilege: agentgateway writes only in namespace inference;
#    KEDA watches it only and reads no other namespace's Secrets; all three
#    namespaces enforce Pod Security restricted. agentgateway's controller
#    still reads every Secret: reported as GAP-10;
#  - through the pool: the agent's request answered by a pod the endpoint
#    picker chose; the picker's metrics want a token;
#  - the LLM gateway is still the only way in: pods elsewhere, and other
#    pods in namespace inference, can't reach the proxy or vLLM; a pod can't
#    join the pool (or pass for the proxy) by wearing its labels;
#  - autoscaling on queue depth: under load (6 concurrent requests; vLLM
#    runs 4 at once) KEDA asks for a second replica, which comes up on a
#    second GPU time slice and serves; with the load gone, back to one.
#    Requests may time out (503) only while the second replica starts: it
#    slows the one serving (README, finding 21).
# Needs `make p2 p3 durable p4 evals p5`, the LLM gateway in mock mode.
# Takes about 15 minutes, most of it the second replica starting and the
# scale-down window; about 50k tokens of the agent's hourly budget.
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
  # command: kubectl is a function (lib.sh); backgrounding the function
  # puts $! on a subshell, and killing that leaves the port-forward running.
  command kubectl --context "$KUBE_CONTEXT" port-forward -n "$1" "$2" "$4:$3" >/dev/null 2>&1 & PFS+=($!)
  for _ in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/$4) 2>/dev/null && return 0; sleep 1; done
  echo "port-forward to $2 didn't come up"; exit 1
}
token() { kubectl exec -n agent "$W" -- cat /var/run/secrets/safe-ops.io/llm-gateway/token > $TMP/tok.new && mv $TMP/tok.new $TMP/tok; }
msg() { # BODY -> "CODE BODY", as the agent's identity, through the LLM gateway
  curl -s -o $TMP/out -w '%{http_code}' -H "Authorization: Bearer $(cat $TMP/tok)" -H 'content-type: application/json' \
    --max-time 180 --data "$1" localhost:$GWPORT/v1/messages; echo " $(cat $TMP/out)"
}
req() { # USER-TEXT MAX-TOKENS
  python3 -c 'import json, sys; print(json.dumps({"model": sys.argv[1], "max_tokens": int(sys.argv[3]), "messages": [{"role": "user", "content": sys.argv[2]}]}))' $MODEL "$1" "$2"
}
prom() { # QUERY -> the first value, or "-"
  kubectl exec -n observability "$PROM" -- wget -qO- "http://127.0.0.1:9090/api/v1/query?query=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")" \
    | python3 -c 'import json, sys; r = json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "-")'
}
picked() { prom "sum(llm_d_epp_scheduler_attempts_total{status=\"success\"${1:+,endpoint_name=\"$1\"}}) or vector(0)"; }
replicas() { kubectl get deploy -n $NS local-model -o jsonpath='{.spec.replicas} {.status.readyReplicas}'; }
# A pod that passes Pod Security "restricted". pod NAME NAMESPACE COMMAND [LABELS-JSON]
pod() {
  python3 - "$@" <<'EOF'
import json, sys
name, ns, cmd = sys.argv[1:4]
labels = {"safe-ops.io/test-serving": name}
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
  run_pod probe-$T "$1" "python3 -c 'import socket
try: socket.create_connection((\"$2\", $3), timeout=5); print(\"connected\")
except Exception as e: print(\"refused:\", type(e).__name__)'" | grep -E 'connected|refused' || echo "no result"
}
LOAD=
cleanup() {
  [ -n "$LOAD" ] && kill $LOAD 2>/dev/null || true
  for p in "${PFS[@]}"; do kill "$p" 2>/dev/null || true; done
  kubectl delete pod -A -l safe-ops.io/test-serving --wait=false >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status"; exit 1; }
./scripts/llm-gateway-mode.sh mock >/dev/null
[[ "$(scripts/local-model-mode.sh status)" =~ ^cluster:\ [12]\ ready$ ]] || scripts/local-model-mode.sh cluster
PROM=$(kubectl get pod -n observability -l app=prometheus -o jsonpath='{.items[0].metadata.name}')

echo "=== The stack (P5-05)"
check "InferencePool is served at inference.networking.k8s.io/v1 (GIE v1.6.2)" '^v1:true$' \
  "$(kubectl get crd inferencepools.inference.networking.k8s.io -o jsonpath='{range .spec.versions[*]}{.name}:{.served}{end}')"
check "the agentgateway GatewayClass is accepted" '^True$' \
  "$(kubectl get gatewayclass agentgateway -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')"
check "the Gateway inference-gateway is programmed" '^True$' \
  "$(kubectl get gateway -n $NS inference-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"
check "its route to the InferencePool is accepted, and the pool resolved" '^True True$' \
  "$(kubectl get httproute -n $NS local-model -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status} {.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')"
check "the pool selects the vLLM pods and names its endpoint picker" '^local-model 8000 local-model-epp FailOpen$' \
  "$(kubectl get inferencepool -n $NS local-model -o jsonpath='{.spec.selector.matchLabels.app} {.spec.targetPorts[0].number} {.spec.endpointPickerRef.name} {.spec.endpointPickerRef.failureMode}')"
check "the proxy has a ClusterIP Service: no NodePort (the default LoadBalancer would open one)" '^ClusterIP $' \
  "$(kubectl get svc -n $NS inference-gateway -o jsonpath='{.spec.type} {.spec.ports[*].nodePort}')"
check "every image in the stack is pinned by digest" '^(\S+@sha256:[0-9a-f]{64} ?){5}$' \
  "$(for x in "$NS deploy/local-model-epp" "$NS deploy/inference-gateway" "agentgateway-system deploy/agentgateway" "keda deploy/keda-operator" "keda deploy/keda-operator-metrics-apiserver"; do
       set -- $x; kubectl get -n $1 $2 -o jsonpath='{.spec.template.spec.containers[0].image} '; done | sed 's/ $//')"

echo "=== Least privilege"
AGW=system:serviceaccount:agentgateway-system:agentgateway
check "agentgateway may create Deployments in $NS, where its Gateway is" '^yes$' "$(kubectl auth can-i create deployments -n $NS --as $AGW)"
check "... and not in other namespaces (default, gateways)" '^no no$' \
  "$(echo $(kubectl auth can-i create deployments -n default --as $AGW; kubectl auth can-i create deployments -n gateways --as $AGW))"
KEDA=system:serviceaccount:keda:keda-operator
check "KEDA watches namespace $NS only" '^inference$' \
  "$(kubectl get deploy -n keda keda-operator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="WATCH_NAMESPACE")].value}')"
check "... and may not read Secrets outside its namespace (gateways, $NS)" '^no no$' \
  "$(echo $(kubectl auth can-i get secrets -n gateways --as $KEDA; kubectl auth can-i get secrets -n $NS --as $KEDA))"
# Its reads are another matter: one cluster-wide Secret informer (GAP-10).
if [ "$(kubectl auth can-i list secrets -n gateways --as $AGW)" = yes ]; then
  echo "GAP   GAP-10: agentgateway's controller may read Secrets in every namespace (gateways included)"
else
  pass "agentgateway's controller may not read other namespaces' Secrets"
fi
check "agentgateway-system, keda and $NS enforce Pod Security restricted" '^restricted restricted restricted$' \
  "$(echo $(for n in agentgateway-system keda $NS; do kubectl get ns $n -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'; echo; done))"

echo "=== Through the pool"
W=$(kubectl get pod -n agent -l app=agent-worker -o jsonpath='{.items[0].metadata.name}')
token
GWPORT=38091; forward gateways svc/llm-gateway 8080 $GWPORT
check "the LLM gateway routes the local model to the inference gateway" '^qwen2\.5-1\.5b-instruct=http://inference-gateway\.inference\.svc\.cluster\.local:8080$' \
  "$(kubectl get deploy -n gateways llm-gateway -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROUTES")].value}')"
before=$(picked)
check "the agent's identity gets an answer through the LLM gateway, the proxy and the pool (200)" "^200 .*\"type\": ?\"text\".*\"model\": ?\"$MODEL\"" \
  "$(msg "$(req 'Answer with one word: what is the capital of France?' 50)")"
for _ in $(seq 1 12); do [ "$(picked)" != "$before" ] && break; sleep 5; done
check "... sent to the pod the endpoint picker chose (its scheduling count went up)" '^[1-9]' \
  "$(python3 -c 'import sys; print(int(float(sys.argv[2]) - float(sys.argv[1])))' "$before" "$(picked)")"
check "the picker's metrics refuse a scrape without a token (401)" '401' \
  "$(kubectl exec -n observability "$PROM" -- wget -S -O /dev/null http://local-model-epp.inference.svc.cluster.local:9090/metrics 2>&1 | head -3)"
check "... and Prometheus, with its token, scrapes them" '^1$' "$(prom 'up{job="local-model-epp"}')"

echo "=== The LLM gateway is still the only way in (P5-07)"
PROXY_IP=$(kubectl get svc -n $NS inference-gateway -o jsonpath='{.spec.clusterIP}')
POD_IP=$(kubectl get pod -n $NS -l app=local-model -o jsonpath='{.items[0].status.podIP}')
check "a pod in the agent's namespace can't connect to the proxy" 'refused' "$(probe agent $PROXY_IP 8080)"
check "... nor one in a namespace with no network policy (default)" 'refused' "$(probe default $PROXY_IP 8080)"
check "... nor another pod in $NS, to the proxy" 'refused' "$(probe $NS $PROXY_IP 8080)"
check "... or to vLLM itself" 'refused' "$(probe $NS $POD_IP 8000)"
check "a hand-made pod can't join the pool by wearing its label (app=local-model)" 'refused: .*for pods its Deployments make' \
  "$(run_pod member-$T $NS 'sleep 1' '{"app": "local-model"}')"
check "... nor pass for the proxy by wearing its label" 'refused: .*for pods its Deployments make' \
  "$(run_pod proxy-$T $NS 'sleep 1' '{"gateway.networking.k8s.io/gateway-name": "inference-gateway"}')"
pod relabel-$T $NS 'sleep 60' | kubectl create -f - >/dev/null
check "... nor a running pod relabelled into it" "can't be added to or changed on a running pod" \
  "$(kubectl label pod -n $NS relabel-$T app=local-model 2>&1)"
kubectl delete pod -n $NS relabel-$T --wait=false >/dev/null

echo "=== Autoscaling on queue depth (P5-05)"
check "KEDA scales vLLM from 1 to 2 on the pool's requests in flight, 4 per replica" '^True 1 2 4 .*llm_d_epp_average_queue_size' \
  "$(kubectl get scaledobject -n $NS local-model -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.spec.minReplicaCount} {.spec.maxReplicaCount} {.spec.triggers[0].metadata.threshold} {.spec.triggers[0].metadata.query}')"
# Start from one: an earlier run's second replica goes after two quiet minutes.
for _ in $(seq 1 60); do [ "$(replicas)" = "1 1" ] && break; sleep 5; done
check "idle: one replica" '^1 1$' "$(replicas)"
# The load: 6 at a time, one more than vLLM's batch. The agent's token is
# short-lived: refreshed every 30s.
(
  end=$((SECONDS + 900))
  while [ $SECONDS -lt $end ] && [ ! -e $TMP/stop ]; do token; sleep 30; done
) & LOAD=$!
for i in $(seq 1 6); do
  ( while [ ! -e $TMP/stop ]; do
      c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat $TMP/tok)" -H 'content-type: application/json' \
        --max-time 180 --data "$(req 'Write a long story about a lighthouse keeper.' 256)" localhost:$GWPORT/v1/messages)
      echo "$(date +%s) $c" >> $TMP/codes
      sleep 0.5
    done ) &
  LOAD="$LOAD $!"
done
t0=$SECONDS; want=
for _ in $(seq 1 24); do [ "$(kubectl get hpa -n $NS keda-hpa-local-model -o jsonpath='{.status.desiredReplicas}')" = 2 ] && { want=$((SECONDS - t0)); asked=$(date +%s); break; }; sleep 5; done
check "under load, KEDA asks for a second replica (within 2 minutes)" '^[0-9]+s$' "${want:+${want}s}"
t0=$SECONDS; up=
for _ in $(seq 1 96); do [ "$(replicas)" = "2 2" ] && { up=$((SECONDS - t0)); ready=$(date +%s); break; }; sleep 5; done
check "... which is ready on a second GPU slice (within 8 minutes)" '^[0-9]+s$' "${up:+${up}s}"
check "... first time, no restarts" '^0 0$' \
  "$(kubectl get pods -n $NS -l app=local-model -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount} {end}' | sed 's/ $//')"
NEW=$(kubectl get pods -n $NS -l app=local-model --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
before=$(picked "$NEW")
for _ in $(seq 1 18); do [ "$(picked "$NEW")" != "$before" ] && break; sleep 5; done
check "... and the endpoint picker sends it requests" '^[1-9]' \
  "$(python3 -c 'import sys; print(int(float(sys.argv[2]) - float(sys.argv[1])))' "$before" "$(picked "$NEW")")"
touch $TMP/stop; wait $LOAD 2>/dev/null || true; LOAD=
# While the second replica loads, both share the GPU, and the one serving
# slows to about a third: a request can then outlast the LLM gateway's 60s
# upstream timeout (503). That's allowed from the ask until a minute after
# the new replica is ready (README, finding 21); an error any other time,
# or of another kind, is not.
read -r answered window outside <<<"$(awk -v a="${asked:-0}" -v r="${ready:-0}" '
  $2 == 200 { n++ } $2 == 503 && $1 >= a && $1 <= r + 60 { w++ } $2 != 200 && $2 != 429 && !($2 == 503 && $1 >= a && $1 <= r + 60) { o++ }
  END { print n+0, w+0, o+0 }' $TMP/codes)"
check "requests under load answered (200), or held to the gateway's rate limit (429), or timed out only while the second replica started" \
  '^answered=[1-9][0-9]* errors=0$' "answered=$answered errors=$outside"
echo "      ($(awk '{print $2}' $TMP/codes | sort | uniq -c | awk '{printf "%s x %s, ", $1, $2}' | sed 's/, $//'); $window timed out during the start; scale-up asked after ${want:-?}s, ready after ${up:-?}s)"
t0=$SECONDS; down=
for _ in $(seq 1 72); do [ "$(replicas)" = "1 1" ] && { down=$((SECONDS - t0)); break; }; sleep 5; done
check "with the load gone, back to one replica (within 6 minutes)" '^[0-9]+s$' "${down:+${down}s}"

echo
[ $FAILED = 0 ] && echo "ALL PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
