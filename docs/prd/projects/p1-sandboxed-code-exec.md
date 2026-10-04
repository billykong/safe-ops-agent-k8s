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
| P1-05 | CPU, memory and ephemeral-storage limits per sandbox; a pids limit per pod. The memory limit is a hard cap: pods can't swap. | Must | **Done**: `make attack-demos` (memory bombs). The pod pids limit doesn't apply inside gVisor; fork bombs are stopped by P1-34 |
| P1-06 | Sandbox egress is denied by default: no internet, no API server, no cluster DNS. | Must | **Done**: `make verify` with negative control |
| P1-07 | Only the agent (`app=agent` in namespace `agent`) can reach the sandbox, and only on the executor port. | Must | **Done**: `make test-executor`, `make test-agent` |
| P1-08 | No policy is added behind our back: the sandbox template sets `networkPolicyManagement: Unmanaged`. | Must | **Done**: `make verify` egress check would fail otherwise |
| P1-09 | ICMP from the sandbox is blocked. | Must | **Done**: `make attack-demos` (raw socket denied; unprivileged ICMP dropped, seen in Hubble) |
| P1-10 | Where a task needs egress, only allowlisted DNS names can be resolved and reached (Cilium `toFQDNs`). | Should | **Done**: `make test-egress` (allowlisted names and `pip install` work; other names, IPs, ports and direct DNS blocked; default pool unaffected) |
| P1-12 | Allowlisted egress pins the TLS SNI, so other sites sharing a CDN address are not reachable by name. | Should | **Done**: `make test-egress` |
| P1-13 | Egress can't be redirected by domain fronting (SNI of an allowed name, `Host` of another site on the same CDN). Needs an in-cluster mirror or egress proxy rather than direct internet access. | Should | **Gap**: reported by `make test-egress`; planned with P3's gateway |
| P1-11 | Kata Containers runtime available as a stronger alternative, benchmarked on bare metal. | Could | Planned (M7) |

### Lifecycle

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P1-20 | Sandboxes are claimed from a warm pool (`SandboxWarmPool`) and destroyed on release; no state carries between tasks. | Must | **Done**: `make test-agent` (claim, release, no leftover claim) |
| P1-21 | A claim carries a `shutdownTime` backstop so a dead agent can't leak sandboxes. | Should | **Partial**: set by the agent; expiry not tested |
| P1-22 | Readiness is reported without the node needing network access to the sandbox (`exec` probe). The probe is cheap under gVisor, and a 1s startup probe reports a cold sandbox ready within about a second of the executor listening. | Must | **Done**: warm pool reaches ready in all tests; timing in `make bench` |
| P1-23 | Cap on warm-pool size and concurrent sandboxes (ResourceQuota). | Should | Planned |
| P1-24 | Node swap is off for all pods (`kubelet.slice` `MemorySwapMax=0`), so memory limits are real regardless of runtime. | Must | **Done**: applied by `make up`; memory bombs in `make attack-demos` |

### Executor

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P1-30 | `POST /run {code, timeout_s}` returns `{stdout, stderr, exit_code, timed_out, duration_ms, truncated}`; `GET /healthz`. | Must | **Done**: `make executor-test`, `make test-executor` |
| P1-31 | Wall-clock timeout kills the whole process group, so background children can't outlive the run. Timeout capped at 60s, with an `RLIMIT_CPU` backstop. | Must | **Done**: `make executor-test` |
| P1-32 | Output capped at 64 KiB per stream; request body capped at 256 KiB; one run at a time (409 when busy). | Must | **Done**: `make executor-test` |
| P1-33 | The executor is documented as not a security boundary. | Must | **Done**: P1 README |
| P1-34 | User code runs with `RLIMIT_NPROC` (32), sized to fit the memory budget, so a fork bomb fails with `EAGAIN` and the sandbox survives. | Must | **Done**: `make attack-demos` (fork-bomb) |
| P1-35 | User code runs with `RLIMIT_AS` (192 MiB per process), so one over-sized allocation fails with `MemoryError` instead of crashing the sandbox. | Must | **Done**: `make executor-test`, `make attack-demos` (memory-bomb) |
| P1-36 | No user process outlives a run, including `setsid()`-detached ones: the executor kills every other process of its uid after each run, repeating until none remain. | Must | **Done**: `make attack-demos` (persistence) |
| P1-37 | A process reaper (`tini`) is PID 1, so killed processes don't linger as zombies that consume the process cap. | Must | **Done**: `make attack-demos` (post-attack health check forks) |
| P1-38 | Memory exhaustion spread across processes (each under P1-35) is contained to the one sandbox: other sandboxes and the node are unaffected. | Must | **Done**: `make attack-demos` (memory-bomb-multiprocess, CONTAINED) |

### Agent side

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P1-40 | The agent runs in its own namespace and pod, never in the sandbox. | Must | **Done**: `make test-agent` |
| P1-41 | Agent RBAC: `create/get/delete` on `sandboxclaims` and `get` on `sandboxes` in `sandboxes` only. No direct `Sandbox` creation, no claim update or list, no pods, exec or secrets. | Must | **Done**: `make test-agent` |
| P1-42 | Admission policy: the agent's claims must name an approved warm pool (`python-gvisor`, `python-gvisor-pypi`) and may not add pod labels/annotations, env or volumes. Denials come from the policy, not schema validation. | Must | **Done**: `make test-agent` |
| P1-43 | Agent egress: only the API server and sandbox port 8888. No internet, no DNS, no other sandbox ports. | Must | **Done**: `make test-agent` |
| P1-44 | The agent always releases its claim, including on error. | Must | **Partial**: release on success tested; error path not tested |

### Evidence

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P1-50 | Attack demos: fork bomb, memory bombs, credential hunt, persistence, TCP egress, DNS exfiltration, ICMP. Each names the layer that stopped it, with independent host-side evidence (restart counts, Hubble drops). | Must | **Done**: `make attack-demos`; report in `results/attack-demos.md` |
| P1-51 | Benchmarks: cold `Sandbox` vs warm-pool claim latency; runc vs gVisor overhead for CPU, syscall-heavy and I/O workloads. Each states the runtime and environment used. | Must | **Done**: `make bench`; report in `results/benchmarks.md` |
| P1-52 | A clean rebuild (`make down up p1`) passes all P1 suites. | Must | **Done**: last run (2026-10-04) 7 + 8 + 26 + 13 + 9 checks across verify, test-executor, test-agent, test-egress and attack-demos; test-egress also reports its 1 known GAP |

## Acceptance

P1 is done when every **Must** above is *Done*, the attack demos and benchmarks are in `results/`, and the findings log is up to date.
