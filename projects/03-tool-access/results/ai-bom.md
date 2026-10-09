# AI bill of materials

Generated 2026-10-09T11:20:44Z by `scripts/ai-bom.sh` from the code and the running cluster (P3-23).

## Models

| Use | Model | Settings |
| --- | --- | --- |
| Agent (`AgentWorkflow`) | `claude-opus-5-5` | effort medium, max_tokens 8000, up to 6 model calls per decision, refusal fallbacks `default` |
| LLM gateway allows | `claude-opus-5-5` | upstream `http://mock-model.gateways.svc.cluster.local:8080` |

## Prompts

| Prompt | Source | SHA-256 |
| --- | --- | --- |
| agent system prompt | `projects/02-approval-gate/durable/agent/model.py (SYSTEM)` | `sha256:0aa9802a7efbc6bbc6ec1bafbc8befbcea1911b052e3bf8f47ae9b57f341a739` |

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
| approval-system/approval-controller | `docker.io/library/approval-controller:dev` | `sha256:54a129f252431c05c64683c0e04567bae5dbf1f4ab32dda6368a838b04df34dc` |
| gateways/llm-gateway | `docker.io/library/agent-gateway:dev` | `sha256:910881a0123a95483fda32c55617cd3076f1bb1088d56b98567a4ac2ef62ca66` |
| gateways/mcp-gateway | `docker.io/library/mcp-gateway:dev` | `sha256:58974637bbcae731c4d67d1b20ea2f94354e48465a4a9b3af4e7d2c93bb4cb6f` |
| gateways/mock-model | `docker.io/library/mock-model:dev` | `sha256:084c4ceac77609511b294ef8c586e89fff9f533a979916f83a1a8037997dc0f9` |
| mcp-servers/incident-tracker | `docker.io/library/mcp-tools:dev` | `sha256:869ed53fca1bfa88f64ca8c4f138ed6fecee0432920c15ed46e85297cc7a9f56` |
| mcp-servers/incidents-mcp | `docker.io/library/mcp-tools:dev` | `sha256:869ed53fca1bfa88f64ca8c4f138ed6fecee0432920c15ed46e85297cc7a9f56` |
| temporal/temporal | `docker.io/temporalio/temporal:1.9.1` | `sha256:e1534f2d0aa0ce2d79375ce20ac15a3405fc51c3e7bd374f4ac204bc94e1252c` |
