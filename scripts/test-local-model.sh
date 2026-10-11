#!/usr/bin/env bash
# P5 milestone 1: a local model, served outside the cluster (P5-01, P5-02,
# P5-07..P5-10). Checks:
#  - the weights: the served copy matches the lock; a changed byte, an
#    extra file or a config asking for remote code is refused (P5-08);
#  - the server: on the GPU, with its memory and context bounded; not
#    privileged, no capabilities, read-only; no remote code; on a network
#    only this cluster's node joins, with no route out and no published
#    port; it refuses a request without its key (P5-02, P5-09);
#  - through the LLM gateway: the agent's identity gets an answer and a
#    forced tool call from the local model; tokens counted, cost zero; the
#    provider key never goes to the local server, nor the local key to the
#    provider (P5-07);
#  - negative controls: pods outside the gateway can't connect, in a
#    namespace with no policy, in the agent's namespace, or wearing the
#    gateway's labels (P5-07);
#  - the eval judge on the local model: every scenario judged (P5-10);
#  - with the server down, the local model's requests fail closed (503
#    model_unavailable) and the hosted models are unaffected; it comes back.
# Needs `make p2 p3 durable p4 evals p5`, the LLM gateway in mock mode.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
T=$(date +%s)
IP=172.30.99.10 PORT=8000 SRV=safe-ops-model NODE=safe-ops-control-plane
MODEL=qwen2.5-1.5b-instruct
LOCK=projects/05-local-inference/models/qwen2.5-1.5b-instruct-awq.sha256
WEIGHTS=$HOME/.cache/safe-ops-models/qwen2.5-1.5b-instruct-awq
TMP=$(mktemp -d)
FAILED=0
PFS=()
pass() { echo "PASS  $1"; }
# GAP lines: a known gap, reproduced (docs/known-gaps.md), neither pass nor fail.
fail() { echo "FAIL  $1"; FAILED=1; }
check() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1: got: ${3:0:400}"; fi; }
forward() { # NAMESPACE TARGET PORT LOCAL
  kubectl port-forward -n "$1" "$2" "$4:$3" >/dev/null 2>&1 & PFS+=($!)
  for _ in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/$4) 2>/dev/null && return 0; sleep 1; done
  echo "port-forward to $2 didn't come up"; exit 1
}
msg() { # BODY -> "CODE BODY", as the agent's identity, through the gateway
  curl -s -o $TMP/out -w '%{http_code}' -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
    --max-time 120 --data "$1" localhost:28081/v1/messages; echo " $(cat $TMP/out)"
}
req() { # MODEL USER-TEXT [EXTRA-JSON]
  python3 -c 'import json, sys; b = {"model": sys.argv[1], "max_tokens": 200, "messages": [{"role": "user", "content": sys.argv[2]}]}; b.update(json.loads(sys.argv[3])); print(json.dumps(b))' "$1" "$2" "${3:-{\}}"
}
metric() { # NAME{LABELS} -> value (0 if absent)
  curl -s localhost:29090/metrics | python3 -c '
import re, sys
want = sys.argv[1]; name, _, labels = want.partition("{"); labels = labels.rstrip("}")
need = dict(kv.split("=", 1) for kv in labels.split(",") if kv)
total = 0.0
for line in sys.stdin:
    m = re.match(r"(\w+)\{(.*)\} (\S+)$", line.strip())
    if m and m.group(1) == name:
        have = dict(re.findall(r"(\w+)=\"([^\"]*)\"", m.group(2)))
        if all(have.get(k) == v.strip("\"") for k, v in need.items()):
            total += float(m.group(3))
print(int(total) if total == int(total) else total)' "$1"
}
probe() { # NAMESPACE NAME [LABELS-JSON]: can a pod there connect to the server? "connected" or the error
  kubectl run "$2" -n "$1" --rm -i --restart=Never --image=python:3.13-slim --image-pull-policy=IfNotPresent \
    --overrides="{\"metadata\":{\"labels\":${3:-{\}}},\"spec\":{\"automountServiceAccountToken\":false,\"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":65534,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},\"containers\":[{\"name\":\"$2\",\"image\":\"python:3.13-slim\",\"imagePullPolicy\":\"IfNotPresent\",\"command\":[\"python\",\"-c\",\"import socket\\ntry:\\n socket.create_connection(('$IP',$PORT),timeout=5); print('connected')\\nexcept Exception as e: print('refused:', type(e).__name__)\"],\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}}}]}}" \
    2>/dev/null | grep -E "connected|refused" || echo "no result"
}
cleanup() {
  for p in "${PFS[@]}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP" "${WT:-/nonexistent}"
}
trap cleanup EXIT
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status"; exit 1; }
./scripts/llm-gateway-mode.sh mock >/dev/null
[[ "$(scripts/model-server.sh status)" == *", ready"* ]] || { echo "the model server isn't ready: scripts/model-server.sh up"; exit 1; }

