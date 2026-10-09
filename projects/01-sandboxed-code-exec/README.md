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
- [x] DNS-scoped egress for sandboxes that need it: a separate `python-gvisor-pypi` template and warm pool, whose pods may resolve and reach only `pypi.org` and `files.pythonhosted.org` on 443, with the TLS SNI pinned

## Milestones
1. [x] Cluster up with gVisor; `make verify` passes (7/7, from a clean rebuild)
2. [x] Minimal executor (HTTP: run code, return stdout/stderr/exit, wall-clock timeout); `make test-executor` passes 8/8
3. [x] Agent pod (separate namespace) that claims a sandbox, runs code, releases it; `make test-agent` passes 25/25
4. [x] Attack demos showing which control stops each one; `make attack-demos` (report in `results/attack-demos.md`)
5. [x] Benchmarks: cold `Sandbox` vs warm-pool claim latency; runc vs gVisor overhead (CPU, syscall-heavy, I/O); `make bench` (report in `results/benchmarks.md`)
6. [x] DNS-scoped egress (Cilium `toFQDNs` + DNS proxy + SNI); `make test-egress` passes 13/13 plus Hubble evidence, with domain fronting reported as a known gap
7. [x] Kata Containers comparison, on WSL2 with nested KVM (`make kata`, `make verify-kata`, `make attack-demos-kata`, Kata rows in `make bench`)
8. [x] Close the remaining Must items: Pod Security enforcement (`make test-pod-security`) and claim release on every error path, plus the `shutdownTime` backstop (`make test-agent`)

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
15. **gVisor's "CPU overhead" on this host was a Spectre mitigation.** A pure-Python loop ran 1.6x slower under gVisor, with no syscalls in it. The kernel forces SSBD (Speculative Store Bypass Disable) on seccomp-filtered processes, and every gVisor process shows `Speculation_Store_Bypass: thread force mitigated`; runc's container seccomp filter opts out. Forcing SSBD on the runc process with `prctl` reproduced the slowdown (233 → 389 ms). SHA-256 in C was unaffected (0.99x). (Since 2026-10-09 the picture is reversed: runc's processes also show `thread force mitigated`, and gVisor on the KVM platform runs the loop at runc's old unmitigated speed. See finding 32 and `results/benchmarks.md`.)
16. **A tight CPU limit roughly doubles gVisor's overhead.** At 500m, syscall and file-metadata workloads were 5-10x slower than runc; with 2 CPUs, 3-5x. The Sentry's work is charged to the pod's quota alongside the user code. Benchmarks at 500m also swung by 2x between runs (CFS throttling in 100 ms periods), so the overhead comparison uses 2 CPUs.
17. **The scripts targeted whatever kubectl context was current.** Creating another kind cluster (from another project) switched the current context to it, and every `make` target here would have run there. A test run against the wrong cluster can report PASS or FAIL for controls that don't exist. The Makefile and scripts now pin `--context kind-$(CLUSTER)` (`scripts/lib.sh`). The reverse holds too: `make up` would have switched another project's sessions to this cluster, so it now has kind write a separate kubeconfig and merges it in without changing `current-context`.

