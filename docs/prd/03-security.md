# 03 - Security requirements

Reference documents (read 2026-09-29):

- **OWASP Top 10 for Agentic Applications 2026** (ASI01-ASI10): the main yardstick.
- **NIST AI 100-1, AI RMF 1.0** (GOVERN, MAP, MEASURE, MANAGE) and its Playbook.
- **NIST concept note** on a Trustworthy AI in Critical Infrastructure profile (2026-04-07). It names autonomous incident-response agents with tested guardrails as a target use case.

## Threat model summary

| OWASP risk | Main controls | Project |
| --- | --- | --- |
| ASI01 Agent goal hijack (prompt injection) | Impact-limiting: sandbox, gate, policy outside the model; red-team where "the gate holds even when the model complies"; scope binding | P1, P2, P3 |
| ASI02 Tool misuse | Typed actions; policy engine as semantic gate; DNS-aware egress; tool budgets | P2, P3 |
| ASI03 Identity and privilege abuse | Per-agent identity; brokered secrets; no self-approval; agent can't touch guardrails; approval bound to hash (TOCTOU) | P1, P2, P3 |
| ASI04 Supply chain | Signed, digest-pinned images; SBOM and AI-BOM; pinned MCP servers and tool descriptors; no dynamic tool discovery | Cross-cutting |
| ASI05 Unexpected code execution | Separate sandbox pod; gVisor (Kata on bare metal); no pickle weights; no `--trust-remote-code` | P1, P5 |
| ASI06 Memory and context poisoning | Agent-written runbooks and memory land as reviewed PRs; sandbox and scratch memory wiped per task | P1, P2 |
| ASI07 Insecure inter-agent communication | Mutual auth between components; only the evaluator's identity writes verdicts (done, P4 M3) | P3, P4 |
| ASI08 Cascading failures | Change budget; circuit breaker; blast-radius caps; replay evals | P2, P4 |
| ASI09 Human-agent trust exploitation | Deterministic approval packet; oversight metrics; seeded known-bad proposals | P2, P4 |
| ASI10 Rogue agents | Kill switch with credential revocation; tamper-evident audit | P2, P4 |

## Cross-cutting requirements

### Isolation and least privilege

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| SEC-01 | The agent loop and the code sandbox run in **separate pods**. The sandbox has no credentials, no GPU, and no route to the agent, gateways, workflow engine or API server. | Must | **Done**: `make verify`, `make test-executor`; no route to the workflow engine: `make test-durable` |
| SEC-02 | DNS is treated as an exfiltration channel. The sandbox has no egress by default. Where egress is needed, only allowlisted names can be *resolved* (Cilium L7 DNS), ICMP is blocked, and allowlists are minimal. | Must | **Done**: no egress, DNS exfiltration and ICMP blocked (`make attack-demos`); DNS-scoped egress with exact names for tasks that need it (`make test-egress`). Domain fronting remains: see residual risks |
| SEC-03 | The agent never holds the model API key or tool secrets. Gateways hold them and authenticate the agent by workload identity. | Must | **Done**: the model key (`make test-llm-gateway`) and tool secrets (`make test-mcp`) are held by the gateways, mounted nowhere else the agent can reach; agents authenticate by workload identity |
| SEC-04 | The agent cannot approve its own change: approval is in the status subresource; the agent has no `update` on `changerequests/status`; the approver is recorded from the authenticated request identity; approval needs an authenticated human. | Must | **Done**: `make test-approval` (RBAC, plus admission policies that stamp the authenticated approver and require a human in `safe-ops:approvers`) |
| SEC-05 | Each approval is bound to exactly what was approved: a content hash of an immutable spec (CEL `self == oldSelf`), an expiry, and a live-state re-check before apply. | Must | **Done**: `make test-approval` (review hash over spec, pre-state, plan and rollback; immutable spec; expiry; live-state re-check) |
| SEC-06 | The agent cannot touch its own guardrails. Its RBAC excludes: admission webhooks and policy objects; the kill switch; CRDs and RBAC objects (no `escalate`, `bind`, `impersonate`); `secrets`, `pods/exec`, `serviceaccounts/token`, `nodes/proxy`; creating pods. | Must | **Done**: excluded and tested for the P1 and P2 agent identity (`make test-agent`, `make test-approval`, `make test-agent-guard`, `make test-kill-switch`), with an admission backstop on its writes. Admission can't protect admission configuration itself (GAP-02), so the RBAC exclusions are load-bearing |
| SEC-07 | Content-level admission for agent identities: RBAC grants verbs; admission policy constrains content (approved references only, no scope-widening fields). | Must | **Done** for SandboxClaims (`make test-agent`), ChangeRequest approvals (`make test-approval`), and all other agent writes (default-deny guard, `make test-agent-guard`) |
| SEC-08 | The write-capable executor is small and deterministic: no LLM, no free-text parsing; it applies only typed, approved, hash-matched artefacts with namespace-scoped credentials (never cluster-admin). | Must | **Done**: `make test-approval` (typed actions, no LLM, hash-matched approvals, `get`/`patch` on Deployments in `workloads` only) |

