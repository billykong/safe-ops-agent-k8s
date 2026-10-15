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

## The GPU (P5)

| What | Needed for | Notes |
| --- | --- | --- |
| NVIDIA driver on Windows with WSL support (`/dev/dxg`, `/usr/lib/wsl`) | The local model server (`make p5`) | 566.07 (CUDA 12.7) on 2026-10-11. CUDA 13 builds need 580 or later |
| No NVIDIA container toolkit | | Not installed: `scripts/model-server.sh` maps `/dev/dxg` and `/usr/lib/wsl` itself. If you install it, generate its CDI spec (`/etc/cdi/nvidia.yaml`) and the script uses `--gpus all` (untested here). Keep it patched (P5-09) |
| Docker network `safe-ops-models` (172.30.99.0/28, internal) | The server's network; the kind node joins it as `eth1` | Created by `make p5`. Pick another subnet if it collides with your LAN |

The Docker server holds about 3.2 GB of the GPU's 4 GB while it runs. In the cluster (P5 M3) each replica holds about 1.5 GB, and KEDA runs one or two (the GPU is time-sliced in three: two slices for vLLM, one for the DCGM metrics exporter, which takes no GPU memory and about 400 MiB of host memory); two replicas take about 6 GB of host memory. `make model-server-down` frees the GPU from the Docker server. In the cluster, pause KEDA at zero (scaling the Deployment alone doesn't hold: KEDA scales it back):

```bash
kubectl --context kind-safe-ops -n inference annotate scaledobject local-model autoscaling.keda.sh/paused-replicas=0 --overwrite
```

`scripts/local-model-mode.sh cluster` unpauses it.

In cluster mode the kind node holds a copy of the WSL driver (`/usr/lib/wsl`, about 2 GB) and `nvidia-cdi-hook` (`scripts/node-gpu.sh`). A Windows NVIDIA driver update leaves the copy stale: run `scripts/node-gpu.sh` again, then restart the device plugin (`kubectl -n gpu-system rollout restart ds/nvdp-nvidia-device-plugin`). The server image (15 GB) is stored twice: in Docker and in the node's containerd.

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
make p5                # the local model server, if you use it: it doesn't restart on its own
```

If gVisor sandboxes stay in `ContainerCreating`, run `runsc` directly on the node to see why:

```bash
docker exec safe-ops-control-plane runsc --network=none do /bin/true
```

Add `--platform=ptrace` or `--platform=kvm` to compare platforms. That's how the systrap failure of 2026-10-09 was found (P1 finding 32): after a `.wslconfig` change, systrap failed, and the node moved to the KVM platform.

If pods can't reach each other after the restart (on 2026-10-14 the agent worker crash-looped, timing out on Temporal at port 7233), check Cilium's IP cache. That time, every pod IP was listed as `reserved:unmanaged`, so policy dropped all pod-to-pod traffic (`cilium-dbg monitor --type drop` showed `Policy denied ... ->unmanaged`). Restarting the Cilium agent rebuilt the cache; then restart any pod still in a crash-loop backoff:

```bash
kubectl --context kind-safe-ops -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg ip list | grep unmanaged
kubectl --context kind-safe-ops -n kube-system rollout restart ds/cilium
```