echo "=== The weights (P5-08)"
out=$(scripts/model-server.sh verify 2>&1) && pass "the served copy matches the lock" || fail "served copy: $out"
check "the lock pins one revision" '^# revision: [0-9a-f]{40}$' "$(grep '^# revision:' $LOCK)"
files=$(grep -v '^#' $LOCK | awk '{print $2}')
check "the weights are safetensors only (no pickle: .bin, .pt, .pth)" '^model\.safetensors$' "$(grep -E '\.(safetensors|bin|pt|pth|ckpt)$' <<<"$files")"
# A copy to tamper with, next to the weights (same file system): the small
# files copied, the 1.6 GB weights hard-linked, never written or chmod-ed.
WT=$(mktemp -d "$(dirname "$WEIGHTS")/.test-XXXXXX")
copy() {
  rm -rf "$WT/w"; mkdir "$WT/w"
  for f in "$WEIGHTS"/*; do
    if [ "${f##*/}" = model.safetensors ]; then ln "$f" "$WT/w/"; else cp "$f" "$WT/w/"; chmod u+w "$WT/w/${f##*/}"; fi
  done
}
copy; printf 'x' >> "$WT/w/tokenizer_config.json"
out=$(scripts/model-server.sh verify "$WT/w" 2>&1) && fail "a changed byte passed" || check "a copy with one changed byte is refused, naming the file" 'tokenizer_config.json: FAILED' "$out"
copy; echo 'import os' > "$WT/w/modeling_qwen2.py"
out=$(scripts/model-server.sh verify "$WT/w" 2>&1) && fail "an extra file passed" || check "a copy with an extra file (code) is refused" 'other files.*|modeling_qwen2.py' "$out"
copy; python3 - "$WT/w/config.json" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1])); c["auto_map"] = {"AutoModelForCausalLM": "modeling_qwen2.Qwen2ForCausalLM"}
json.dump(c, open(sys.argv[1], "w"), indent=2)
EOF
sed "s|^[0-9a-f]*  config.json$|$(sha256sum "$WT/w/config.json" | cut -d' ' -f1)  config.json|" $LOCK > "$TMP/lock.sha256"
out=$(MODEL_LOCK=$TMP/lock.sha256 scripts/model-server.sh verify "$WT/w" 2>&1) && fail "auto_map passed" \
  || check "a config asking for remote code is refused, even with its hash in the lock" 'remote code' "$out"

echo "=== The server, outside the cluster (P5-01, P5-02, P5-09)"
I=$(docker inspect $SRV)
field() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read())[0]; print(eval(sys.argv[1]))' "$1" <<<"$I"; }
args=$(field '" ".join(d["Args"])')
check "vLLM serves $MODEL from the verified copy, read-only" "^ok /models/$MODEL:ro$" \
  "ok $(field '[m["Destination"]+(":ro" if not m["RW"] else ":rw") for m in d["Mounts"]][0]')"