### Fail-safe operation

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| SEC-10 | Guardrail webhooks fail closed (`failurePolicy: Fail`) for the agent's identity, scoped with `matchConditions` so an outage blocks the agent, not the cluster. | Must | **Partial**: set on the claim policy (built-in VAP, no webhook to fail); webhook outage test planned (P2) |
| SEC-11 | The kill switch flips a flag checked by a fail-closed webhook, **and** revokes the agent's credentials, cancels in-flight workflows, and scales the agent to zero. It is tested as part of the evals. | Must | **Done** in P2 as a ValidatingAdmissionPolicy (no webhook to fail) plus `scripts/kill-switch.sh`, which also terminates in-flight Temporal workflows: `make test-kill-switch`, `make test-durable`. Joins the eval suite in P4 |
| SEC-12 | If the model API is down, the system degrades to "escalate everything", never to "act without the model's checks". | Should | **Done**: `make test-llm-gateway` (model unavailable, refused, out of budget or invalid output: the agent escalates and proposes nothing) |

### Human oversight

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| SEC-20 | The approval view leads with a deterministic diff, blast radius and policy findings. The model's rationale is secondary and labelled as model-generated. | Must | Planned (P2) |
| SEC-21 | Oversight is measured: approval rate, time to approve, override/reject counts, and catch rate on seeded known-bad proposals. | Should | **Partial**: approval rate, time to decide, rejections and approvals of flagged requests per approver (`approvalctl stats`, controller metrics; `make test-review`). Seeded known-bad proposals in P4 |
| SEC-22 | Agent-written runbooks, memory and summaries are untrusted until merged through human-reviewed PRs with provenance. | Should | Planned |

### Supply chain and platform hardening

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| SEC-30 | Images are digest-pinned (no `:latest`), signed with cosign, and verified at admission (Kyverno `verifyImages`). | Should | **Gap**: images are local `:dev` tags and `python:3.13-slim` by tag |
| SEC-31 | SBOM (Syft) and an AI-BOM listing each model, prompt, tool and MCP server with version and hash. | Should | Planned |
| SEC-32 | MCP servers pinned by digest; tool descriptors pinned by hash (detects "rug pull"); no dynamic tool discovery; system prompts in git. | Should | Planned (P3) |
| SEC-33 | Pod Security Admission `restricted` on agent and sandbox namespaces; read-only rootfs, non-root, dropped capabilities, seccomp `RuntimeDefault`. | Must | **Partial**: namespace labels set; pod settings checked by `make verify`; PSA rejection not tested |
| SEC-34 | `ResourceQuota`/`LimitRange` and caps on concurrent sandboxes and warm-pool size. | Should | **Partial**: per-pod limits and pids limit done; quotas planned |
| SEC-35 | Mutual authentication between components (Cilium mutual auth or a mesh). | Could | Planned (P3) |
| SEC-36 | Kubernetes API audit logging captures the agent's identity, shipped to a store the agent can't write or delete. | Should | **Done** in P4 M2: the agent's requests (with pod and token id) and changes to guard configuration, over mTLS to a hash-chained sink in namespace `audit` and a root-only node log; tampering and admission changes alert: `make test-audit`. Outage limit: GAP-07 |
| SEC-37 | Trace content capture (prompts, tool outputs) off or redacted by default. | Should | **Done** in P4 M1: no sender records content, and the collector deletes any span attribute not on its allowlist: `make test-observability` |
| SEC-38 | Each `ChangeRequest` carries a declared scope (namespaces, kinds); policy rejects actions outside it even if approved. | Should | **Done** in the controller: `make test-approval`; a policy engine joins in P3 |
| SEC-39 | GPU access never via `privileged: true`; the untrusted-code sandbox never gets a GPU; NVIDIA Container Toolkit kept patched. | Must | Done (P5 M2): the model server is a restricted pod with the GPU as a CDI device; admission keeps GPU requests to namespace `inference`; the toolkit's CDI hook is pinned. The device plugin is privileged, alone in `gpu-system`. Since M3 the GPU is time-sliced in two, with no memory isolation between the sharers; admission keeps both to `inference` |