18. **Under gVisor, Cilium's socket-level load balancing never sees the sandbox's sockets.** With kube-proxy replacement, Cilium translates service IPs in `connect()`/`sendmsg()` cgroup hooks. gVisor's sockets live in its own network stack, so a sandbox's packets to kube-dns left still addressed to the ClusterIP, which policy classifies as `world`: no rule naming kube-dns could ever match. Earlier "cluster DNS blocked" results held, but because the VIP was `world`, not because of the rule. Fix: `socketLB.hostNamespaceOnly: true`, so pod traffic is translated per packet at the interface.
19. **Cilium's DNS proxy enforced the allowlist, but every allowed answer timed out.** In transparent mode it forwards with the pod's source IP, and steering the reply back to the proxy needs the iptables `socket --transparent` match the WSL2 kernel lacks (the same gap as finding 4). Fix: `dnsProxy.enableTransparentMode: false`; CoreDNS then sees the node's address, not the pod's, while Hubble keeps per-pod attribution. Envoy (used for the SNI check) had the same problem: `envoy.useOriginalSourceAddress: false`.
20. **No pod in the cluster could resolve external names.** kind points the node's resolver at an address that the node's iptables DNAT to Docker's embedded DNS. Cilium's eBPF host routing skips the node's iptables, so CoreDNS's forwarded queries went to a real host that refused them. Nothing needed external DNS until now. Fix: CoreDNS forwards to `1.1.1.1`/`8.8.8.8` (`make coredns-upstream`, run by `make up`).
21. **The default `ndots:5` breaks an exact-name DNS allowlist.** `pypi.org` is first tried with each search suffix (`pypi.org.sandboxes.svc.cluster.local`, ...), and the proxy refuses those. The egress template sets `ndots:1`. Exact names, not wildcards: `*.pypi.org` would let code encode data in subdomain queries (`secret.pypi.org`) that reach the zone's authoritative servers.
22. **`toFQDNs` allows IPs, not names, and CDNs share IPs.** Through PyPI's Fastly address, a sandbox reached `www.python.org`, `www.fastly.com` and the NYT's origin. Pinning the TLS SNI (`serverNames`) stops that. But domain fronting still works: with SNI `pypi.org` and an HTTP `Host` header naming another Fastly customer, Fastly routes by the encrypted `Host`, which network policy can't see. Closing it needs TLS interception or, better, no direct internet at all: an in-cluster package mirror or egress proxy as the sandbox's only destination (P3's tool gateway). `make test-egress` reports this as `GAP GAP-01`; details and options in [docs/known-gaps.md](../../docs/known-gaps.md).

23. **Kata runs on WSL2, with one hypervisor.** The kind node sees `/dev/kvm` (nested AMD SVM), so Kata boots real VMs. QEMU can't be used: the stock WSL2 kernel has no `CONFIG_VHOST_VSOCK` for talking to the guest agent. Cloud Hypervisor implements vsock in the VMM over a Unix socket and works (`kata-clh`). Dragonball (runtime-rs) fails because it moves itself into the pod's cgroup through systemd over D-Bus, and kind's node runs no D-Bus.
24. **Neither runtime applied the pod's seccomp profile to user code.** Kata's default `disable_guest_seccomp = true` skips `RuntimeDefault` in the guest (`Seccomp: 0`, and `add_key` worked against the guest kernel). Fixed: `disable_guest_seccomp = false`. gVisor doesn't load OCI seccomp in the sandbox either, by design: its Sentry implements the syscalls and is itself seccomp-confined on the host.
25. **A pod annotation could change the Kata guest's kernel command line.** The default allows `io.katacontainers.config.hypervisor.kernel_params`. Disabled (`enable_annotations = []`); the claim admission policy (finding 7) already blocks annotations from the agent.
26. **By default the Kata VM ran outside every host resource limit.** With `sandbox_cgroup_only = false`, the VMM landed in a cgroup at the root of the hierarchy (kind's systemd-style cgroup path, created literally), with no memory, CPU, pids or swap limit, while the pod's own cgroup sat empty. The node's swap-off (finding 9) didn't cover it either. Fixed: `sandbox_cgroup_only = true`; `make verify-kata` checks every VMM is under `kubelet.slice`.
27. **With the VM inside the pod's cgroup, Kata's defaults got it OOM-killed.** The default VM has a 2 GiB base plus the container limit hot-plugged, against a declared overhead of 130 MiB. The guest never felt memory pressure, and the host OOM-killed the whole VM during the single-process memory bomb. Fixed: 256 MiB base and a 320 MiB RuntimeClass overhead, so the guest's own limits act first.
28. **Memory containment is finer-grained under Kata.** The multi-process memory bomb that kills a gVisor sandbox is handled inside the Kata guest: its kernel OOM-kills individual processes (5 of 8) and the sandbox keeps serving. As under gVisor, the pod pids limit doesn't reach guest processes (the guest cgroup's `pids.max` is `max`), so the executor's `RLIMIT_NPROC` still stops fork bombs. `kubectl exec` sessions in a Kata guest lack `no_new_privs`; the executor and user code have it.

29. **A clean rebuild depended on large downloads surviving the network.** Pulls of `python:3.13-slim` and of `kata-deploy` (one 1.7 GiB layer) failed with `connection reset by peer` and minute-long stalls, inside the node and on the host alike, and the rebuild carried on with half its suites failing. quay.io itself was up. A packet capture showed why: the reset arrived with TTL 63, one hop past the Windows host, i.e. from the home router's NAT, while the server's packets arrived with TTL 55-58. Docker and containerd restart a failed layer from zero, so a layer needing minutes on one connection never finished. `scripts/fetch_image.py` (used by `make p1` and `make kata`) downloads each blob with HTTP Range requests, resuming after every reset or stall, verifies its sha256, caches it across rebuilds, and imports only this platform's manifest into the node. The 1.7 GiB layer took 12 minutes and 13 resumes. (`kind load docker-image` was no way round it: it imports with `--all-platforms`, which fails for multi-arch images when Docker holds only this host's platform.)

