# AI bill of materials

Generated 2026-10-12T22:41:08Z by `scripts/ai-bom.sh` from the code and the running cluster (P3-23).

## Models

| Use | Model | Settings |
| --- | --- | --- |
| Agent (`AgentWorkflow`) | `claude-opus-5-5` | effort medium, max_tokens 8000, up to 6 model calls per decision, refusal fallbacks `default` |
| LLM gateway allows | `claude-opus-5-5`, `claude-sonnet-5-5`, `qwen2.5-1.5b-instruct` | upstream `http://mock-model.gateways.svc.cluster.local:8080` |
| Self-hosted (P5), via the gateway | `qwen2.5-1.5b-instruct`: `Qwen/Qwen2.5-1.5B-Instruct-AWQ` at `3ecffa0ceb27851800f45519bab9c457a04405e1` | `http://inference-gateway.inference.svc.cluster.local:8080`; in the cluster (`inference-gateway.inference`, image under Running components) |

### `qwen2.5-1.5b-instruct` weights (lock `projects/05-local-inference/models/qwen2.5-1.5b-instruct-awq.sha256`)

| File | SHA-256 |
| --- | --- |
| `LICENSE` | `sha256:832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e` |
| `config.json` | `sha256:61cefa4671101141de551f7b46faa45dc792cba654848ee5bb8e55bebe8b6f5d` |
| `generation_config.json` | `sha256:091fc0fd8cf33ecb3ded1399ffe17cca80fefdb167ac4c241c1ca42c6bc116e5` |
| `merges.txt` | `sha256:599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3` |
| `model.safetensors` | `sha256:5b29ed6f80e422c3ae7d40dc76fd8983501bbd7489cf84a72a5c5fe20bcf2813` |
| `tokenizer.json` | `sha256:c0382117ea329cdf097041132f6d735924b697924d6f6fc3945713e96ce87539` |
| `tokenizer_config.json` | `sha256:5b5d4f65d0acd3b2d56a35b56d374a36cbc1c8fa5cf3b3febbbfabf22f359583` |
| `vocab.json` | `sha256:ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910` |

## Prompts

| Prompt | Source | SHA-256 |
| --- | --- | --- |
| agent system prompt | `projects/02-approval-gate/durable/agent/model.py (SYSTEM)` | `sha256:0aa9802a7efbc6bbc6ec1bafbc8befbcea1911b052e3bf8f47ae9b57f341a739` |

## Policies

| Policy | Source | SHA-256 |
| --- | --- | --- |
| semantic action gate | `projects/02-approval-gate/policy/gate.rego` | `sha256:af48c536adddad7280b4b27b9293c2890783a9de0a4d25a6430d2ac2e8431091` |

## Tools

