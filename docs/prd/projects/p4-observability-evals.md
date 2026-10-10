# P4 - Observability and evals

**Goal:** what the agent does, what it costs and whether it's still safe are visible by default and checked continuously. Changes to the agent are gated on replayed evaluations. Covers goal G4.

Status: **in progress**: milestone 1 (telemetry) done. Depends on P2 and P3; uses P5 for a local judge. Built in [projects/04-observability/](../../../projects/04-observability/README.md).

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
| P4-04 | Kubernetes API audit logging captures the agent's identity, shipped to a store the agent can't write to or delete from. | Should | Planned |

### Evals

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P4-10 | A suite replays recorded scenarios against fresh sandboxes, as Kubernetes Jobs or Argo Workflows. | Must | Planned |
| P4-11 | Scoring combines deterministic checks with a blind LLM judge, which sees the goal and the result, not the agent's reasoning. Use a different model or prompt family from the agent. | Must | Planned |
| P4-12 | Only the evaluator's identity can write verdicts. | Must | Planned |
| P4-13 | CI gates merges on eval regressions. | Must | Planned |
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

Status: dashboards show cost per task and escalation rate for a test run, and a task's trace links model calls, tool calls and the resulting `ChangeRequest` with no prompt content (milestone 1, `make test-observability`). The CI eval gate is milestone 4.
