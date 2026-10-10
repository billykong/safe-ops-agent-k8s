"""Calls the gateways from inside the agent's pod, as the agent's code
would if an attacker controlled it: its own identity tokens, its own
network path. The red-team (scripts/red-team.sh) runs it with
`kubectl exec -i -n agent deploy/agent-worker -- python - MODE ARGS < this`.

  mcp SERVER TOOL JSON-ARGS   one tools/call through the MCP gateway
  llm JSON-BODY               one POST /v1/messages through the LLM gateway

Prints "<HTTP code> <response body>". Standard library only."""
import json
import os
import sys
import urllib.error
import urllib.request

MCP = os.environ.get("MCP_GATEWAY_URL", "http://mcp-gateway.gateways.svc.cluster.local:8080/mcp")
LLM = os.environ.get("LLM_GATEWAY_URL", "http://llm-gateway.gateways.svc.cluster.local:8080")
TOKENS = "/var/run/secrets/safe-ops.io"


def post(url, token_dir, body, headers=()):
    with open(f"{TOKENS}/{token_dir}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json", **dict(headers)})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


mode = sys.argv[1]
if mode == "mcp":
    server, tool, args = sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
    code, body = post(f"{MCP}/{server}", "mcp-gateway",
                      {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}},
                      [("Accept", "application/json, text/event-stream"), ("MCP-Protocol-Version", "2025-06-18")])
elif mode == "llm":
    code, body = post(f"{LLM}/v1/messages", "llm-gateway", json.loads(sys.argv[2]), [("anthropic-version", "2023-06-01")])
else:
    sys.exit(f"unknown mode {mode}")
print(code, body[:2000])
