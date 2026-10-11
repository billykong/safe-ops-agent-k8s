# P4 - Observability and evals

**Goal:** what the agent does, what it costs and whether it's still safe are visible by default and checked continuously. Changes to the agent are gated on replayed evaluations. Covers goal G4.

Status: **in progress**: milestones 1 (telemetry), 2 (API audit log), 3 (replay evals) and 4 (CI regression gate) done. Depends on P2 and P3; uses P5 for a local judge. Built in [projects/04-observability/](../../../projects/04-observability/README.md).

## User stories

- As an **operator**, I can trace any task from model call to tool call to change, and see tokens and cost per task.
- As a **maintainer**, a change to the agent's prompts, model or code can't merge if it regresses on recorded scenarios.
- As a **risk reviewer**, I can see whether human oversight is working, not just whether approvals happen.

## Requirements

### Telemetry

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P4-01 | OpenTelemetry traces using the GenAI semantic conventions: a span per model call and tool call, with token counts. | Must | **Done** (M1): one trace per task from the starter through the workflow, `chat` and `execute_tool` spans at the agent and both gateways, and the controller's gate decision and outcome via the ChangeRequest's `traceparent` annotation; `make test-observability`. The collector can't authenticate senders ([GAP-06](../../known-gaps.md#gap-06-the-collector-cant-tell-who-sent-a-span)) |
| P4-02 | Token and cost metrics, and escalation rate, exported to Prometheus with Grafana dashboards. | Must | **Done** (M1): tokens, estimated cost and request outcomes per identity from the LLM gateway; tool calls from the MCP gateway; gate decisions from the controller; the agent's decisions and escalations over OTLP; a provisioned dashboard with cost per task and escalation rates |
| P4-03 | Trace content capture (prompts, tool outputs) off or redacted by default. | Must | **Done** (M1): off in every sender, and enforced by an attribute allowlist in the collector; the suite checks a canary in the instruction never reaches Jaeger and that content sent directly to the collector is stripped |
| P4-04 | Kubernetes API audit logging captures the agent's identity, shipped to a store the agent can't write to or delete from. | Should | **Done** (M2): the API server's audit policy records everything the agents do (writes in full) and every change to what guards them; events go over mTLS to a sink that appends them to a hash chain on a retained volume, plus a root-only log on the node. Events name the agent's service account and the pod, node and token id behind it, and a proposal's event carries its task's trace id. The agent has no RBAC in namespace `audit`, no route to the sink and no client certificate; an edit on disk breaks the chain and alerts. Changes to admission configuration alert (GAP-02); `make audit test-audit`. A sink outage over ~45s loses events from the sink, not the node's log ([GAP-07](../../known-gaps.md#gap-07-a-long-audit-sink-outage-loses-events-from-the-sink)) |

### Evals

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P4-10 | A suite replays recorded scenarios against fresh sandboxes, as Kubernetes Jobs or Argo Workflows. | Must | **Done** (M3): a Job as the evaluator's identity replays scenarios from git through the real agent, gateways, controller and gate, each against a fresh target in namespace `eval-sandbox`, and records one EvalRun; `make evals test-evals`, `scripts/eval-run.sh` |
| P4-11 | Scoring combines deterministic checks with a blind LLM judge, which sees the goal and the result, not the agent's reasoning. Use a different model or prompt family from the agent. | Must | **Done** (M3): checks on decision, replicas, gate result, tools read and an unchanged target; a judge on `claude-sonnet-5-5` (the agent runs `claude-opus-5-5`) with its own prompt, given the task and the outcome only. The runner never receives the reasoning, and the suite checks the judge's request at the provider; a same-model judge is refused |
| P4-12 | Only the evaluator's identity can write verdicts. | Must | **Done** (M3): RBAC plus the `eval-verdict-authority` admission policy, which refuses cluster admins too; EvalRuns are append-only (immutable spec, no update or delete); creations and refused attempts are in the audit log |
| P4-13 | CI gates merges on eval regressions. | Must | **Done** (M4): on every pull request to main, CI builds the stack on a fresh kind cluster, replays the scenarios with the mock model, and fails if a scenario the baseline in git passes now fails, if safety didn't hold, or if a scenario, the agent's prompt or model, or the judge changed without a new baseline; required check `result`; `make eval-gate test-eval-gate`. The mock doesn't score prompt or model changes, only forces a re-baseline ([GAP-08](../../known-gaps.md#gap-08-the-ci-gate-cant-score-a-prompt-or-model-change)) |
| P4-14 | The kill switch is exercised as part of the suite. | Must | Planned |
| P4-15 | Seeded known-bad proposals measure catch rate for the AI reviewer and human approvers. | Should | Planned |

### Metrics that matter

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P4-20 | Track reopen rate, escalation rate and cost per task, not just throughput. | Must | **Partial** (M1): escalation rate (agent and gate) and cost per task on the dashboard; reopen rate in M5 |
| P4-21 | Track oversight health: approval rate, time to approve, override/reject counts. A near-100% approval rate with seconds-long reviews raises an alert. | Should | Planned |
| P4-22 | Quality metrics sit alongside throughput, so the system can't game its own metric. | Must | Planned |

## Acceptance

A deliberately regressed agent change fails CI on the eval gate. Dashboards show cost per task and escalation rate for a test run. A trace for one task links model calls, tool calls and the resulting `ChangeRequest`, with prompt content redacted.

Status: dashboards show cost per task and escalation rate for a test run, and a task's trace links model calls, tool calls and the resulting `ChangeRequest` with no prompt content (milestone 1, `make test-observability`). A deliberately regressed agent change (`evals/regressions/clamp-replicas.patch`) fails the eval gate (milestone 4, `make test-eval-gate`; in CI, the workflow's `regression` input).
