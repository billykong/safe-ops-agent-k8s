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
| `projects/04-observability/` | OpenTelemetry GenAI traces (one per task, no content), Prometheus and Grafana for tokens, cost and escalation rate; the API audit log, in a hash-chained store the agent can't reach; the replay eval suite with a blind judge, the CI regression gate on it, and a kill-switch drill; oversight and quality metrics from records the agent can't write |
| `projects/05-local-inference/` | A local model on the host's GPU: vLLM inside the cluster through the NVIDIA device plugin (CDI, on WSL2), behind the Gateway API Inference Extension and scaled on queue depth by KEDA, or in Docker outside it as the fallback; reached through the LLM gateway only, with hash-verified weights; used as an eval judge |
| `docs/prd/` | Product requirements: goals, architecture, security requirements, roadmap, and per-project requirements with status |

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
make p4 test-observability     # telemetry: one trace per task, tokens, cost, escalation rate
scripts/observability.sh       # Grafana, Jaeger, Prometheus on localhost
make audit test-audit          # API audit log: the agent's identity, tamper-evident sink, alerts (restarts the API server)
make evals test-evals          # replay evals: scenarios through the real agent, blind judge, verdicts only the evaluator writes
scripts/eval-run.sh            # one eval run; kubectl get evalruns -n evals
make eval-gate test-eval-gate  # regression gate: the run against the baseline in git; CI runs it on every PR
make eval-kill-switch          # kill-switch drill: stop the agent mid-work, check every layer, resume (CI, after the gate)
make test-oversight            # oversight and quality metrics, their alerts, no forged metrics, the drill
./scripts/kill-switch.sh stop --reason TEXT   # runbook: docs/runbooks/kill-switch.md
./scripts/new-approver.sh NAME # issue an approver certificate; then approvalctl with that kubeconfig
```

## Publishing

Run the pre-publish red-flag scan in `billy-notes/kubernetes/agentic-track-security-review.md` before pushing anything public. Check employer IP terms first.
