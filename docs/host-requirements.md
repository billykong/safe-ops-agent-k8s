# Host requirements

The cluster runs in kind on WSL2, on a host that's also used for other work. These are the host settings it depends on, and what to re-check after changing any WSL setting or restarting WSL.

## WSL (`%UserProfile%\.wslconfig`, `/etc/wsl.conf`)

| Setting | Needed for | Notes |
| --- | --- | --- |
| systemd (`[boot] systemd=true` in `/etc/wsl.conf`) | Docker Engine | |
| cgroup v2 only (`kernelCommandLine = cgroup_no_v1=all`) | kubelet, the node's swap limit (P1 finding 9) | |
| Nested virtualization (`/dev/kvm` visible in WSL) | Kata (P1 M7), gVisor's KVM platform (P1 finding 32) | Default on recent Windows 11 with an AMD SVM or Intel VT-x CPU |
| Memory, swap, processors | Headroom: WSL used ~6.4 GB in total with the cluster running (2026-10-09), more while Kata VMs and benchmarks run | Current: 16 GB, 16 GB swap, 8 processors. Pods don't swap whatever the host has (P1 finding 9) |
| Networking mode | kind's port mappings on 127.0.0.1, pod egress | Works under `mirrored` (current) and NAT |

## Packages on the WSL host

Docker Engine and gVisor (`runsc` 20260928.0) from `scripts/setup-host.sh`. The node mounts the host's `runsc` binaries read-only (`cluster/kind-gvisor.yaml`), so a `runsc` upgrade on the host changes the cluster's sandbox runtime.

## After a WSL restart or a `.wslconfig` change

The kind node container may not restart on its own. It came back `Exited (128)` twice. The second time (2026-10-10), `docker inspect` showed why: Docker's restart at boot failed to create the container's systemd scope (`unable to start unit "docker-<id>.scope" ... got failed`), probably because systemd wasn't ready yet. A manual start a few minutes later worked, and the gVisor KVM platform still worked after it. Then:

```bash
docker start safe-ops-control-plane
```

Then check that each runtime still starts sandboxes, in this order:

```bash
make verify            # gVisor: claims a sandbox and checks it
make verify-kata       # Kata, if installed
make attack-demos      # sandboxes survive the attacks
```

If gVisor sandboxes stay in `ContainerCreating`, run `runsc` directly on the node to see why:

```bash
docker exec safe-ops-control-plane runsc --network=none do /bin/true
```

Add `--platform=ptrace` or `--platform=kvm` to compare platforms. That's how the systrap failure of 2026-10-09 was found (P1 finding 32): after a `.wslconfig` change, systrap failed, and the node moved to the KVM platform.
