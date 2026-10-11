# vLLM 0.30.0 for CUDA 12.9, repaired. The host's driver (566.07) supports
# CUDA 12.7, so the default (CUDA 13) images can't run; CUDA 12's
# minor-version compatibility runs a 12.9 build. But the v0.30.0-cu129
# image ships torch 2.14.0+cu130 beside torchvision 0.28.0+cu129, so
# torchvision's native ops don't load and vLLM exits on import
# ("operator torchvision::nms does not exist"). Put back the torch it was
# built against, pinned by hash.
FROM vllm/vllm-openai@sha256:a67f8f186d4567612ac37a55bd82295006002b18858eb12a8af2f05f86c2ae3f
COPY requirements-torch.txt /tmp/requirements-torch.txt
RUN pip install --no-cache-dir --no-deps --require-hashes --index-url https://download.pytorch.org/whl/cu129 \
      -r /tmp/requirements-torch.txt \
 && python3 -c "import torch, torchvision; assert torch.version.cuda == '12.9', torch.version.cuda; torchvision.ops.nms" \
 && rm /tmp/requirements-torch.txt
