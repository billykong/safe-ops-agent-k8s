# 01 - Sandboxed code-execution agent

## Goal
The agent loop and the code sandbox run in separate pods. The sandbox has no credentials, no GPU and no route to the agent, model gateway or API server.

## Hardening (in `manifests/`)
- [x] `runtimeClassName: gvisor` (runsc)
- [x] Namespace at Pod Security `restricted`
- [x] Default-deny NetworkPolicy, ingress and egress
- [x] No service-account token, non-root, read-only rootfs, drop all caps, seccomp RuntimeDefault
- [x] CPU, memory and ephemeral-storage limits
- [x] Pids limit (`podPidsLimit: 512` in the kind kubelet config)
- [ ] Executor service inside the sandbox, with ingress opened only from the agent pod
- [ ] Cilium DNS-scoped egress for tasks that need it

## Milestones
1. [ ] Cluster up with gVisor; `make verify` passes
2. [ ] Minimal executor (HTTP: run code, return stdout/stderr/exit, wall-clock timeout)
3. [ ] Agent pod (separate namespace) that claims a sandbox, runs code, releases it
4. [ ] Fork-bomb and egress-exfil demos showing which control stops each one
5. [ ] Benchmarks: cold `Sandbox` vs warm-pool claim latency; runc vs gVisor overhead (CPU, syscall-heavy, I/O)

## Results
See `results/`.