30. **The agent ignored SIGTERM and leaked its claim when its pod was deleted.** It runs as PID 1, and the kernel applies no default action to signals sent to PID 1 without a handler. So `kubectl delete pod` (or a Job being cancelled, or a node drain) waited out the 30s grace period, SIGKILLed the agent, and its `finally: release()` never ran. The claim, and a whole sandbox, then lingered until the 10-minute `shutdownTime`. The agent now turns SIGTERM into `SystemExit`, which runs the release: the pod is gone in 2s and the claim with it. `make test-agent` deletes an agent pod mid-run to check.
31. **A Pod Security test can pass for the wrong reason.** `privileged: true` with `allowPrivilegeEscalation: false` is rejected by plain validation before PodSecurity sees it, so a "privileged pod denied" check passed without testing the policy. The suite now asserts the denial comes from PodSecurity, as the claim admission tests do (finding 7).
32. **gVisor's default platform stopped working after a WSL restart; sandboxes now run on its KVM platform.** On 2026-10-09 WSL was restarted after a `.wslconfig` change made for other work on the same WSL (mirrored networking, memory, swap and CPU settings). From then on no gVisor sandbox could start: `runsc` panicked with `failed to create a syscall thread` in systrap's first stub thread (`initSyscallThread`), reproduced outside Kubernetes with `runsc do /bin/true` on the node. The runsc package, the kernel, the sysctls and the CPU flags were unchanged, and the `ptrace` and `kvm` platforms worked. Which `.wslconfig` setting caused it is untested (reverting would disturb the other work). The node now runs gVisor with `platform = "kvm"` (`cluster/runsc.toml`, wired in by `make node-gvisor-platform`, which `make up` runs). KVM here is nested virtualization (WSL2 is itself a VM), as for Kata. The broken sandboxes also left their pods stuck terminating, with runsc shims containerd couldn't stop; they had to be killed by hand. See `docs/host-requirements.md`.
33. **The KVM platform costs more host memory per sandbox, which broke two attack demos.** An idle gVisor sandbox uses ~135 MiB of host memory under KVM, and each guest process ~4.5 MiB more (measured from the pod's cgroup while forking 4 to 24 processes). With the template's 256 MiB, the fork bomb (capped at 32 processes, finding 18) and the single-process memory bomb (capped at 192 MB) went over the limit, and the kernel OOM-killed the whole sandbox, where under systrap they failed inside it. The limit is now 384 MiB (request 160 MiB), and both are contained again (`make attack-demos`). The Kata template is unchanged: its VM has its own sizing (finding 27).
34. **Changing a SandboxTemplate doesn't change an existing warm pool.** The pool's `Sandbox` objects keep the pod spec they were created with, and deleting their pods just recreates them from it. After the memory change, the pool kept serving 256 MiB sandboxes until its unclaimed `Sandbox` objects were deleted, after which it created new ones from the template. Roll a pool after any template change.
35. **The benchmark identity was an "agent" too.** The bench client ran as `agent/bench`, in the agent namespace to share the agents' route to the executors. Once the write guard, claim policy and kill switch matched every service account in that namespace (P3 milestone 1), they refused its Sandbox creation, with HTTP 422 (a ValidatingAdmissionPolicy's default reason is `Invalid`). The benchmarks hadn't run since. The bench now runs in its own namespace, created and removed per run, with a run-scoped rule to reach the executors; exempting it from the guard would have made one service account in the agent namespace unguarded.

Lesson for the verify script: always run a negative control. A pod without the policy must succeed where the sandbox is expected to fail. Otherwise "blocked" can just mean "networking is broken".