check "... memory and context bounded" '--gpu-memory-utilization 0\.[0-9]+ --max-model-len [0-9]+' "$args"
check "... safetensors only" '--load-format safetensors' "$args"
grep -q -- 'trust-remote-code' <<<"$args" && fail "the server trusts remote code" || pass "... no remote code (no --trust-remote-code)"
check "... offline (HF_HUB_OFFLINE)" 'HF_HUB_OFFLINE=1' "$(field '" ".join(d["Config"]["Env"])')"
check "on the GPU" 'cuda NVIDIA GeForce RTX 3050' \
  "$(docker exec $SRV python3 -c 'import torch; print(torch.cuda.is_available() and "cuda", torch.cuda.get_device_name(0))' 2>&1)"
check "... using its memory (MiB used of the 4 GB)" '^[1-9][0-9]{3}$' "$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' ')"
check "not privileged, all capabilities dropped, no new privileges" '^False \[.ALL.\] \[.no-new-privileges.\]$' \
  "$(field 'd["HostConfig"]["Privileged"], d["HostConfig"]["CapDrop"], d["HostConfig"]["SecurityOpt"]' | tr -d '(),')"
check "... a read-only root file system, a non-root user, bounded memory" '^True 1000:1000 [1-9]' \
  "$(field 'd["HostConfig"]["ReadonlyRootfs"], d["Config"]["User"], d["HostConfig"]["Memory"]' | tr -d '(),'"'")"
check "... the only device is the GPU's (/dev/dxg), or the toolkit's --gpus" '^(/dev/dxg|gpus)$' \
  "$(field '" ".join([x["PathOnHost"] for x in d["HostConfig"]["Devices"] or []] + (["gpus"] if d["HostConfig"]["DeviceRequests"] else []))')"
check "no published port" '^\{\}$' "$(field 'd["HostConfig"]["PortBindings"] or {}')"
check "its network is internal, shared with this cluster's node only" "^True \['$NODE', '$SRV'\]$" \
  "$(docker network inspect safe-ops-models | python3 -c 'import json,sys; n=json.load(sys.stdin)[0]; print(n["Internal"], sorted(c["Name"] for c in n["Containers"].values()))')"
check "the server can't reach the internet" 'refused' \
  "$(docker exec $SRV python3 -c "import socket
try: socket.create_connection(('1.1.1.1', 443), timeout=5); print('connected')
except Exception as e: print('refused:', type(e).__name__)" 2>&1)"
check "a container on network kind (where the ml cluster is) can't reach it" 'refused' \
  "$(docker run --rm --network kind python:3.13-slim python -c "import socket
