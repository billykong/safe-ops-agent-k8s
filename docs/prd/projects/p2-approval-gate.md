# P2 - Kubernetes-native human approval gate

**Goal:** the agent never changes the cluster directly. It proposes; a human approves; a small trusted controller applies. Nothing the agent can do approves, alters or bypasses that flow. Covers goal G2.

Status: **not started**. Depends on P1.

## User stories

- As an **agent**, I can propose a change with its intent, diff, blast radius, scope and rollback, and resume my workflow when it's decided, even hours later.
- As an **approver**, I see a deterministic review packet, and my approval applies to exactly what I reviewed.
- As an **operator**, I can stop the agent completely with one action, and I can cap how many changes it makes before it must ask.
- As a **security reviewer**, I can see every self-approval and time-of-check/time-of-use path closed by a test.

## Requirements

### Proposal and apply

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P2-01 | A `ChangeRequest` CRD holds intent, the change (typed action preferred over a raw diff), blast radius, declared scope (namespaces, kinds) and a rollback procedure. | Must | Planned |
| P2-02 | The spec is immutable after creation (CEL `self == oldSelf`). | Must | Planned |
| P2-03 | A controller (kubebuilder) applies a request only when it is approved, unexpired and its hash matches. It holds namespace-scoped write credentials, never cluster-admin, and contains no LLM. | Must | Planned |
| P2-04 | Before applying, the controller re-checks live state against the recorded pre-state. On mismatch, the request goes back for re-approval. | Must | Planned |
| P2-05 | Every applied change records pre-state, the exact command or manifest, and the rollback, before it executes. | Must | Planned |
| P2-06 | Typed actions (`restart_deployment`, `scale`, `drain_node`, ...) are the default path; arbitrary commands are a rare, separately approved exception, pinned by hash. | Should | Planned |
| P2-07 | Policy rejects actions outside the declared scope, even when approved. | Should | Planned |

### Approval integrity

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P2-10 | Approval lives in the `status` subresource; the agent's identity has no `update` on `changerequests/status`. | Must | Planned |
| P2-11 | The approver is recorded from the authenticated request identity, not from a field in the object. Approval requires an authenticated human. | Must | Planned |
| P2-12 | Approval binds to a content hash of the spec and expires. | Must | Planned |
| P2-13 | An admission webhook rejects direct writes to managed resources by the agent's identity, fail-closed and scoped to that identity. | Must | Planned |
| P2-14 | The agent has no RBAC on webhooks, policies, the kill switch, CRDs or RBAC objects, and can't create pods (SEC-06). | Must | Planned |

### Bounding and stopping

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P2-20 | Change budget: N autonomous changes, then the agent must ask. | Must | Planned |
| P2-21 | Kill switch: a flag checked by a fail-closed admission webhook, plus revoking the agent's credentials, cancelling in-flight workflows and scaling the agent to zero. | Must | Planned |
| P2-22 | A tested decommission / break-glass runbook for the kill switch. | Should | Planned |

### Durable execution

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P2-30 | The agent pauses and resumes across approvals that take hours (Temporal workflow or LangGraph `interrupt`). | Must | Planned; engine is an open question |
| P2-31 | Demo: a pod restart mid-approval loses no state. | Should | Planned |

### Review experience and oversight

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P2-40 | The review packet is computed by code, not an LLM: exact diff and server-side dry run, blast radius, policy findings, budget remaining, rollback and whether it was tested. The model's rationale is secondary and labelled. | Must | Planned |
| P2-41 | Approval via a CLI first; a Slack-style webhook only with real authentication. | Must | Planned |
| P2-42 | Oversight metrics: approval rate, time to approve, edit/reject rate per approver. | Should | Planned (feeds P4) |
| P2-43 | Seeded known-bad proposals measure approver catch rate. | Could | Planned |
| P2-44 | Risk tiers: low-risk, reversible, in-budget typed actions matching a pre-approved runbook can be auto-approved **by deterministic policy**, never by an AI. | Could | Planned |

## Acceptance

- A full flow works end to end: propose, approve via CLI, apply, record, roll back.
- Tests prove each closure: agent can't approve (RBAC and identity), approval can't be reused for a changed spec (hash), stale approval is rejected (expiry), drifted live state blocks apply, direct agent writes are denied, the kill switch stops an in-flight workflow and revokes credentials.
