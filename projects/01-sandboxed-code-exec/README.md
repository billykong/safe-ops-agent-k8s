# 01 - Sandboxed code-execution agent

## Goal
The agent loop and the code sandbox run in separate pods. The sandbox has no credentials, no GPU and no route to the agent, model gateway or API server.

## Hardening (in `manifests/`)
- [x] `runtimeClassName: gvisor` (runsc)
- [x] Namespace at Pod Security `restricted`
- [x] Default-deny NetworkPolicy, ingress and egress, enforced by Cilium (eBPF)
- [x] `networkPolicyManagement: Unmanaged` on the template, so agent-sandbox doesn't add its own allow-internet policy
- [x] No service-account token, non-root, read-only rootfs, drop all caps, seccomp RuntimeDefault
- [x] CPU, memory and ephemeral-storage limits
- [x] Pids limit (`podPidsLimit: 512` in the kind kubelet config). Effective for runc pods only; see finding 8
- [x] Node swap off for pods (`make node-swap-off`, run by `make up`), so the memory limit is a hard cap
- [x] Executor caps user code with `RLIMIT_NPROC` 32 and `RLIMIT_AS` 192 MiB, kills every leftover process after each run, and runs under `tini`
- [x] Executor service inside the sandbox, with ingress opened only from `app=agent` pods in the `agent` namespace
- [ ] Cilium DNS-scoped egress for tasks that need it

## Milestones
1. [x] Cluster up with gVisor; `make verify` passes (7/7, from a clean rebuild)
2. [x] Minimal executor (HTTP: run code, return stdout/stderr/exit, wall-clock timeout); `make test-executor` passes 8/8
3. [x] Agent pod (separate namespace) that claims a sandbox, runs code, releases it; `make test-agent` passes 25/25
4. [x] Attack demos showing which control stops each one; `make attack-demos` (report in `results/attack-demos.md`)
5. [x] Benchmarks: cold `Sandbox` vs warm-pool claim latency; runc vs gVisor overhead (CPU, syscall-heavy, I/O); `make bench` (report in `results/benchmarks.md`)

## Executor (`executor/`)
Standard library only, built as `sandbox-executor:dev` and loaded into kind (`make executor-image`, run by `make p1`).

- `POST /run {"code": "...", "timeout_s": 10}` returns `{stdout, stderr, exit_code, timed_out, duration_ms, truncated}`.
- `GET /healthz`.
- Limits:
  - the code runs in its own process group, which is SIGKILLed on timeout or exit. After that, every other process of the sandbox uid is killed too (`kill(-1)`, repeated until none remain), so even `setsid()`-detached processes can't outlive the run. This also ends any `kubectl exec` session in the sandbox when a run finishes
  - `RLIMIT_NPROC` 32 and `RLIMIT_AS` 192 MiB per process, enforced by gVisor
  - `tini` is PID 1 and reaps orphans, so killed processes don't linger as zombies
  - timeout capped at 60s, plus an `RLIMIT_CPU` backstop
  - stdout and stderr capped at 64 KiB each
  - request body capped at 256 KiB
  - one run at a time (409 if busy)
- The executor is **not** a security boundary. User code runs as the same uid and can kill it. Isolation comes from gVisor, the pod hardening and NetworkPolicy.
- Tests: `make executor-test` (unit, local) and `make test-executor` (in-cluster). The in-cluster test calls the executor as the agent and checks that both a pod in the `agent` namespace without the label and a labelled pod in another namespace are blocked.

## Agent (`agent/`)
A Job in the `agent` namespace. It claims a sandbox from the warm pool (Ready in ~50 ms, first run at ~210 ms; see Benchmarks), runs `TASK_CODE` through the executor, and always releases the claim, even on error. Claims also carry a 10-minute `shutdownTime` as a backstop if the agent dies. Python standard library only; it talks to the API server by IP, so it needs no DNS. No LLM yet.