## Benchmarks (`make bench`)
An in-cluster client (its own `bench` identity in a `bench` namespace with the agents' route to the executors; namespace, RBAC and that route in `bench/rbac.yaml`, applied only for the run) measures:
- **Startup:** warm-pool claim vs a cold `Sandbox` from the same template, under gVisor and runc, to `Ready` and to the first successful `POST /run`. Plus a burst of 4 claims against a pool of 2.
- **Overhead:** the same workloads (CPU, syscalls, file metadata, small files, sequential I/O, process spawn, loopback TCP, interpreter start) through the executor in a gVisor and a runc sandbox built from the template.

Headline numbers (kind on WSL2, Ryzen 5 5600H, overhead at 2 CPUs, gVisor on its KVM platform since 2026-10-09; full tables and caveats in `results/benchmarks.md`):

| | gVisor (KVM) | Kata (CLH) | runc |
| --- | --- | --- | --- |
| Warm claim → first run | ~200 ms | ~150 ms | n/a |
| Cold `Sandbox` → first run | ~2.9 s | ~4.9 s | ~2.3 s |
| Claims beyond the pool size (burst, gVisor) | ~5.7-6.0 s | | n/a |
| Fresh Python start (every run pays it) | ~46 ms | ~74 ms | ~34 ms |
| Syscalls / file metadata / process spawn / loopback TCP, vs runc | 3.4x / 8.9x / 4.9x / 1.1x | 0.4x / 0.4x / 9.1x / 0.3x | 1x |
| Small files / sequential read on `/tmp`, vs runc | 2.7x / 1.4x | 13.4x / 4.5x (virtio-fs) | 1x |

So the warm pool is worth ~2.7 s per task under gVisor and ~4.8 s under Kata, and the pool must be sized for the burst: claims beyond it wait for a cold start.

Since the 2026-10-09 host restart, two things changed at once, so ratios aren't comparable with earlier runs: gVisor moved from systrap to KVM (finding 32), and runc containers now run with SSBD forced like every other process on the node (finding 15 described them opting out), which slowed runc's own CPU-bound and start-up times. In absolute terms under KVM, gVisor's syscalls and file metadata got slower (VM exits under nested virtualization: `stat` ~2x), and process creation, interpreter start and the agent's round trip got faster (~2x). Under systrap the table read: warm first run ~270 ms, fresh Python ~90 ms, syscalls / metadata / spawn 2.8x / 4.9x / 10.4x vs an unmitigated runc.

## DNS-scoped egress (`make test-egress`)
Sandboxes get no egress by default. A task that needs packages claims from the `python-gvisor-pypi` warm pool instead (approved in the agent's admission policy). Its template is the default one plus a pod label, set by the operator (claims can't add labels), that `65-networkpolicy-egress-pypi.yaml` selects:
- DNS only to kube-dns, through Cilium's DNS proxy, which answers only `pypi.org` and `files.pythonhosted.org` and refuses everything else.
- TCP 443 only to IPs the proxy has seen for those names (`toFQDNs`), and only with a matching TLS SNI.

`make test-egress` probes through the executor from an agent-identity pod: allowed lookups, HTTPS and a real `pip install` work; other names (including subdomain exfiltration), direct DNS to public resolvers, other IPs, other ports and other SNIs on the same CDN address are blocked; a default-pool sandbox, as a negative control, can do none of it. Hubble shows the proxy's refusals independently.

## Kata Containers (`make kata`)
Optional, installed after `make p1`: the upstream `kata-deploy` chart with Cloud Hypervisor only (`cluster/kata-values.yaml`), plus a `python-kata` template and warm pool (`manifests/kata/`, the same hardened template with `runtimeClassName: kata-clh`). Each sandbox is a VM with its own guest kernel. The configuration changes four defaults (findings 24-27): guest seccomp on, no hypervisor annotations, the whole sandbox in the pod's cgroup, and the VM sized to fit the pod's declared overhead.

- `make verify-kata`: the hardening checks plus guest kernel, guest seccomp, and VMM cgroup placement.
- `make attack-demos-kata`: the same attacks, report in `results/attack-demos-kata.md`.
- `make bench` adds Kata rows when the RuntimeClass exists.

## Results
See `results/`.
