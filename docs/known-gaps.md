# Known gaps

Weaknesses we know about, have reproduced, and haven't closed yet. Each has an ID that tests and docs refer to. A test that reproduces a gap reports `GAP <id>` instead of passing or failing, so the gap stays visible in every run without blocking the suite. When a gap is closed, its test check becomes a normal PASS/FAIL and the entry moves to *Closed* with the commit that closed it.

| ID | Gap | Severity | Status | Requirement |
| --- | --- | --- | --- | --- |
| [GAP-01](#gap-01-domain-fronting-through-the-pypi-egress-allowlist) | Domain fronting through the PyPI egress allowlist | High for sandboxes with egress; none for default sandboxes | Open | [P1-13](prd/projects/p1-sandboxed-code-exec.md) |
| [GAP-02](#gap-02-admission-guards-cant-protect-their-own-configuration) | Admission guards can't protect their own configuration | Low today (the agent has no such RBAC); critical if that RBAC is ever granted | Open (inherent; mitigated by RBAC tests) | [P2-13, P2-14, P2-21](prd/projects/p2-approval-gate.md) |
| [GAP-03](#gap-03-temporals-frontend-has-no-authentication) | Temporal's frontend has no authentication | Low (only the agent's worker and the eval runner can reach it) | Open (accepted for the dev server) | [P2-30](prd/projects/p2-approval-gate.md) |
| [GAP-04](#gap-04-agent-to-gateway-traffic-is-plaintext) | Agent-to-gateway traffic is plaintext | Low on one node; Medium on multi-node clusters | Open | [P3-24](prd/projects/p3-tool-identity-policy.md) |
| [GAP-05](#gap-05-narrow-channels-through-allowed-tool-arguments) | Narrow channels through allowed tool arguments | Low (about 20 bits a call, to the incident tracker only) | Open (accepted) | [P3-31](prd/projects/p3-tool-identity-policy.md) |
| [GAP-06](#gap-06-the-collector-cant-tell-who-sent-a-span) | The collector can't tell who sent a span | Low (traces are a debugging aid; the numbers that matter are scraped from the gateways and controller) | Open | [P4-01](prd/projects/p4-observability-evals.md) |
| [GAP-07](#gap-07-a-long-audit-sink-outage-loses-events-from-the-sink) | A long audit sink outage loses events from the sink | Low (the node's log keeps them, and the drop alerts) | Open | [P4-04](prd/projects/p4-observability-evals.md) |
| [GAP-08](#gap-08-the-ci-gate-cant-score-a-prompt-or-model-change) | The CI gate can't score a prompt or model change | Medium (a prompt change needs a deliberate re-baseline, but nothing checks it was tested on the real model) | Open | [P4-13](prd/projects/p4-observability-evals.md) |

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
| Alert on changes to admission configuration (API audit log to an agent-unwritable store) | Detects, doesn't prevent | **Done** in P4 milestone 2: alert `AdmissionConfigChanged`, `make test-audit` |
| Manage admission configuration with GitOps reconciliation (re-applied within minutes) | Shrinks the window | A reconciler with its own privileges |
| Out-of-cluster enforcement (e.g. an API proxy in front of the agent) | Yes, for the agent's traffic | Another component in the agent's path |

### Status

Open, inherent to in-cluster admission control. Mitigated by keeping and testing the RBAC exclusions, and detected: since P4 milestone 2 every change to admission configuration is in the API audit log and raises `AdmissionConfigChanged` (`make test-audit`).

## GAP-03: Temporal's frontend has no authentication

**Found:** 2026-10-07, P2 milestone 5. **Reproduced by:** `make test-durable`, section "Temporal's network fence" (the controls around it; the gap itself is a property of the deployment).

### What's wrong

The agent's workflows run on Temporal's development server (`projects/02-approval-gate/durable/manifests/10-temporal.yaml`), which has no authentication or authorization: any client that reaches port 7233 can start, signal, query, terminate or reset any workflow in any namespace, and read every workflow's history, inputs and results included.

### Impact

Limited by the network policy: only pods labelled `app: agent-worker` in the `agent` namespace, and since P4 milestone 3 the eval runner (`app: eval-runner` in `evals`), can connect (`make test-durable` checks that other agent pods, other namespaces and sandboxes can't). That pod is the agent itself, so the gap gives the agent nothing over its own work it couldn't already do: it could terminate or rewrite its own workflows, or start new ones, each of which can only propose ChangeRequests through the same RBAC and admission. It can't approve, apply or bypass anything through Temporal. The exposure grows with each client allowed to reach Temporal, or if workflow inputs start carrying secrets (they mustn't: P3 keeps secrets in gateways). The eval runner is the second: it needs to start the agent's workflows and query their decisions, but could also terminate, signal or reset any of them, and read their histories, which hold the model's reasoning. The eval judge's blindness (P4-11) therefore rests on the runner's code, not on what its identity can reach.

The dev server is also a single process with SQLite on one volume: no high availability, and losing the volume loses in-flight workflows (the ChangeRequests, the record that matters, are unaffected).

### Options

| Option | Closes it? | Cost |
| --- | --- | --- |
| Temporal server with mTLS, a claim mapper and an authorizer (per-namespace roles from client certificates or JWTs) | Yes | Production deployment (separate services, Postgres), certificate management |
| Temporal Cloud | Yes | External dependency; data leaves the cluster |
| Keep the network fence, and keep secrets out of workflow inputs | Narrows it | Already done |

### Status

Open, accepted for the development server. A second client (the eval runner, a trusted identity) now has access; with an authorizer it would get only start and query on the agent's task queue. Revisit when Temporal moves to a production-style deployment, or before anything less trusted needs access.

## GAP-04: agent-to-gateway traffic is plaintext

**Found:** 2026-10-08, P3 milestone 1.

### What's wrong

Agents call the LLM gateway over plain HTTP on the pod network, with their gateway token in the `Authorization` header. Whoever can read pod traffic (a compromised node, a privileged pod with host networking, a misconfigured mirror) can copy the token. The gateway also isn't authenticated to the agent: something answering on the gateway's address could collect tokens and feed the agent responses.

### Impact

Limited by the token's design: it's valid only for the gateway's audience (the API server and any other service refuse it), bound to its pod, and expires in at most 10 minutes. The response side matters more from milestone 2, when model output flows back over this connection. On this single-node kind cluster, traffic doesn't leave the node.

### Options

| Option | Closes it? | Cost |
| --- | --- | --- |
| Cilium transparent encryption (WireGuard) between nodes | For node-to-node traffic only; same-node traffic stays clear | A Cilium setting; WSL2 kernel support to check |
| TLS on the gateway, with a cluster CA the agents trust | Confidentiality and gateway authentication | Certificate issuance and rotation (cert-manager) |
| Mutual TLS with SPIFFE identities (SPIRE, or Cilium's mutual authentication) | Both directions (P3-24) | SPIRE to run |

### Status

Open. Planned with P3-24 (mutual authentication), once the gateway carries model traffic.

## GAP-05: narrow channels through allowed tool arguments

**Found:** 2026-10-10, P3 milestone 5. **Reproduced by:** `make red-team`, attack RT-16, reported as `GAP GAP-05`.

### What's wrong

The MCP gateway refuses a tool argument that doesn't match its rule in the registry. That closed the wide channels: a DNS name under an attacker's domain (RT-10) and an incident id with data appended (RT-12). But an argument that matches still carries whatever its allowed values can encode. `get_incident` accepts `INC-` and 4 to 6 digits, so a model following an injection can ask for `INC-778142`, and the tracker (an external SaaS in this design) receives those digits in its request path, logs them, and answers 404.

### Impact

About 20 bits per call, to the tracker only: at most 3 lookups a turn and 6 model calls per decision is under 50 bytes a decision, and each call is in the gateway's audit log with the identity and pod. Exploiting it needs both an injection the model obeys and access to the tracker's logs (its operator, or an attacker who has compromised it). `resolve` has the same property inside the cluster (a service-name label of up to 63 characters), but that name reaches only the cluster's DNS (RT-13).

### Options

| Option | Closes it? | Cost |
| --- | --- | --- |
| Validate values against what exists (the gateway checks the id against `list_open_incidents` before forwarding) | Yes for ids: only real records can be asked for | A lookup per call; the gateway learns each tool's semantics |
| Rate and anomaly limits on tool calls (repeated 404s, unusual ids) | Narrows it and makes it visible | Thresholds to tune |
| Accept and watch: the audit log names every call | No | None |

### Status

Open, accepted for now. Revisit when a tool with a free-text argument or an external destination is added.

## GAP-06: the collector can't tell who sent a span

**Found:** 2026-10-10, P4 milestone 1. **Reproduced by:** `make test-observability`, reported as `GAP GAP-06`.

### What's wrong

The OpenTelemetry collector accepts OTLP from the agent's worker, the two gateways and the approval controller (network policy), but it doesn't authenticate them, and a span's service is whatever its sender's resource says. The suite sends a span from the agent's pod with `service.name: llm-gateway`, and Jaeger stores it as the gateway's. A compromised agent could add spans that appear to come from the gateways or the controller to any trace: a "gateway" span saying a call was refused, or a "policy gate" span with a different result.

### Impact

Misleading traces, not wrong numbers or a way out:
- The figures that matter are scraped by Prometheus from the gateways and the controller, which the agent can't reach. That covers tokens, cost, refusals, gate decisions and oversight.
- The collector's allowlist still strips content from forged spans (P4-03), and nothing in `observability` reaches outside the cluster.
- The record of what happened is the ChangeRequest's status and the gateways' audit logs, not the trace.

The agent's own metrics (tasks, escalations, model calls) can be inflated the same way; the dashboard compares its model-call count with the gateway's.

### Options

| Option | Closes it? | Cost |
| --- | --- | --- |
| The collector's `k8s_attributes` processor stamps each span with the pod it came from (by connection IP); dashboards and queries trust that, not `service.name` | Makes forgery visible | Read access to pods for the collector; queries change |
| One OTLP endpoint per sender, each authenticated (`bearertokenauth` with projected tokens, or mTLS), and a processor that sets `service.name` from the endpoint | Yes | A token or certificate per sender; more collector config |
| Accept: traces are for debugging, the records live elsewhere | No | None |

### Status

Open. The audit log (milestone 2) doesn't rely on traces: its events come from the API server, over mTLS, and a ChangeRequest's audit event names the trace only as a pointer. Revisit before traces are used for evals (milestone 3).

## GAP-07: a long audit sink outage loses events from the sink

**Found:** 2026-10-10, P4 milestone 2. **Reproduced by:** `make test-audit`, section "A long sink outage", reported as `GAP GAP-07`.

### What's wrong

The API server sends audit events to the sink in batches (webhook backend, batch mode). A batch that fails is retried with backoff, starting at 5s (`--audit-webhook-initial-backoff`), for about 45 seconds in all, and then dropped from the webhook path: the API server logs `Error in audit plugin 'webhook' affecting N audit events` and counts them in `apiserver_audit_error_total{plugin="webhook"}`. With the sink down for longer than that (a node drain, a stuck volume, a crash loop), the events of that window never reach the chain. The suite stops the sink, has the agent make a request, and finds it in the node's log but not in the sink.

Anyone able to stop the sink can open such a window. The agent can't: it has no RBAC in namespace `audit` and no route to the sink.

### Impact

The audit record is complete only in the node's log (`/var/log/kubernetes/audit/audit.log`, root-only, rotated at 100 MB x 5), which isn't hash-chained or shipped anywhere. The sink's chain is complete except for the outage window, and the gap is visible:
- `AuditEventsDropped` alerts on any drop;
- `AuditSinkDown` alerts after two minutes down.

### Options

| Option | Closes it? | Cost |
| --- | --- | --- |
| `--audit-webhook-mode=blocking-strict`: a request isn't served until its event is stored | Yes | The sink becomes part of the API server's availability: sink down, cluster read-only and then down |
| A shipper (Fluent Bit or Vector DaemonSet) tails the node's log with a position file and forwards to the sink, deduplicating by `auditID` | Yes, for outages shorter than log rotation | A privileged pod with a hostPath mount of the audit directory, on every control-plane node |
| More sink replicas behind the Service, each writing its own chain | Shrinks it (restarts, one-pod failures) | Several chains to verify and merge |
| Accept: rely on the node's log and the alert for the window | No | None |

### Status

Open. Revisit when the audit log feeds anything automated (evals, P4 milestone 3), or before running on a multi-node control plane.

## GAP-08: the CI gate can't score a prompt or model change

**Found:** 2026-10-11, P4 milestone 4. **Reproduced by:** `make test-eval-gate`, section "A prompt regression scores the same with the mock", reported as `GAP GAP-08`.

### What's wrong

CI runs the eval scenarios with the mock model: deterministic, free, and needing no key in a pull request. The mock decides from the operator's instruction and the tools it's offered, not from the agent's system prompt or the model the agent asks for. So the gate scores regressions in the agent's code, its tools, the gateways, the controller and the gate's policy, but a prompt or model change scores exactly as before. The suite builds an agent whose prompt no longer sends unclear or unsafe instructions to a human, and its run matches the baseline scenario for scenario.

The gate doesn't let that pass silently: the baseline records the agent's model and prompt hash, and a change to either fails the gate until the baseline is rewritten in the same change. But rewriting it only takes another mock run. Nothing checks that the new prompt was run against the real model first.

### Impact

A prompt or model change merges after a re-baseline that is visible in the diff (and needs the code owner's review, `.github/CODEOWNERS`), not after evidence that the agent still behaves. The scenarios that matter most here, escalating vague or injected instructions, are the ones a prompt change is most likely to break. The approval gate and the human approver still stand behind it: a worse prompt makes worse proposals, not unreviewed changes.

### Options

| Option | Closes it? | Cost |
| --- | --- | --- |
| A live job in CI: the real model through the gateway, with the provider key as a repository secret, on pull requests from this repository only | Yes, for changes from maintainers | Model spend per run; nondeterministic scores need repeated runs or a tolerance; a key in CI |
| Record live runs: `--rebaseline` on a live gateway writes `baseline-live.yaml`, and the gate requires a live baseline whose prompt hash matches the agent's | Mostly: proves a live run happened with this prompt, on the maintainer's cluster; CI can't verify it was that run's result | A maintainer's time and spend per prompt change |
| A local model as the agent's stand-in in CI (P5) | Partly: catches gross prompt regressions, not the production model's behaviour | GPU runner or slow CPU inference |
| Accept: re-baseline by review | No | None |

### Status

Open. Revisit with P5 (local inference), and before anyone else can change the prompt.

