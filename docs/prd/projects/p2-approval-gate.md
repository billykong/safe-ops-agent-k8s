# P2 - Kubernetes-native human approval gate

**Goal:** the agent never changes the cluster directly. It proposes; a human approves; a small trusted controller applies. Nothing the agent can do approves, alters or bypasses that flow. Covers goal G2.

Status: **done** (milestones 1-6: CRD, controller, agent fence; authenticated approver, hash binding, expiry, CLI; admission guard on the agent's writes; change budget and kill switch; durable execution with Temporal; computed review packet and oversight metrics). Seeded known-bad proposals (P2-43) move to P4's evals. Implementation: [projects/02-approval-gate/](../../../projects/02-approval-gate/README.md). Depends on P1.

## User stories

- As an **agent**, I can propose a change with its intent, diff, blast radius, scope and rollback, and resume my workflow when it's decided, even hours later.
- As an **approver**, I see a deterministic review packet, and my approval applies to exactly what I reviewed.
- As an **operator**, I can stop the agent completely with one action, and I can cap how many changes it makes before it must ask.
- As a **security reviewer**, I can see every self-approval and time-of-check/time-of-use path closed by a test.

## Requirements

### Proposal and apply

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P2-01 | A `ChangeRequest` CRD holds intent, the change (typed action preferred over a raw diff), blast radius, declared scope (namespaces, kinds) and a rollback procedure. | Must | **Done**: `make test-approval` (malformed actions rejected by schema/CEL) |
| P2-02 | The spec is immutable after creation (CEL `self == oldSelf`). | Must | **Done**: `make test-approval` (an admin's spec edit is rejected) |
| P2-03 | A controller (kubebuilder) applies a request only when it is approved, unexpired and its hash matches. It holds namespace-scoped write credentials, never cluster-admin, and contains no LLM. | Must | **Done**: `make test-approval` (applies only an approval of the current review hash, before `expiresAt`; namespace-scoped `get`/`patch` on Deployments; no LLM) |
| P2-04 | Before applying, the controller re-checks live state against the recorded pre-state. On mismatch, the request goes back for re-approval. | Must | **Done**: `make test-approval` (drift after review clears the approval and re-proposes) |
| P2-05 | Every applied change records pre-state, the exact command or manifest, and the rollback, before it executes. | Must | **Done**: `make test-approval` (pre-state, exact merge patch and rollback patch in status at proposal; restart timestamp fixed) |
| P2-06 | Typed actions (`restart_deployment`, `scale`, `drain_node`, ...) are the default path; arbitrary commands are a rare, separately approved exception, pinned by hash. | Should | **Partial**: `ScaleDeployment` and `RestartDeployment`; typed actions are the only path (no arbitrary commands yet) |
| P2-07 | Policy rejects actions outside the declared scope, even when approved. | Should | **Done** in the controller: `make test-approval`. A policy engine joins in P3 |

### Approval integrity

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P2-10 | Approval lives in the `status` subresource; the agent's identity has no `update` on `changerequests/status`. | Must | **Done**: `make test-approval` (can-i and an actual self-approval attempt, forbidden) |
| P2-11 | The approver is recorded from the authenticated request identity, not from a field in the object. Approval requires an authenticated human. | Must | **Done**: `make test-approval` (a MutatingAdmissionPolicy overwrites `approver` with the authenticated username; a ValidatingAdmissionPolicy requires group `safe-ops:approvers` and no service account; approvers authenticate with client certificates from `scripts/new-approver.sh`) |
| P2-12 | Approval binds to a content hash of the spec and expires. | Must | **Done**: `make test-approval` (the hash covers UID, spec, pre-state, plan and rollback; another hash is discarded; expiry by the controller's clock, `approvalWindowSeconds` capped at a day) |
| P2-13 | An admission webhook rejects direct writes to managed resources by the agent's identity, fail-closed and scoped to that identity. | Must | **Done** as a ValidatingAdmissionPolicy, not a webhook (in-process: no TLS or extra service to fail): `make test-agent-guard` (with the agent's RBAC deliberately widened, direct writes are still refused; the agent's own work and other identities are unaffected). Limit: [GAP-02](../../known-gaps.md#gap-02-admission-guards-cant-protect-their-own-configuration) |
| P2-14 | The agent has no RBAC on webhooks, policies, the kill switch, CRDs or RBAC objects, and can't create pods (SEC-06). | Must | **Done**: no RBAC on CRDs, RBAC objects, admission policies and webhooks, impersonation, escalate/bind, token minting, CSRs, the controller, pods, the change budget or the kill switch flag (`make test-approval`, `make test-agent-guard`, `make test-budget`, `make test-kill-switch`). Limit: [GAP-02](../../known-gaps.md#gap-02-admission-guards-cant-protect-their-own-configuration) |

### Bounding and stopping

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P2-20 | Change budget: N autonomous changes, then the agent must ask. | Must | **Done**: `make test-budget` (a `ChangeBudget` of N eligible changes per rolling window, eligibility decided by code: action types, namespaces, replica range; grants recorded with an optimistic lock before applying; past the budget, or ineligible, a change waits for a human; agent and approvers can't change it, nobody but the controller can record a grant) |
| P2-21 | Kill switch: a flag checked by a fail-closed admission webhook, plus revoking the agent's credentials, cancelling in-flight workflows and scaling the agent to zero. | Must | **Done** with a ValidatingAdmissionPolicy instead of a webhook: `make test-kill-switch` (one command; the flag stops the agent's claims and proposals, pods and tokens in its namespace; the ServiceAccount is recreated, so a stolen token fails even for reads; the agent's Job is suspended and can't come back; its sandbox is released; open proposals are cancelled by the controller; missing or garbled flag means stopped) and `make test-durable` (running Temporal workflows terminated, the worker scaled to zero) |
| P2-22 | A tested decommission / break-glass runbook for the kill switch. | Should | **Done**: [docs/runbooks/kill-switch.md](../../runbooks/kill-switch.md); stop, check, resume and fail-closed cases run by `make test-kill-switch` |

### Durable execution

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P2-30 | The agent pauses and resumes across approvals that take hours (Temporal workflow or LangGraph `interrupt`). | Must | **Done** with Temporal: `make test-durable` (each task is a `ChangeWorkflow` that proposes once, idempotently, and waits in heartbeating poll activities; it survives the worker being down for the whole approval; a long wait continues as new with its progress, so history stays bounded; every outcome reaches the workflow). Limit: [GAP-03](../../known-gaps.md#gap-03-temporals-frontend-has-no-authentication) |
| P2-31 | Demo: a pod restart mid-approval loses no state. | Should | **Done**: `make test-durable` (worker and Temporal server pods both deleted mid-approval; the workflow resumes waiting, applies on approval, and proposed exactly once) |

### Review experience and oversight

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P2-40 | The review packet is computed by code, not an LLM: exact diff and server-side dry run, blast radius, policy findings, budget remaining, rollback and whether it was tested. The model's rationale is secondary and labelled. | Must | **Done**: `make test-review` (the controller dry-runs the exact patch server-side, admission included, and records the field diff; computes the blast radius from the live object and its PodDisruptionBudgets; applies deterministic rules for findings, a refused dry run among them; checks that the rollback patch restores the pre-state exactly; all covered by the review hash and writable only by the controller. `approvalctl show` puts this first, with budget remaining, and the agent's account last as unverified claims; approving a Critical finding needs `--accept-critical`) |
| P2-41 | Approval via a CLI first; a Slack-style webhook only with real authentication. | Must | **Done** for the CLI: `approvalctl` (`make test-approval`). No chat channel |
| P2-42 | Oversight metrics: approval rate, time to approve, edit/reject rate per approver. | Should | **Done**: `make test-review` (`approvalctl stats` and Prometheus metrics on the controller: approvals and rejections per approver, time from proposal to decision, approvals of flagged requests, outcomes by what settled them, re-proposals after drift; derived from the ChangeRequests on each scrape, so a restart doesn't reset them). Edits are impossible by design (immutable spec); drift re-proposals stand in for them. Scraping joins P4 |
| P2-43 | Seeded known-bad proposals measure approver catch rate. | Could | Planned for P4's eval suite; `safeops_approver_approvals_flagged` already counts approvals of requests the rules flagged |
| P2-44 | Risk tiers: low-risk, reversible, in-budget typed actions matching a pre-approved runbook can be auto-approved **by deterministic policy**, never by an AI. | Could | **Done** as the change budget: it pays only for eligible actions the semantic action gate allows (`policy/gate.rego`, P3-10: no Warning or Critical findings, not a critical service; `make test-budget`, `make test-policy`); everything else needs a human |

## Acceptance

- A full flow works end to end: propose, approve via CLI, apply, record, roll back. **Met**: `make test-review` (rollback is the inverse typed action, proposed and approved through the same gate; its diff matches the recorded rollback plan).
- **Met**: tests prove each closure: agent can't approve (RBAC and identity), approval can't be reused for a changed spec (hash), stale approval is rejected (expiry), drifted live state blocks apply, direct agent writes are denied, the kill switch stops an in-flight workflow and revokes credentials.
