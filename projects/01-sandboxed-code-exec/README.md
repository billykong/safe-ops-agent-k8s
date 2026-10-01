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
- [ ] Executor service inside the sandbox, with ingress opened only from the agent pod
- [ ] Cilium DNS-scoped egress for tasks that need it

## Milestones
1. [x] Cluster up with gVisor; `make verify` passes (7/7, from a clean rebuild)
2. [ ] Minimal executor (HTTP: run code, return stdout/stderr/exit, wall-clock timeout)
3. [ ] Agent pod (separate namespace) that claims a sandbox, runs code, releases it
4. [ ] Fork-bomb and egress-exfil demos showing which control stops each one
5. [ ] Benchmarks: cold `Sandbox` vs warm-pool claim latency; runc vs gVisor overhead (CPU, syscall-heavy, I/O)

## Findings so far
Each of these was a silent failure: the setup looked healthy, but a control didn't hold.

1. **gVisor sidecars.** Recent `runsc` releases need `gvisor-bin/` (e.g. `gvisor_sentry`) next to the binary. Mounting only `runsc` and the shim into the kind node fails pod creation.
2. **containerd config key.** kind node images ship a `version = 2` config. The v3 key for the runsc runtime is ignored without an error.
3. **kindnet doesn't enforce NetworkPolicy on WSL2.** Its policy engine needs `CONFIG_NFT_QUEUE`, which the stock WSL2 kernel lacks. Every rule sync fails, and all traffic flows.
4. **Cilium with iptables loses egress on WSL2.** One of its rules needs the missing `socket --transparent` module. The whole iptables reconcile aborts, including masquerade, so pods can't reach the internet at all. The fix is an eBPF-only datapath: kube-proxy replacement, BPF masquerade, `installIptablesRules: false`.
5. **agent-sandbox opens the internet by default.** Each `SandboxTemplate` gets a generated NetworkPolicy allowing egress to `0.0.0.0/0` minus private ranges. Policies are additive, so it overrode the default-deny. Found with Hubble: world SYNs `FORWARDED`, API server `DENIED`.

Lesson for the verify script: always run a negative control. A pod without the policy must succeed where the sandbox is expected to fail. Otherwise "blocked" can just mean "networking is broken".

## Results
See `results/`.
