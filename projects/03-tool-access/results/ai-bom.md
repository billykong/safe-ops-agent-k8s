# AI bill of materials

Generated 2026-10-10T08:21:06Z by `scripts/ai-bom.sh` from the code and the running cluster (P3-23).

## Models

| Use | Model | Settings |
| --- | --- | --- |
| Agent (`AgentWorkflow`) | `claude-opus-5-5` | effort medium, max_tokens 8000, up to 6 model calls per decision, refusal fallbacks `default` |
| LLM gateway allows | `claude-opus-5-5` | upstream `http://mock-model.gateways.svc.cluster.local:8080` |

## Prompts

| Prompt | Source | SHA-256 |
| --- | --- | --- |
| agent system prompt | `projects/02-approval-gate/durable/agent/model.py (SYSTEM)` | `sha256:0aa9802a7efbc6bbc6ec1bafbc8befbcea1911b052e3bf8f47ae9b57f341a739` |

## Policies

| Policy | Source | SHA-256 |
| --- | --- | --- |
| semantic action gate | `projects/02-approval-gate/policy/gate.rego` | `sha256:af48c536adddad7280b4b27b9293c2890783a9de0a4d25a6430d2ac2e8431091` |

## Tools

| Tool | Kind | Pin (SHA-256 of the descriptor) |
| --- | --- | --- |
| `propose_scale_deployment` | typed action, strict schema | `sha256:a3a58a0829707a6af9db30bf60daebf77b50fa696fc8bbcb79f9a622cb94bf99` |
| `propose_restart_deployment` | typed action, strict schema | `sha256:de0600fca2c066aec30dce0920d0a8b96cc4ae751313e986be0d65db6c1b5807` |
| `escalate_to_human` | typed action, strict schema | `sha256:8c88a268ac8f8082bdf25aa20a9fac75876529b87b1aa58493aedafd648f32c6` |
| `incidents__get_incident` | MCP, via the MCP gateway (http://incidents-mcp.mcp-servers.svc.cluster.local:8080/mcp) | `sha256:3a381e2b5a6d91585000af1cbfc18aff1784edc4b64ad77c73ff679839b18256` |
| `incidents__list_open_incidents` | MCP, via the MCP gateway (http://incidents-mcp.mcp-servers.svc.cluster.local:8080/mcp) | `sha256:d553488ca8e729d4e1e5b1a99f50465ff1615082e9cf040b6f94f8b9530750ad` |

## Who may use which MCP tools

- `system:serviceaccount:agent:proposer`: incidents: list_open_incidents, get_incident

## Running components

| Component | Image | Digest running |
| --- | --- | --- |
| agent/agent-worker | `docker.io/library/approval-agent:dev` | `sha256:89f5aa94349ea77980ab57e5a13473434c3ce32c44c8c9e772395e3379d5897c` |
| approval-system/approval-controller | `docker.io/library/approval-controller:dev` | `sha256:1cf0bac0b4dd499ef5279209859486ab0655b7acafb7290f3d4433f869497dd0` |
| gateways/llm-gateway | `docker.io/library/agent-gateway:dev` | `sha256:821f2a1d33d6752953250d7dbd545d1980c3a5e0afae2317acadf02e86b07eec` |
| gateways/mcp-gateway | `docker.io/library/mcp-gateway:dev` | `sha256:8212afedde5b046e5cf86b00a15a057964151342380be41bb2a51f1a851673d2` |
| gateways/mock-model | `docker.io/library/mock-model:dev` | `sha256:b5bf2eab16e19a694e91b042d02ef97311fc0d467102cd8680e9ca0f4d26f283` |
| mcp-servers/incident-tracker | `docker.io/library/mcp-tools:dev` | `sha256:8d576d2af70e29b708a5919e17158500e3042cbc297c554163a51d8fb6c454b5` |
| mcp-servers/incidents-mcp | `docker.io/library/mcp-tools:dev` | `sha256:8d576d2af70e29b708a5919e17158500e3042cbc297c554163a51d8fb6c454b5` |
| temporal/temporal | `docker.io/temporalio/temporal:1.9.1` | `sha256:e1534f2d0aa0ce2d79375ce20ac15a3405fc51c3e7bd374f4ac204bc94e1252c` |
