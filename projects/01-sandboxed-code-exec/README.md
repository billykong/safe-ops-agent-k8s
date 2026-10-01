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
- [x] Pids limit (`podPidsLimit: 512` in the kind kubelet config)
- [x] Executor service inside the sandbox, with ingress opened only from `app=agent` pods in the `agent` namespace
- [ ] Cilium DNS-scoped egress for tasks that need it

## Milestones
1. [x] Cluster up with gVisor; `make verify` passes (7/7, from a clean rebuild)
2. [x] Minimal executor (HTTP: run code, return stdout/stderr/exit, wall-clock timeout); `make test-executor` passes 8/8
3. [ ] Agent pod (separate namespace) that claims a sandbox, runs code, releases it
4. [ ] Fork-bomb and egress-exfil demos showing which control stops each one
5. [ ] Benchmarks: cold `Sandbox` vs warm-pool claim latency; runc vs gVisor overhead (CPU, syscall-heavy, I/O)

## Executor (`executor/`)
Standard library only, built as `sandbox-executor:dev` and loaded into kind (`make executor-image`, run by `make p1`).

- `POST /run {"code": "...", "timeout_s": 10}` returns `{stdout, stderr, exit_code, timed_out, duration_ms, truncated}`.
- `GET /healthz`.
- Limits:
  - the code runs in its own process group, which is SIGKILLed on timeout or exit, so background children can't outlive the run
  - timeout capped at 60s, plus an `RLIMIT_CPU` backstop
  - stdout and stderr capped at 64 KiB each
  - request body capped at 256 KiB
  - one run at a time (409 if busy)
- The executor is **not** a security boundary. User code runs as the same uid and can kill it. Isolation comes from gVisor, the pod hardening and NetworkPolicy.
- Tests: `make executor-test` (unit, local) and `make test-executor` (in-cluster). The in-cluster test calls the executor as the agent and checks that both a pod in the `agent` namespace without the label and a labelled pod in another namespace are blocked.

## Findings so far
Each of these was a silent failure: the setup looked healthy, but a control didn't hold.

1. **gVisor sidecars.** Recent `runsc` releases need `gvisor-bin/` (e.g. `gvisor_sentry`) next to the binary. Mounting only `runsc` and the shim into the kind node fails pod creation.
2. **containerd config key.** kind node images ship a `version = 2` config. The v3 key for the runsc runtime is ignored without an error.
3. **kindnet doesn't enforce NetworkPolicy on WSL2.** Its policy engine needs `CONFIG_NFT_QUEUE`, which the stock WSL2 kernel lacks. Every rule sync fails, and all traffic flows.
4. **Cilium with iptables loses egress on WSL2.** One of its rules needs the missing `socket --transparent` module. The whole iptables reconcile aborts, including masquerade, so pods can't reach the internet at all. The fix is an eBPF-only datapath: kube-proxy replacement, BPF masquerade, `installIptablesRules: false`.
5. **agent-sandbox opens the internet by default.** Each `SandboxTemplate` gets a generated NetworkPolicy allowing egress to `0.0.0.0/0` minus private ranges. Policies are additive, so it overrode the default-deny. Found with Hubble: world SYNs `FORWARDED`, API server `DENIED`.

6. **On this cluster, Cilium sees all node-originated traffic as `world`.** The BPF IP cache maps the node's IPs to `host`, but Cilium marks host-originated packets as such with an iptables rule, which `installIptablesRules: false` removes. With default-deny ingress, kubelet `httpGet`/`tcpSocket` probes are dropped (`identity world->...` in `cilium-dbg monitor --type drop`). The sandbox now uses an `exec` readiness probe. The same will hit any default-deny namespace, including the agent's (milestone 3). Durable fix: a WSL2 kernel with `xt_socket`/TPROXY so Cilium's iptables rules install, or run on bare metal.

Lesson for the verify script: always run a negative control. A pod without the policy must succeed where the sandbox is expected to fail. Otherwise "blocked" can just mean "networking is broken".

## Results
See `results/`.
