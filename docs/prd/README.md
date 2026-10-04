# Product requirements: safe-ops-agent-k8s

This folder is the product requirements document (PRD) for the whole project: what we're building, why, the requirements each part must meet, and how we'll know it works.

## Documents

| Document | Contents |
| --- | --- |
| [01-overview.md](01-overview.md) | Problem, goals and non-goals, audience, design principles, success measures |
| [02-architecture.md](02-architecture.md) | Components, trust boundaries, data flows, environments |
| [03-security.md](03-security.md) | Threat model (OWASP Agentic Top 10), cross-cutting security requirements, governance artefacts, residual risks, publishing rules |
| [04-roadmap.md](04-roadmap.md) | Sequencing, dependencies, deliverables, open questions |
| [projects/p1-sandboxed-code-exec.md](projects/p1-sandboxed-code-exec.md) | P1: sandboxed code execution |
| [projects/p2-approval-gate.md](projects/p2-approval-gate.md) | P2: Kubernetes-native human approval gate |
| [projects/p3-tool-identity-policy.md](projects/p3-tool-identity-policy.md) | P3: tool access, identity, policy and prompt-injection defence |
| [projects/p4-observability-evals.md](projects/p4-observability-evals.md) | P4: observability and evals |
| [projects/p5-local-inference.md](projects/p5-local-inference.md) | P5: self-hosted inference on the local GPU |

## Status at a glance

| Project | Status |
| --- | --- |
| P1 Sandboxed code execution | Milestones 1-6 done; 7 (Kata comparison) next |
| P2 Approval gate | Not started |
| P3 Tool identity and policy | Not started |
| P4 Observability and evals | Not started |
| P5 Local inference | Not started |

## Conventions

- **Requirement IDs** take the form `<area>-<n>`, e.g. `P1-07` or `SEC-04`. IDs are stable: a dropped requirement is marked *Dropped*, never renumbered.
- **Priority:** **Must** (the project isn't done without it), **Should** (expected; omission needs a stated reason) or **Could** (nice to have).
- **Status:** *Done* (an automated test proves it, and the test is named), *Partial*, *Planned* or *Open question*.
- "Done" means demonstrated by a test in this repo. A requirement met only by configuration that nothing checks is *Partial*.
- Update this PRD in the same commit as the change that alters a requirement's status.
