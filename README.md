# safe-ops-agent-k8s

Reference implementation of a safe autonomous ops agent on Kubernetes: sandboxed code execution, a CRD-based human approval gate, identity and policy on tool access, and observability with evals. Runs locally on kind (WSL2).

The plan and requirements live in [docs/prd/](docs/prd/README.md). Weaknesses we have reproduced but not yet closed are tracked in [docs/known-gaps.md](docs/known-gaps.md).

## Layout

| Path | Purpose |
| --- | --- |
| `cluster/` | kind cluster config (gVisor runtime wired in) |
| `scripts/` | Host setup and verification helpers |
| `projects/01-sandboxed-code-exec/` | agent-sandbox + gVisor, hardened sandbox pods, warm-pool latency |
| `projects/03-tool-access/` | Workload identity per agent; the LLM gateway holding the model key, with per-agent budgets; MCP tools behind a gateway with pinned descriptors and argument rules; the prompt-injection red-team ([docs/red-team.md](docs/red-team.md)) |
| `projects/02-approval-gate/` | `ChangeRequest` CRD and approval controller (kubebuilder): the agent proposes, a human approves, the controller applies |
| `docs/prd/` | Product requirements: goals, architecture, security requirements, roadmap, and per-project requirements with status |

Projects 3-5 (tool identity/policy, observability/evals, local inference) get their own folders as they start.

## Quick start

```bash
sudo ./scripts/setup-host.sh   # once: Docker Engine + gVisor
make up                        # kind cluster + agent-sandbox controller
make p1                        # RuntimeClass, namespace, policy, template, warm pool
make verify                    # claim a sandbox, check gVisor + hardening
make test-pod-security         # Pod Security restricted is enforced, not just labelled
make bench                     # startup latency and gVisor vs runc overhead
make test-egress               # DNS-scoped egress for the pypi sandbox pool
make kata verify-kata          # optional: Kata Containers sandboxes (nested KVM)
./scripts/setup-go.sh          # once, no sudo: Go for the P2 controller
make p2 test-approval          # approval gate: propose, approve, apply
make test-agent-guard          # admission backstop on the agent's writes (widens its RBAC to test)
make test-budget               # change budget: N autonomous changes, then a human
make test-kill-switch          # stop the agent mid-task, check every layer, resume
make durable test-durable      # Temporal; the agent as a worker; restarts mid-approval lose nothing
make test-review               # computed review packet, Critical-finding override, oversight metrics
make p3 test-identity          # per-agent identities; gateway tokens: audience, pod binding, revocation
make test-llm-gateway          # LLM gateway (mock provider): no key in the agent, policy, budgets, degrade
make test-mcp                  # MCP gateway: brokered secrets, pinned descriptors, rug pull, agent reads MCP
make test-policy               # semantic action gate (embedded OPA): allow/escalate/deny on effect
make red-team                  # prompt injection and exfiltration: which layer stops each attack
./scripts/kill-switch.sh stop --reason TEXT   # runbook: docs/runbooks/kill-switch.md
./scripts/new-approver.sh NAME # issue an approver certificate; then approvalctl with that kubeconfig
```

## Publishing

Run the pre-publish red-flag scan in `billy-notes/kubernetes/agentic-track-security-review.md` before pushing anything public. Check employer IP terms first.
