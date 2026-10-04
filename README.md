# safe-ops-agent-k8s

Reference implementation of a safe autonomous ops agent on Kubernetes: sandboxed code execution, a CRD-based human approval gate, identity and policy on tool access, and observability with evals. Runs locally on kind (WSL2).

The plan and requirements live in [docs/prd/](docs/prd/README.md).

## Layout

| Path | Purpose |
| --- | --- |
| `cluster/` | kind cluster config (gVisor runtime wired in) |
| `scripts/` | Host setup and verification helpers |
| `projects/01-sandboxed-code-exec/` | agent-sandbox + gVisor, hardened sandbox pods, warm-pool latency |
| `docs/prd/` | Product requirements: goals, architecture, security requirements, roadmap, and per-project requirements with status |

Projects 2-5 (approval gate, tool identity/policy, observability/evals, local inference) get their own folders as they start.

## Quick start

```bash
sudo ./scripts/setup-host.sh   # once: Docker Engine + gVisor
make up                        # kind cluster + agent-sandbox controller
make p1                        # RuntimeClass, namespace, policy, template, warm pool
make verify                    # claim a sandbox, check gVisor + hardening
make bench                     # startup latency and gVisor vs runc overhead
```

## Publishing

Run the pre-publish red-flag scan in `billy-notes/kubernetes/agentic-track-security-review.md` before pushing anything public. Check employer IP terms first.
