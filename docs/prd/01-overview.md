# 01 - Overview

## Problem

AI agents are starting to operate infrastructure: investigating incidents, writing and running code, and proposing or making changes. Two things make that dangerous:

1. **Unintended effects.** An agent reads content an attacker can influence (logs, tickets, web pages, tool output). Injected instructions can make it exfiltrate data, move laterally, exhaust resources or misuse its credentials. Models can't reliably tell instructions from content, so this can't be solved inside the model.
2. **Intended but wrong changes.** Even an uncompromised agent will sometimes propose a change that is wrong. If it can apply changes directly, a wrong change reaches production at machine speed.

Most agent demos ignore both, or rely on guardrails inside the agent process, where the code they guard can disable them.

## Product

**A reference implementation of a safe autonomous operations agent on Kubernetes.** It shows, with working code and tests, how to run an agent so that:

- code it generates runs in a disposable sandbox with no credentials and no network;
- its only way to change the cluster is to propose a change that a human approves and a separate, trusted component applies;
- its tool access, identity and secrets are brokered and policy-checked outside the model;
- its behaviour, cost and safety are observable and continuously evaluated.

It runs entirely on a laptop (kind on WSL2), so anyone can reproduce it.

## Audience

| Who | What they need from it |
| --- | --- |
| Platform and SRE engineers evaluating agents for operations | A concrete architecture with the trade-offs and failure modes written down |
| Security reviewers | A threat model mapped to controls, with residual risks stated openly |
| Engineers building agent platforms | Reusable manifests, policies and test patterns |
| The author | A structured way to learn and demonstrate the design, end to end |

## Goals

1. **G1 - Contain generated code.** Untrusted code runs in a strongly isolated, disposable sandbox that can't reach credentials, the agent, the API server or the internet.
2. **G2 - Gate every change.** The agent never holds write credentials. Changes flow through an approval gate that the agent can't bypass, approve itself or disable.
3. **G3 - Broker identity and tools.** Each agent has its own workload identity. Secrets, including the model API key, are held by gateways, never by the agent. A policy engine decides allow, deny or escalate for each tool action.
4. **G4 - Measure it.** Traces, cost and safety metrics are emitted by default. A replay eval suite gates changes to the agent on regressions.
5. **G5 - Show the evidence.** Every control has an automated test, including a negative control that proves "blocked" isn't just "broken". Findings, including failures, are documented.
6. **G6 - Be reproducible and publishable.** Anyone can bring the stack up from the README. The repo passes its own pre-publish security scan.

## Non-goals

- **A production-ready product.** This is a single-node lab. Etcd encryption, node hardening, HA and multi-cluster are out of scope unless a project explicitly shows them.
- **Solving prompt injection.** The design limits the *impact* of injection; it doesn't claim to prevent it.
- **A capable agent.** The agent's reasoning quality is not the point. A simple or scripted agent is fine wherever it exercises the controls.
- **Agent framework comparisons.** Frameworks are used only where they serve a requirement (e.g. durable execution in P2).
- **Low-latency infrastructure work.** Outside this repo.

## Design principles

1. **Treat model output as untrusted. Enforce outside the model.** Every guardrail lives somewhere the agent's process and its generated code can't modify.
2. **The agent's authority is data, not credentials.** The agent emits proposals. A small, deterministic executor with no LLM holds the write credentials and applies only approved, hash-matched artefacts.
3. **Separate pods for separate trust levels.** Kubernetes controls (service account, NetworkPolicy, RuntimeClass, security context) apply per pod, so the agent and the code it runs must never share a pod.
4. **Fail closed, with a tested break-glass path.** If a guardrail is unavailable, the agent stops, not the cluster.
5. **Default deny, then allow narrowly.** For network, RBAC, admission and tool access alike.
6. **Test both directions.** Every control test pairs "the restricted thing is blocked" with "an unrestricted equivalent works".
7. **Write limitations down.** A documented residual risk is defensible; an undocumented one looks like an oversight.

## Success measures

| Measure | Target |
| --- | --- |
| Control coverage | Every **Must** requirement in [03-security.md](03-security.md) and the project files has an automated test, or a documented reason it can't |
| Reproducibility | `make up && make p1` (and later project targets) on a fresh machine reaches all-green tests without manual steps beyond the documented host setup |
| Red-team outcomes | For each attack in the red-team plan, the log names the layer that stopped it; "the gate holds even when the model complies" |
| Operational metrics (P4) | Reopen rate, escalation rate and cost per task are tracked alongside throughput. Targets are set after a baseline exists |
| Oversight health (P2/P4) | Approval rate, time to approve and catch rate on seeded known-bad proposals are measured. A near-100% approval rate with seconds-long reviews is treated as a finding |
| Publication | Reference repo public, with a blog post per major project, and a capstone architecture write-up with a YouTube video of it |
