# Known gaps

Weaknesses we know about, have reproduced, and haven't closed yet. Each has an ID that tests and docs refer to. A test that reproduces a gap reports `GAP <id>` instead of passing or failing, so the gap stays visible in every run without blocking the suite. When a gap is closed, its test check becomes a normal PASS/FAIL and the entry moves to *Closed* with the commit that closed it.

| ID | Gap | Severity | Status | Requirement |
| --- | --- | --- | --- | --- |
| [GAP-01](#gap-01-domain-fronting-through-the-pypi-egress-allowlist) | Domain fronting through the PyPI egress allowlist | High for sandboxes with egress; none for default sandboxes | Open | [P1-13](prd/projects/p1-sandboxed-code-exec.md) |
| [GAP-02](#gap-02-admission-guards-cant-protect-their-own-configuration) | Admission guards can't protect their own configuration | Low today (the agent has no such RBAC); critical if that RBAC is ever granted | Open (inherent; mitigated by RBAC tests) | [P2-13, P2-14, P2-21](prd/projects/p2-approval-gate.md) |
| [GAP-03](#gap-03-temporals-frontend-has-no-authentication) | Temporal's frontend has no authentication | Low (only the agent's worker can reach it, and it can already do what the API allows) | Open (accepted for the dev server) | [P2-30](prd/projects/p2-approval-gate.md) |

## GAP-01: domain fronting through the PyPI egress allowlist

**Found:** 2026-10-04, P1 milestone 6. **Reproduced by:** `make test-egress`, check `domain fronting (SNI pypi.org, Host www.fastly.com)`, reported as `GAP GAP-01`.

### What's wrong

Sandboxes from the `python-gvisor-pypi` pool may reach `pypi.org` and `files.pythonhosted.org` on 443 (`projects/01-sandboxed-code-exec/manifests/65-networkpolicy-egress-pypi.yaml`). The policy works at three layers:

1. DNS: Cilium's DNS proxy answers only those exact names.
2. IP: TCP 443 only to addresses the proxy has returned for them (`toFQDNs`).
3. TLS: the SNI must be one of the names (`serverNames`, checked by Envoy without decrypting).

PyPI is served by Fastly, whose addresses are shared by many other customers. Code in the sandbox can open TLS to PyPI's address with SNI `pypi.org` (passing all three checks) and then send an HTTP `Host` header naming any other Fastly-hosted site. Fastly routes by the `Host` header, which is inside the encrypted stream, so Cilium can't see it.

### Impact

A sandbox with PyPI egress can send data to, and receive data from, any service on Fastly, including one an attacker sets up for a few dollars. That's an exfiltration and command-and-control channel for code that prompt injection or a malicious package got into the sandbox. Default sandboxes (no egress) are not affected.

### Evidence

From a `python-gvisor-pypi` sandbox, connecting to PyPI's address with SNI `pypi.org`:

| `Host` header | Response | Meaning |
| --- | --- | --- |
| `pypi.org` | `200`, `server: gunicorn` | Intended |
| `www.fastly.com` | `200`, `Server: Artisanal bits` | Another Fastly customer's site served |
| `www.nytimes.com` | `403`, `server: DataDome` | Request reached the NYT's origin (its bot wall answered) |
| `www.python.org` | `200`, `server: nginx` | Another site reached |

Without the SNI pin, even plain HTTPS by name to those sites worked through PyPI's address. The pin closed that, not fronting.

### Options

| Option | Closes it? | Cost |
| --- | --- | --- |
| **In-cluster package mirror or proxy** (e.g. devpi, or a pip-index proxy) as the sandbox's only egress destination; it fetches from PyPI itself and serves only package paths | Yes, for the sandbox: the sandbox has no internet route at all | A component to run; the mirror's own egress must be fenced the same way. Fits P3's tool gateway |
| **Cilium TLS interception** (`terminatingTLS`/`originatingTLS` with HTTP rules on `Host` and path) | Yes | The sandbox must trust a cluster CA; Envoy sees plaintext; keys to manage |
| **Pre-built images or wheels** for known dependencies, so most tasks need no egress | Avoids it for those tasks | Image rebuilds per dependency set |
| Keep the allowlist minimal and egress pools small | Narrows it, doesn't close it | — |

**Planned:** the mirror/proxy, with P3's gateway. Until then, treat the pypi pool as able to reach Fastly.

### Status

Open.

## GAP-02: admission guards can't protect their own configuration

**Found:** 2026-10-07, P2 milestone 3. **Reproduced by:** `make test-agent-guard`, reported as `GAP GAP-02`.

### What's wrong

`agent-write-guard` (`projects/02-approval-gate/manifests/80-agent-write-guard.yaml`) refuses every write by the agent's identity outside a small allowlist, even when RBAC would allow it. But Kubernetes never applies admission policies or webhooks to admission configuration itself: `ValidatingAdmissionPolicy`, `MutatingAdmissionPolicy`, their bindings, and webhook configurations. This avoids configurations that lock everyone out. So an agent whose RBAC were widened to cover `admissionregistration.k8s.io` could delete the guard, then do what the guard was there to stop. The approval-integrity policies of P2 milestone 2 and the admission half of the kill switch (P2 milestone 4) are equally exposed; the kill switch's credential revocation and scale-to-zero are not.

Two related permissions are invisible to any admission check: `impersonate`, since a request made while impersonating is admitted as the impersonated user, and `escalate`/`bind` on RBAC.

### Evidence

With RBAC temporarily widened to write almost anything (not impersonate/escalate/bind), the guard refused patching workloads, scaling, deleting a namespace, creating pods and secrets, exec, editing the controller, cordoning the node, and removing the widening itself. A server-side dry run of deleting `agent-write-guard` was admitted.

### Impact

None while the agent has no RBAC on admission configuration, impersonation, escalate or bind. That is checked by `make test-agent-guard` and `make test-approval`. If someone ever grants it, the backstop and the approval-integrity policies can be removed by the agent.

### Options

| Option | Closes it? | Cost |
| --- | --- | --- |
| Keep those permissions away from the agent, and test it on every run | Keeps it closed in practice | Already done; relies on RBAC hygiene |
| Alert on changes to admission configuration (API audit log to an agent-unwritable store, P4) | Detects, doesn't prevent | Audit pipeline |
| Manage admission configuration with GitOps reconciliation (re-applied within minutes) | Shrinks the window | A reconciler with its own privileges |
| Out-of-cluster enforcement (e.g. an API proxy in front of the agent) | Yes, for the agent's traffic | Another component in the agent's path |

### Status

Open, inherent to in-cluster admission control. Mitigated by keeping and testing the RBAC exclusions.

## GAP-03: Temporal's frontend has no authentication

**Found:** 2026-10-07, P2 milestone 5. **Reproduced by:** `make test-durable`, section "Temporal's network fence" (the controls around it; the gap itself is a property of the deployment).

### What's wrong

The agent's workflows run on Temporal's development server (`projects/02-approval-gate/durable/manifests/10-temporal.yaml`), which has no authentication or authorization: any client that reaches port 7233 can start, signal, query, terminate or reset any workflow in any namespace, and read every workflow's history, inputs and results included.

### Impact

Limited by the network policy: only pods labelled `app: agent-worker` in the `agent` namespace can connect (`make test-durable` checks that other agent pods, other namespaces and sandboxes can't). That pod is the agent itself, so the gap gives the agent nothing over its own work it couldn't already do: it could terminate or rewrite its own workflows, or start new ones, each of which can only propose ChangeRequests through the same RBAC and admission. It can't approve, apply or bypass anything through Temporal. The exposure grows if anything else is ever allowed to reach Temporal, or if workflow inputs start carrying secrets (they mustn't: P3 keeps secrets in gateways).

The dev server is also a single process with SQLite on one volume: no high availability, and losing the volume loses in-flight workflows (the ChangeRequests, the record that matters, are unaffected).

### Options

| Option | Closes it? | Cost |
| --- | --- | --- |
| Temporal server with mTLS, a claim mapper and an authorizer (per-namespace roles from client certificates or JWTs) | Yes | Production deployment (separate services, Postgres), certificate management |
| Temporal Cloud | Yes | External dependency; data leaves the cluster |
| Keep the network fence, and keep secrets out of workflow inputs | Narrows it | Already done |

### Status

Open, accepted for the development server. Revisit when Temporal moves to a production-style deployment or any second client needs access.