The agent's fence, each part tested in `make test-agent`:
- **RBAC:** `create/get/delete` on `sandboxclaims` and `get` on `sandboxes`, in `sandboxes` only. It cannot create `Sandbox`es directly (which would bypass the hardened template), update or list claims, read pods or secrets, or exec.
- **Admission:** a `ValidatingAdmissionPolicy` for the agent's service account. Claims must name an approved warm pool and may not add pod labels/annotations, env or volumes. RBAC can grant "may create claims" but not "only safe ones": a claim's `additionalPodMetadata` could relabel the sandbox pod (labels decide which NetworkPolicies match) or annotate it (annotations can change runtime behaviour).
- **Network:** default-deny in `agent`. Egress is allowed only to the API server (`CiliumNetworkPolicy` `toEntities: kube-apiserver`) and to sandbox port 8888. Internet, cluster DNS and other sandbox ports are blocked.

## Findings so far
Each of these was a silent failure: the setup looked healthy, but a control didn't hold.

1. **gVisor sidecars.** Recent `runsc` releases need `gvisor-bin/` (e.g. `gvisor_sentry`) next to the binary. Mounting only `runsc` and the shim into the kind node fails pod creation.
2. **containerd config key.** kind node images ship a `version = 2` config. The v3 key for the runsc runtime is ignored without an error.
3. **kindnet doesn't enforce NetworkPolicy on WSL2.** Its policy engine needs `CONFIG_NFT_QUEUE`, which the stock WSL2 kernel lacks. Every rule sync fails, and all traffic flows.
4. **Cilium with iptables loses egress on WSL2.** One of its rules needs the missing `socket --transparent` module. The whole iptables reconcile aborts, including masquerade, so pods can't reach the internet at all. The fix is an eBPF-only datapath: kube-proxy replacement, BPF masquerade, `installIptablesRules: false`.
5. **agent-sandbox opens the internet by default.** Each `SandboxTemplate` gets a generated NetworkPolicy allowing egress to `0.0.0.0/0` minus private ranges. Policies are additive, so it overrode the default-deny. Found with Hubble: world SYNs `FORWARDED`, API server `DENIED`.

6. **On this cluster, Cilium sees all node-originated traffic as `world`.** The BPF IP cache maps the node's IPs to `host`, but Cilium marks host-originated packets as such with an iptables rule, which `installIptablesRules: false` removes. With default-deny ingress, kubelet `httpGet`/`tcpSocket` probes are dropped (`identity world->...` in `cilium-dbg monitor --type drop`). The sandbox now uses an `exec` readiness probe. The same will hit any default-deny namespace, including the agent's (milestone 3). Durable fix: a WSL2 kernel with `xt_socket`/TPROXY so Cilium's iptables rules install, or run on bare metal.

7. **A SandboxClaim can modify the sandbox pod's metadata.** `additionalPodMetadata` lets the claimer add labels and annotations, so "may create claims" is broader than it looks. Fenced with an admission policy (above). The template's `envVarsInjectionPolicy` and `volumeClaimTemplatesPolicy` already default to `Disallowed`.

8. **Under gVisor, the pod pids limit doesn't stop a fork bomb.** Guest processes are goroutines in gVisor's Sentry, not host tasks: during a bomb the host cgroup showed 14 of 512 pids used, with zero `pids.max` events, and the whole sandbox crashed. gVisor does enforce `RLIMIT_NPROC`, so the executor sets it. The cap must also fit the memory budget, because each forked Python copies its pages: with 256 MiB, an exponential bomb crashed the sandbox at 64 processes and was contained at 32. The count includes the executor's own threads.
9. **Host swap makes pod memory limits soft.** With swap on the host (WSL2 defaults to some), `memory.swap.max` was `max` all the way down, and a pod limited to 256 MiB wrote 1 GiB without error. kubelet's `NoSwap` only covers container cgroups, and gVisor's memory is charged at the pod level. Fix: `MemorySwapMax=0` on the node's `kubelet.slice`, which caps every pod regardless of runtime. Testing trap: `bytearray(n)` pages are lazily zero-filled and take no memory until written, so a "1 GiB allocated" result proves nothing.
10. **Under gVisor, exceeding the pod memory limit kills the whole sandbox.** One clean `MemoryError` early on was a fluke. The executor's `RLIMIT_AS` turns a single over-sized process into a `MemoryError`. Several processes, each under the cap, can still add up past the pod limit; that kills only that sandbox (demonstrated as **CONTAINED**: the other sandbox keeps serving, and the node stays Ready).
11. **An executor running as PID 1 doesn't reap orphans.** Killed processes stayed as zombies (25 after one bomb), and zombies count against `RLIMIT_NPROC`, so the next run couldn't fork at all. One fork bomb left the sandbox unusable. `tini` as PID 1 fixes it. The attack demos' health check now forks, to catch this.
12. **Killing the process group misses `setsid()`, and `kill(-1)` races with an in-flight fork.** A detached double-fork survived a single post-run `kill(-1)` under gVisor: the grandchild was created as the signal went out. The executor now repeats `kill(-1)` until nothing but itself and PID 1 is alive.

