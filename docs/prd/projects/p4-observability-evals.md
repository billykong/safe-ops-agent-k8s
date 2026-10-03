# P4 - Observability and evals

**Goal:** what the agent does, what it costs and whether it's still safe are visible by default and checked continuously. Changes to the agent are gated on replayed evaluations. Covers goal G4.

Status: **not started**. Depends on P2 and P3; uses P5 for a local judge.

## User stories

- As an **operator**, I can trace any task from model call to tool call to change, and see tokens and cost per task.
- As a **maintainer**, a change to the agent's prompts, model or code can't merge if it regresses on recorded scenarios.
- As a **risk reviewer**, I can see whether human oversight is working, not just whether approvals happen.

## Requirements

### Telemetry

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P4-01 | OpenTelemetry traces using the GenAI semantic conventions: a span per model call and tool call, with token counts. | Must | Planned |
| P4-02 | Token and cost metrics, and escalation rate, exported to Prometheus with Grafana dashboards. | Must | Planned |
| P4-03 | Trace content capture (prompts, tool outputs) off or redacted by default. | Must | Planned |
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
| P4-20 | Track reopen rate, escalation rate and cost per task, not just throughput. | Must | Planned |
| P4-21 | Track oversight health: approval rate, time to approve, override/reject counts. A near-100% approval rate with seconds-long reviews raises an alert. | Should | Planned |
| P4-22 | Quality metrics sit alongside throughput, so the system can't game its own metric. | Must | Planned |

## Acceptance

A deliberately regressed agent change fails CI on the eval gate. Dashboards show cost per task and escalation rate for a test run. A trace for one task links model calls, tool calls and the resulting `ChangeRequest`, with prompt content redacted.
