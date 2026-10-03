# P5 - Self-hosted inference on the local GPU

**Goal:** learn the model-serving plumbing on Kubernetes, and provide a cheap local model as classifier, guard, eval judge and red-team target. The agent's main model stays a hosted API.

Status: **not started**. Runs alongside P4.

## Hardware and its limits

The lab machine has an **RTX 3050 Laptop GPU (4 GB VRAM)**, with 8 cores and 15 GB RAM in WSL2.

- **What fits:** 0.5-1.5B instruct models at FP16, or ~3B with 4-bit AWQ/GPTQ, with small context windows. Enough to learn serving; not enough for a capable agent model.
- **WSL2 caveat:** the GPU is exposed through `/dev/dxg`, not `/dev/nvidia*`. The device plugin and GPU operator assume a native driver and may not work.

## Requirements

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P5-01 | Serve a small model with Ollama/llama.cpp, then vLLM (compute capability 8.6), with `--gpu-memory-utilization` and `--max-model-len` set low. | Must | Planned |
| P5-02 | Fallback path: run vLLM in Docker (`--gpus all`) outside the cluster and call it from the cluster, if in-cluster GPU fails on WSL2. | Must | Planned |
| P5-03 | In-cluster GPU via the NVIDIA container toolkit and device plugin (`nvidia.com/gpu`), trying k3s on WSL2 first and bare metal if needed. | Should | Planned |
| P5-04 | Time-slicing so two pods share one GPU. | Could | Planned |
| P5-05 | Serving stack behind the Gateway API Inference Extension (or KServe/llm-d), with autoscaling on queue depth. | Should | Planned |
| P5-06 | GPU metrics via DCGM exporter, or `nvidia-smi` fallback if DCGM doesn't support the card. | Should | Planned |
| P5-07 | The model server has no auth of its own, so NetworkPolicy allows only the LLM gateway to reach it. | Must | Planned |
| P5-08 | Weights load only as hash-verified `safetensors`; never `--trust-remote-code`. | Must | Planned |
| P5-09 | GPU access never via `privileged: true`; the code sandbox never gets a GPU; the NVIDIA toolkit stays patched (it has had container-escape CVEs, e.g. CVE-2024-0132, CVE-2025-23266). | Must | Planned |
| P5-10 | The local model is used for at least one of: guard/classifier, eval judge (P4), deliberately weak red-team target (P3). | Must | Planned |

## Acceptance

A local model serves requests from inside the cluster only through the LLM gateway. A pod outside the gateway is blocked (negative control). P4's eval suite or P3's red-team uses it. Whether GPU scheduling worked on WSL2 or needed bare metal is documented.