13. **The readiness probe period, not the runtime, set cold-start latency.** With only a 5s readiness probe, a cold sandbox's `Ready` was bimodal (about 3 s or 8.7 s under gVisor, 2.3 s or 7.3 s under runc), depending on where the probe tick fell, while the executor itself answered at a steady ~3.1 s / ~1.8 s. The same delay slows warm-pool refills. A 1s `startupProbe` (readiness stays at 5s) brought cold `Ready` to ~4.0 s / ~2.2 s with no long tail.
14. **Exec probes are expensive under gVisor.** The probe imported `urllib`, which opens and stats dozens of module files, the slowest path under gVisor: each probe took ~0.75 s in a 500m sandbox, every 5 s, for the sandbox's whole life. A raw-socket probe with `python -I -S` takes ~0.3 s.
15. **gVisor's "CPU overhead" on this host was a Spectre mitigation.** A pure-Python loop ran 1.6x slower under gVisor, with no syscalls in it. The kernel forces SSBD (Speculative Store Bypass Disable) on seccomp-filtered processes, and every gVisor process shows `Speculation_Store_Bypass: thread force mitigated`; runc's container seccomp filter opts out. Forcing SSBD on the runc process with `prctl` reproduced the slowdown (233 → 389 ms). SHA-256 in C was unaffected (0.99x).
16. **A tight CPU limit roughly doubles gVisor's overhead.** At 500m, syscall and file-metadata workloads were 5-10x slower than runc; with 2 CPUs, 3-5x. The Sentry's work is charged to the pod's quota alongside the user code. Benchmarks at 500m also swung by 2x between runs (CFS throttling in 100 ms periods), so the overhead comparison uses 2 CPUs.
17. **The scripts targeted whatever kubectl context was current.** Creating another kind cluster (from another project) switched the current context to it, and every `make` target here would have run there. A test run against the wrong cluster can report PASS or FAIL for controls that don't exist. The Makefile and scripts now pin `--context kind-$(CLUSTER)` (`scripts/lib.sh`).

Lesson for the verify script: always run a negative control. A pod without the policy must succeed where the sandbox is expected to fail. Otherwise "blocked" can just mean "networking is broken".

## Benchmarks (`make bench`)
An in-cluster client (its own `bench` identity in the agent namespace, same network policy as the agent; RBAC in `bench/rbac.yaml`, applied only for the run) measures:
- **Startup:** warm-pool claim vs a cold `Sandbox` from the same template, under gVisor and runc, to `Ready` and to the first successful `POST /run`. Plus a burst of 4 claims against a pool of 2.
- **Overhead:** the same workloads (CPU, syscalls, file metadata, small files, sequential I/O, process spawn, loopback TCP, interpreter start) through the executor in a gVisor and a runc sandbox built from the template.

Headline numbers (kind on WSL2, Ryzen 5 5600H; full tables and caveats in `results/benchmarks.md`):

| | gVisor | runc |
| --- | --- | --- |
| Warm claim → first run | ~210 ms | n/a |
| Cold `Sandbox` → first run | ~2.7 s | ~1.3 s |
| Claims beyond the pool size (burst) | ~3.4 s | n/a |
| Fresh Python start (every run pays it) | ~57 ms | ~18 ms |
| Syscalls / file metadata / process spawn / loopback TCP | 2.9x / 4.6x / 10.5x / 1.25x runc | 1x |

So the warm pool is worth ~2.5 s per task, and the pool must be sized for the burst: claims beyond it wait for a cold start.

## Results
See `results/`.
