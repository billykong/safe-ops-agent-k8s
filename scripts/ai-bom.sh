#!/usr/bin/env bash
# AI bill of materials (P3-23): every model, prompt, tool and MCP server the
# agents use, with versions and hashes, and the image digest each component
# is actually running. Read-only. Writes
# projects/03-tool-access/results/ai-bom.{json,md}.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
OUT=projects/03-tool-access/results
mkdir -p $OUT
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# What runs: image reference and the digest the kubelet resolved, per component.
kubectl get pods -A -o json > $TMP/pods.json
kubectl get deploy -n gateways llm-gateway -o json > $TMP/llm.json
kubectl get deploy -n agent agent-worker -o json > $TMP/worker.json
kubectl get configmap -n gateways mcp-registry -o jsonpath='{.data.registry\.json}' > $TMP/registry.json

python3 - "$TMP" "$OUT" <<'EOF'
import ast, datetime, hashlib, json, os, sys
tmp, out = sys.argv[1], sys.argv[2]
sha = lambda b: "sha256:" + hashlib.sha256(b).hexdigest()
canon = lambda v: json.dumps(v, sort_keys=True, separators=(",", ":")).encode()

# The agent's prompt, tools and model, from the code that runs (no imports
# of the agent's dependencies: evaluate only the constant assignments).
src = open("projects/02-approval-gate/durable/agent/model.py").read()
env = {"os": os}
for node in ast.parse(src).body:
    if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in ("MODEL", "MAX_TOKENS", "MAX_STEPS", "SYSTEM", "REASON", "TOOLS") for t in node.targets):
        exec(compile(ast.Module([node], []), "model.py", "exec"), env)
worker = json.load(open(f"{tmp}/worker.json"))
wenv = {e["name"]: e.get("value") for e in worker["spec"]["template"]["spec"]["containers"][0].get("env", [])}
llm = json.load(open(f"{tmp}/llm.json"))
lenv = {e["name"]: e.get("value") for e in llm["spec"]["template"]["spec"]["containers"][0].get("env", [])}
registry = json.load(open(f"{tmp}/registry.json"))

running = {}
for p in json.load(open(f"{tmp}/pods.json"))["items"]:
    app = p["metadata"].get("labels", {}).get("app")
    ns = p["metadata"]["namespace"]
    if ns not in ("agent", "gateways", "mcp-servers", "approval-system", "temporal") or not app:
        continue
    for c in p.get("status", {}).get("containerStatuses", []):
        running.setdefault(f"{ns}/{app}", {"image": c["image"], "imageID": c["imageID"]})

bom = {
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "models": {
        "agent": {"model": wenv.get("AGENT_MODEL") or env["MODEL"], "effort": "medium", "maxTokens": env["MAX_TOKENS"],
                  "maxSteps": env["MAX_STEPS"], "fallbacks": "default (server-side, beta server-side-fallback-2026-07-01)"},
        "gatewayAllows": lenv.get("MODELS", "").split(","),
        "provider": lenv.get("UPSTREAM_URL"),
    },
    "prompts": {"agent system prompt": {"source": "projects/02-approval-gate/durable/agent/model.py (SYSTEM)",
                                         "sha256": sha(env["SYSTEM"].encode())}},
    "tools": {
        "typed actions (agent)": {t["name"]: sha(canon(t)) for t in env["TOOLS"]},
        **{f"mcp:{name}": {"url": s["url"], "pins": s["tools"]} for name, s in registry["servers"].items()},
    },
    "mcpGrants": registry["identities"],
    "components": running,
}
json.dump(bom, open(f"{out}/ai-bom.json", "w"), indent=2, sort_keys=True)

md = [f"# AI bill of materials\n\nGenerated {bom['generated']} by `scripts/ai-bom.sh` from the code and the running cluster (P3-23).\n",
      "## Models\n", "| Use | Model | Settings |", "| --- | --- | --- |",
      f"| Agent (`AgentWorkflow`) | `{bom['models']['agent']['model']}` | effort {bom['models']['agent']['effort']}, max_tokens {bom['models']['agent']['maxTokens']}, up to {bom['models']['agent']['maxSteps']} model calls per decision, refusal fallbacks `default` |",
      f"| LLM gateway allows | {', '.join(f'`{m}`' for m in bom['models']['gatewayAllows'])} | upstream `{bom['models']['provider']}` |",
      "\n## Prompts\n", "| Prompt | Source | SHA-256 |", "| --- | --- | --- |"]
for n, p in bom["prompts"].items():
    md.append(f"| {n} | `{p['source']}` | `{p['sha256']}` |")
md += ["\n## Tools\n", "| Tool | Kind | Pin (SHA-256 of the descriptor) |", "| --- | --- | --- |"]
for n, h in bom["tools"]["typed actions (agent)"].items():
    md.append(f"| `{n}` | typed action, strict schema | `{h}` |")
for k, v in bom["tools"].items():
    if k.startswith("mcp:"):
        for t, pin in sorted(v["pins"].items()):
            md.append(f"| `{k[4:]}__{t}` | MCP, via the MCP gateway ({v['url']}) | `{pin}` |")
md += ["\n## Who may use which MCP tools\n"]
for ident, servers in bom["mcpGrants"].items():
    md.append(f"- `{ident}`: " + "; ".join(f"{s}: {', '.join(t)}" for s, t in servers.items()))
md += ["\n## Running components\n", "| Component | Image | Digest running |", "| --- | --- | --- |"]
for name, c in sorted(running.items()):
    md.append(f"| {name} | `{c['image']}` | `{c['imageID'].split('@')[-1]}` |")
open(f"{out}/ai-bom.md", "w").write("\n".join(md) + "\n")
print(f"wrote {out}/ai-bom.md and ai-bom.json: {len(running)} components, "
      f"{sum(len(v['pins']) for k, v in bom['tools'].items() if k.startswith('mcp:'))} MCP tools, {len(env['TOOLS'])} typed tools")
EOF