## Governance artefacts

To be kept under `docs/` as the projects land.

| Artefact | NIST AI RMF anchor | Status |
| --- | --- | --- |
| Threat model mapping each OWASP ASI risk to a control or an accepted residual risk | MAP 4, MANAGE 1.3-1.4 | Summary above; full version planned |
| Inventory / AI-BOM of models, prompts, tools and MCP servers | GOVERN 1.6, MAP 4.2 | Planned (P3) |
| Human oversight design: what needs approval, who approves, oversight metrics | MAP 3.5, GOVERN 3.2, MEASURE 2.8 | **Done** (P2): everything needs approval except what the change budget pays for; approvers are certificate-authenticated members of `safe-ops:approvers`; packet and metrics computed by code (`make test-review`) |
| Kill-switch / deactivation and decommission runbook, tested | MANAGE 2.4, GOVERN 1.7 | **Done**: `docs/runbooks/kill-switch.md`, `make test-kill-switch` |
| Red-team plan, cadence and results log | MEASURE 2.7, MANAGE 4.1 | Planned (P1 M4, P3) |
| Incident / near-miss log and change log | MANAGE 4.3, GOVERN 4.3 | Partial: P1 findings log |
| Third-party failure plan (model API down: escalate everything) | GOVERN 6.2, MANAGE 3.1 | Planned (P3) |

## Residual risks (stated openly)

- **Prompt injection is not solved.** The design limits its impact; it doesn't prevent it.
- **gVisor is a user-space kernel, not a VM.** For hostile code, a VM boundary is stronger. Kata with Cloud Hypervisor is available as an alternative (`make kata`), including on WSL2 through nested KVM, but its defaults needed four fixes to keep the hardening (P1 README findings 24-27). Every benchmark states which runtime was used.
- **A human approver can still be misled** by a well-crafted, policy-compliant change. Deterministic diffs and oversight metrics reduce this; they don't guarantee it.
- **Single-node lab.** Etcd encryption, node hardening and network segmentation are out of scope unless shown.
- **WSL2 networking workarounds.** The eBPF-only Cilium datapath means node-originated traffic is classified as `world`; default-deny namespaces use `exec` probes. Cilium's DNS proxy and Envoy run non-transparent, so upstreams (CoreDNS, PyPI) see the node's address, not the pod's; Hubble keeps per-pod attribution. Results should be re-confirmed on bare metal.
- **A sandbox can be crashed by its own code.** Memory spread across processes, each under the per-process cap, exceeds the pod limit and kills that sandbox. It's contained (other sandboxes and the node are unaffected), but the task's sandbox is lost; the agent sees a transport error and must release and retry.
- **gVisor ignores the pod pids limit.** Fork-bomb protection inside sandboxes depends on the executor setting `RLIMIT_NPROC` on user code. Code reaching the sandbox by another path (e.g. `kubectl exec`) isn't covered.
- **Allowlisted egress is by IP, and CDNs share IPs.** The SNI pin stops reaching other sites by name, but domain fronting (allowed SNI, another site's `Host` header) still reaches any customer of the same CDN, so a sandbox with PyPI egress can send data to an attacker's Fastly service ([GAP-01](../known-gaps.md#gap-01-domain-fronting-through-the-pypi-egress-allowlist)). Mitigation planned: a package mirror or egress proxy as the only destination.
- **Admission controls can't protect themselves.** Kubernetes doesn't run admission policies or webhooks on admission configuration, so an identity with RBAC on `admissionregistration.k8s.io` (or `impersonate`, `escalate`, `bind`) can remove the guards. The agent's RBAC excludes these and the suites check it ([GAP-02](../known-gaps.md#gap-02-admission-guards-cant-protect-their-own-configuration)).
- **The executor is not a boundary.** User code in the sandbox can kill or tamper with the executor; isolation relies on gVisor, the pod spec and NetworkPolicy.

## Publishing rules

Before every push to the public repo:

```bash
grep -rnE 'privileged: *true|hostNetwork: *true|hostPID: *true|hostPath:|cluster-admin|failurePolicy: *Ignore|:latest|trust-remote-code|allowPrivilegeEscalation: *true|0\.0\.0\.0|curl .*\| *(ba)?sh' .
gitleaks detect --source . --no-banner
```

Each hit needs a fix or a comment explaining why it's safe. Hits in `docs/prd/` where the requirement text itself forbids the pattern (e.g. "never `privileged: true`") are expected. Nothing derived from employer systems is published; examples stay generic.
