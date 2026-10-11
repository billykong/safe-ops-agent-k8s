# P5 - Self-hosted inference on the local GPU

**Goal:** learn the model-serving plumbing on Kubernetes, and provide a cheap local model as classifier, guard, eval judge and red-team target. The agent's main model stays a hosted API.

Status: **milestone 1 done**: a local model served outside the cluster with Docker on the host's GPU, reached through the LLM gateway only, and used as an eval judge. Runs alongside P4. Built in [projects/05-local-inference/](../../../projects/05-local-inference/README.md).

## Hardware and its limits

The lab machine has an **RTX 3050 Laptop GPU (4 GB VRAM)**, with 8 cores and 15 GB RAM in WSL2.

- **What fits:** 0.5-1.5B instruct models at FP16, or ~3B with 4-bit AWQ/GPTQ, with small context windows. Enough to learn serving; not enough for a capable agent model.
- **WSL2 caveat:** the GPU is exposed through `/dev/dxg`, not `/dev/nvidia*`. The device plugin and GPU operator assume a native driver and may not work.
- **Driver:** 566.07 on Windows, CUDA 12.7. CUDA 12.x builds run (minor-version compatibility); CUDA 13 builds need driver 580 or later.
- **Measured (M1):** Qwen2.5-1.5B-Instruct AWQ in vLLM takes 1.1 GB for weights, and 3.2 GB in all at `--gpu-memory-utilization 0.8` with a 4096-token context; about 3 GB of host memory.

## Requirements

| ID | Requirement | Priority | Status |
| --- | --- | --- | --- |
| P5-01 | Serve a small model with Ollama/llama.cpp, then vLLM (compute capability 8.6), with `--gpu-memory-utilization` and `--max-model-len` set low. | Must | **Partial** (M1): vLLM 0.30 serves Qwen2.5-1.5B-Instruct AWQ on the GPU at 0.8 and 4096 (`make test-local-model`). Ollama and llama.cpp skipped: they load GGUF, and P5-08 allows only verified safetensors |
| P5-02 | Fallback path: run vLLM in Docker (`--gpus all`) outside the cluster and call it from the cluster, if in-cluster GPU fails on WSL2. | Must | **Done** (M1): `scripts/model-server.sh`, on an internal Docker network only the cluster's node joins; the cluster calls it through the LLM gateway. The GPU is mapped as `/dev/dxg` plus `/usr/lib/wsl`, since Docker 29's `--gpus` needs the NVIDIA toolkit's CDI spec; `--gpus all` is used when that exists |
| P5-03 | In-cluster GPU via the NVIDIA container toolkit and device plugin (`nvidia.com/gpu`), trying k3s on WSL2 first and bare metal if needed. | Should | Planned |
| P5-04 | Time-slicing so two pods share one GPU. | Could | Planned |
| P5-05 | Serving stack behind the Gateway API Inference Extension (or KServe/llm-d), with autoscaling on queue depth. | Should | Planned |
| P5-06 | GPU metrics via DCGM exporter, or `nvidia-smi` fallback if DCGM doesn't support the card. | Should | Planned |
| P5-07 | The model server has no auth of its own, so NetworkPolicy allows only the LLM gateway to reach it. | Must | **Done** (M1): a clusterwide Cilium deny for every pod outside `gateways`, and an allow for the gateway only; the suite's negative controls (a pod in a namespace with no policy, in `agent`, and one wearing the gateway's labels) can't connect. Also a bearer key only the gateway mounts. The node and host-network pods are outside pod policy ([GAP-09](../../known-gaps.md#gap-09-the-node-can-reach-the-local-model-server)) |
| P5-08 | Weights load only as hash-verified `safetensors`; never `--trust-remote-code`. | Must | **Done** (M1): a lock pins the revision and every file's SHA-256, verified at fetch and before every start; a changed byte, an extra file or a config asking for remote code is refused. `--load-format safetensors`, offline, mounted read-only, no `--trust-remote-code` |
| P5-09 | GPU access never via `privileged: true`; the code sandbox never gets a GPU; the NVIDIA toolkit stays patched (it has had container-escape CVEs, e.g. CVE-2024-0132, CVE-2025-23266). | Must | **Partial** (M1): the server isn't privileged, drops all capabilities, has a read-only root and only the GPU's device; the NVIDIA toolkit isn't installed, so there's none to patch. The sandbox and the in-cluster GPU are M2 |
| P5-10 | The local model is used for at least one of: guard/classifier, eval judge (P4), deliberately weak red-team target (P3). | Must | **Done** (M1): eval judge, `JUDGE_MODEL=qwen2.5-1.5b-instruct scripts/eval-run.sh`; every scenario judged through the gateway as the evaluator. It agreed with the checks on 5 of 8 and passed the injection scenario the checks fail, so it's a second opinion that can only lower a score, not the merge gate's judge |

## Acceptance

A local model serves requests from inside the cluster only through the LLM gateway. A pod outside the gateway is blocked (negative control). P4's eval suite or P3's red-team uses it. Whether GPU scheduling worked on WSL2 or needed bare metal is documented.

Status: the first three hold for the out-of-cluster server (milestone 1, `make test-local-model`). GPU scheduling inside the cluster is milestone 2.