| Tool | Kind | Pin (SHA-256 of the descriptor) | Arguments allowed (MCP gateway) |
| --- | --- | --- | --- |
| `propose_scale_deployment` | typed action, strict schema | `sha256:a3a58a0829707a6af9db30bf60daebf77b50fa696fc8bbcb79f9a622cb94bf99` | checked by the agent (`validate`) |
| `propose_restart_deployment` | typed action, strict schema | `sha256:de0600fca2c066aec30dce0920d0a8b96cc4ae751313e986be0d65db6c1b5807` | checked by the agent (`validate`) |
| `escalate_to_human` | typed action, strict schema | `sha256:8c88a268ac8f8082bdf25aa20a9fac75876529b87b1aa58493aedafd648f32c6` | checked by the agent (`validate`) |
| `incidents__get_incident` | MCP, via the MCP gateway (http://incidents-mcp.mcp-servers.svc.cluster.local:8080/mcp) | `sha256:3a381e2b5a6d91585000af1cbfc18aff1784edc4b64ad77c73ff679839b18256` | `incident_id`: `INC-[0-9]{4,6}`, ≤ 10 bytes |
| `incidents__list_open_incidents` | MCP, via the MCP gateway (http://incidents-mcp.mcp-servers.svc.cluster.local:8080/mcp) | `sha256:d553488ca8e729d4e1e5b1a99f50465ff1615082e9cf040b6f94f8b9530750ad` | none |
| `netdiag__resolve` | MCP, via the MCP gateway (http://netdiag-mcp.mcp-servers.svc.cluster.local:8080/mcp) | `sha256:32d32b7bfec47c199574023de05d4db1143a8b1a6c2dc02bde3f22fa67c8350d` | `hostname`: `[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.(workloads)\.svc\.cluster\.local`, ≤ 100 bytes |

## Who may use which MCP tools

- `system:serviceaccount:agent:proposer`: incidents: list_open_incidents, get_incident; netdiag: resolve

## Running components

| Component | Image | Digest running |
| --- | --- | --- |
| agent/agent-worker | `docker.io/library/approval-agent:dev` | `sha256:095626c9d3d58387c1a5bcca239e1ccba483337b92bf02e96a51f2892f4a3606` |
| agentgateway-system/agentgateway | `cr.agentgateway.dev/controller:v1.6.0` | `sha256:d84259a7e2d87f8f39bae385d4b032d823c0a4450aecb32e0e31e2258449645b` |
| approval-system/approval-controller | `docker.io/library/approval-controller:dev` | `sha256:f26572b196d321948b3645dcd7ba54db0e93a6965f9f6ea527ef1435335b2d6a` |
| gateways/llm-gateway | `docker.io/library/agent-gateway:dev` | `sha256:a5596d2f35ae997042ad5b8b03d4f99ad8222d6ff1553dceb78482c9684b61b6` |
| gateways/mcp-gateway | `docker.io/library/mcp-gateway:dev` | `sha256:6877b4e38758ab9e801effec00fa7bc9b6675b04389dabe958a8496fce58c345` |
| gateways/mock-model | `docker.io/library/mock-model:dev` | `sha256:00840adc1c42c955396518122a26a95b1ca3a12a47a6616d3f6c5cced7bbfdce` |
| gpu-system/nvidia-device-plugin | `nvcr.io/nvidia/k8s-device-plugin:v0.20.1@sha256:27c1b2553a690ca3d29889dcd61df97525d46f58272c0be8dc63c2b18f120075` | `sha256:27c1b2553a690ca3d29889dcd61df97525d46f58272c0be8dc63c2b18f120075` |
| inference/inference-gateway | `cr.agentgateway.dev/agentgateway:v1.6.0@sha256:9d3e6044ddcdc0878b1787f77bd401252b95e22684203fb5e874c4c42d2ed90c` | `sha256:9d3e6044ddcdc0878b1787f77bd401252b95e22684203fb5e874c4c42d2ed90c` |
| inference/local-model | `docker.io/library/safe-ops-vllm:0.30.0-cu129` | `sha256:a7589035f6eb74ddef7867b3059938d8c902daecbe603a98f6ecfd7b0cff6d62` |
| inference/local-model-epp | `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.11.0@sha256:39257d24552d16d8f215d3de25cc734fd44af3b282b67032db01aff900c610cf` | `sha256:39257d24552d16d8f215d3de25cc734fd44af3b282b67032db01aff900c610cf` |
| keda/keda-operator | `ghcr.io/kedacore/keda:2.21.0@sha256:81fe6547ce8d1cc29273f887b76507e9b853e5bc1f875ec23fe60061a38ed809` | `sha256:81fe6547ce8d1cc29273f887b76507e9b853e5bc1f875ec23fe60061a38ed809` |
| keda/keda-operator-metrics-apiserver | `ghcr.io/kedacore/keda-metrics-apiserver:2.21.0@sha256:255375037fe592732eeb554743aae360c2da88cf0b9b1258d0a987ef885f0881` | `sha256:255375037fe592732eeb554743aae360c2da88cf0b9b1258d0a987ef885f0881` |
| mcp-servers/incident-tracker | `docker.io/library/mcp-tools:dev` | `sha256:274501726b1541ac991891b0f4178cc355a4a895d5013dbf4d40762b87b7fb4b` |
| mcp-servers/incidents-mcp | `docker.io/library/mcp-tools:dev` | `sha256:274501726b1541ac991891b0f4178cc355a4a895d5013dbf4d40762b87b7fb4b` |
| mcp-servers/netdiag-mcp | `docker.io/library/mcp-tools:dev` | `sha256:274501726b1541ac991891b0f4178cc355a4a895d5013dbf4d40762b87b7fb4b` |
| temporal/temporal | `docker.io/temporalio/temporal:1.9.1` | `sha256:e1534f2d0aa0ce2d79375ce20ac15a3405fc51c3e7bd374f4ac204bc94e1252c` |
