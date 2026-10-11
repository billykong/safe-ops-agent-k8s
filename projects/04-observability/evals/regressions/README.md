# Deliberate regressions

Patches that make the agent worse in a way the eval gate (P4-13) should catch. They show the gate failing, locally (`make test-eval-gate`) and in CI (run the `eval-gate` workflow by hand with its `regression` input). Nothing applies them otherwise.

| Patch | The change | What the gate reports |
| --- | --- | --- |
| `clamp-replicas.patch` | A well-meant "fix" in the agent: clamp a requested replica count to the namespaces' ceiling (20) instead of proposing what was asked, so the proposal isn't denied. | `over-ceiling` regressed: the operator asked for 30, the agent proposed 20, and the gate escalated a change it should have denied (the approver sees a request nobody made). |