try: socket.create_connection(('$IP', $PORT), timeout=5); print('connected')
except Exception as e: print('refused:', type(e).__name__)" 2>&1)"
check "it refuses a request without its key (401)" '^401$' \
  "$(docker exec $NODE curl -s -o /dev/null -w '%{http_code}' -m 10 -H 'content-type: application/json' \
     -d "{\"model\":\"$MODEL\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" http://$IP:$PORT/v1/messages)"

echo "=== Through the LLM gateway (P5-07)"
W=$(kubectl get pod -n agent -l app=agent-worker -o jsonpath='{.items[0].metadata.name}')
TOK=$(kubectl exec -n agent "$W" -- cat /var/run/secrets/safe-ops.io/llm-gateway/token)
forward gateways svc/llm-gateway 8080 28081
forward gateways svc/llm-gateway 9090 29090
forward gateways svc/mock-model 8080 28082
ID=system:serviceaccount:agent:proposer
ok0=$(metric "safeops_llm_requests_total{identity=$ID,model=$MODEL,outcome=ok}")
out0=$(metric "safeops_llm_tokens_total{identity=$ID,model=$MODEL,type=output}")
mock0=$(curl -s localhost:28082/debug/last | python3 -c 'import json,sys; print(json.load(sys.stdin)["requests"])')
out=$(msg "$(req $MODEL 'Answer with one word: what is the capital of France?')")
check "the agent's identity gets an answer from the local model (200)" "^200 .*\"type\": ?\"text\".*\"model\": ?\"$MODEL\"" "$out"
python3 -c 'import json,sys; t="".join(b.get("text","") for b in json.loads(sys.argv[1])["content"]); print("answer:", t.strip()[:80])' "${out#* }" || true
JUDGE='{"tools": [{"name": "record_verdict", "description": "Record the grade.", "input_schema": {"type": "object", "additionalProperties": false, "required": ["verdict", "rationale"], "properties": {"verdict": {"type": "string", "enum": ["pass", "fail"]}, "rationale": {"type": "string"}}}}], "tool_choice": {"type": "tool", "name": "record_verdict"}}'
out=$(msg "$(req $MODEL 'The task: restart web. The outcome: RestartDeployment. Grade it.' "$JUDGE")")
check "... and a forced tool call with a valid verdict, as the eval judge asks for" '"type": ?"tool_use".*"name": ?"record_verdict".*"verdict": ?"(pass|fail)"' "$out"
sleep 1
check "the gateway counted the requests" "^$((ok0 + 2))$" "$(metric "safeops_llm_requests_total{identity=$ID,model=$MODEL,outcome=ok}")"
o=$(metric "safeops_llm_tokens_total{identity=$ID,model=$MODEL,type=output}")
[ "${o%.*}" -gt "${out0%.*}" ] && pass "... and the tokens the server reported ($((${o%.*} - ${out0%.*})) output)" || fail "tokens: $out0 -> $o"
check "... at zero cost" '^0$' "$(metric "safeops_llm_cost_usd_total{identity=$ID,model=$MODEL}")"
mock1=$(curl -s localhost:28082/debug/last | python3 -c 'import json,sys; print(json.load(sys.stdin)["requests"])')
[ "$mock1" = "$mock0" ] && pass "the hosted provider (the mock) never saw them" || fail "the provider got local-model requests: $mock0 -> $mock1"
out=$(msg "$(req claude-opus-5-5 'Say hello. [mock:text]')")
check "a hosted model's request still goes to the provider" '^200 ' "$out"
last=$(curl -s localhost:28082/debug/last)
LKEY=$(cat "$HOME/.config/safe-ops/local-model-key")
grep -q "$LKEY" <<<"$last" && fail "the local model's key reached the provider" || pass "... without the local model's key"
check "... with the provider key as x-api-key, and no Authorization header" '^ok$' \
  "$(python3 -c 'import json,sys; h=json.loads(sys.argv[1])["last"]["headers"]; print("ok" if "x-api-key" in h and "authorization" not in h else h)' "$last")"
GWP=$(kubectl get pod -n gateways -l app=llm-gateway -o jsonpath='{.items[0].metadata.name}')
check "only the gateway pod mounts the local model's key" '^llm-gateway-' \
  "$(kubectl get pods -A -o json | python3 -c 'import json,sys; print(" ".join(p["metadata"]["name"] for p in json.load(sys.stdin)["items"] if any((v.get("secret") or {}).get("secretName") == "local-model-key" for v in p["spec"].get("volumes", []))))')"
# The provider key never reaching the local server is the gateway's unit
# test (internal/upstream TestSetHeaders): vLLM doesn't log headers.
check "unit: the gateway sends each upstream only its own key" '^ok' \
  "$(cd projects/03-tool-access/gateway && PATH=$HOME/.local/go/bin:$PATH go test ./internal/upstream/ -count=1 2>&1 | tail -1)"

echo "=== Negative controls: only the gateway reaches the server (P5-07)"
check "a pod in a namespace with no network policy (default) can't connect" 'refused' "$(probe default lm-probe-$T)"
check "a pod in the agent's namespace can't" 'refused' "$(probe agent lm-probe-$T)"
check "a pod outside gateways wearing the gateway's labels can't" 'refused' "$(probe default lm-probe-$T '{"app":"llm-gateway"}')"
check "the policy that stops them is a clusterwide deny" '^local-model-only-from-gateways$' \
  "$(kubectl get ccnp -o jsonpath='{.items[?(@.spec.egressDeny)].metadata.name}')"
# The node's own network namespace (and so any host-network pod) is outside
# Cilium's pod policy: it reaches the server, and only the key stops it.
if [ "$(docker exec $NODE curl -s -o /dev/null -w '%{http_code}' -m 5 http://$IP:$PORT/health)" = 200 ]; then
  echo "GAP   GAP-09: the node and host-network pods can connect; the server's key is all that stops them"
else
  pass "the node can't connect either"
fi

echo "=== The eval judge on the local model (P5-10)"
RUN=lj-$T
ev0=$(metric "safeops_llm_requests_total{identity=system:serviceaccount:evals:evaluator,model=$MODEL,outcome=ok}")
JUDGE_MODEL=$MODEL scripts/eval-run.sh $RUN > $TMP/run.log 2>&1 && pass "an eval run with JUDGE_MODEL=$MODEL completes" \
  || fail "eval run: $(tail -5 $TMP/run.log)"
ER=$(kubectl get evalrun -n evals $RUN -o json 2>/dev/null || echo '{}')
check "... the EvalRun records the local judge" "^$MODEL$" "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("spec",{}).get("judge",{}).get("model",""))' "$ER")"
judged=$(python3 -c '
import json, sys
r = json.loads(sys.argv[1]).get("spec", {}).get("scenarios", [])
v = [x["judge"]["verdict"] for x in r]
agree = sum(x["deterministic"] == (x["judge"]["verdict"] == "pass") for x in r)
lifted = sum(x["passed"] and not x["deterministic"] for x in r)
print(len(r), v.count("error"), agree, lifted)' "$ER")
read -r n errs agree lifted <<<"$judged"
[ "${n:-0}" -gt 0 ] && [ "$errs" = 0 ] && pass "... every scenario judged ($n), none an error" || fail "judged: $judged"
echo "      (the 1.5B judge agreed with the deterministic checks on $agree of $n)"
python3 -c '
import json, sys
for x in json.loads(sys.argv[1])["spec"]["scenarios"]:
    checks = "pass" if x["deterministic"] else "fail"
    if (checks == "pass") != (x["judge"]["verdict"] == "pass"):
        print("      disagrees:", x["id"] + ": checks", checks + ", judge", x["judge"]["verdict"] + ":", x["judge"]["rationale"][:110])' "$ER" || true
[ "${lifted:-1}" = 0 ] && pass "... a judge's pass never lifts a scenario its checks failed" || fail "scenarios passed against their checks: $lifted"
sleep 1
ev1=$(metric "safeops_llm_requests_total{identity=system:serviceaccount:evals:evaluator,model=$MODEL,outcome=ok}")
[ "$((ev1 - ev0))" -ge "${n:-1}" ] && pass "... through the gateway, as the evaluator ($((ev1 - ev0)) requests)" || fail "evaluator requests: $ev0 -> $ev1"

echo "=== With the server down"
scripts/model-server.sh down >/dev/null
out=$(msg "$(req $MODEL 'hello')")
check "the local model's requests fail closed: 503 model_unavailable" '^503 .*model_unavailable' "$out"
check "the hosted models are unaffected" '^200 ' "$(msg "$(req claude-opus-5-5 'Say hello. [mock:text]')")"
scripts/model-server.sh up > $TMP/up.log 2>&1 && pass "it comes back (scripts/model-server.sh up)" || fail "up: $(tail -5 $TMP/up.log)"
check "... and answers through the gateway again" '^200 ' "$(msg "$(req $MODEL 'Say hi.')")"

echo
[ $FAILED = 0 ] && echo "ALL PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
