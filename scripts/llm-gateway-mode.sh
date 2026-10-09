#!/usr/bin/env bash
# Point the LLM gateway at the mock provider (default, free, used by the
# tests) or at the real Anthropic API.
#
#   llm-gateway-mode.sh status
#   llm-gateway-mode.sh mock
#   llm-gateway-mode.sh live
#
# live needs your API key in Secret gateways/anthropic-api-key, created by
# you so the key never passes through this repo or a chat transcript:
#
#   read -rs KEY && printf %s "$KEY" | kubectl --context kind-safe-ops \
#     create secret generic anthropic-api-key -n gateways --from-file=api-key=/dev/stdin; unset KEY
#
# Only the gateway pod mounts it; agents have no read access to Secrets in
# the gateways namespace.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
mode() {
  kubectl get deploy -n gateways llm-gateway -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="UPSTREAM_URL")]}{.value}{end} {range .spec.template.spec.volumes[?(@.name=="provider-key")]}{.secret.secretName}{end}'
}
set_mode() { # URL SECRET
  local i
  i=$(kubectl get deploy -n gateways llm-gateway -o json | python3 -c '
import json, sys
c = json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0]
print([e["name"] for e in c["env"]].index("UPSTREAM_URL"))')
  kubectl patch deploy -n gateways llm-gateway --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/$i/value\",\"value\":\"$1\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/$(kubectl get deploy -n gateways llm-gateway -o json | python3 -c '
import json, sys
print([v["name"] for v in json.load(sys.stdin)["spec"]["template"]["spec"]["volumes"]].index("provider-key"))')/secret/secretName\",\"value\":\"$2\"}]" >/dev/null
  kubectl rollout status -n gateways deploy/llm-gateway --timeout=120s >/dev/null
}
case ${1:-} in
status) echo "upstream, key secret: $(mode)" ;;
mock) set_mode http://mock-model.gateways.svc.cluster.local:8080 mock-provider-key; echo "mode: mock ($(mode))" ;;
live)
  kubectl get secret -n gateways anthropic-api-key >/dev/null 2>&1 || {
    echo "Secret gateways/anthropic-api-key is missing. Create it yourself (see the top of $0), then run this again." >&2; exit 1; }
  set_mode https://api.anthropic.com anthropic-api-key; echo "mode: live ($(mode))" ;;
*) echo "usage: $0 status | mock | live" >&2; exit 2 ;;
esac
