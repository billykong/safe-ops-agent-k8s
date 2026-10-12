#!/usr/bin/env bash
# The GPU inside the kind node (P5 M2). On WSL2 the GPU is /dev/dxg, which
# the node (a privileged container) already sees, and the driver is
# /usr/lib/wsl on the host: lib/ (libcuda.so, libnvidia-ml.so.1, ...)
# and the NVIDIA folder of the Windows driver store, drivers/nv*.inf_*,
# which libcuda.so loads the real driver from. This copies those two into
# the node at the same paths, read-only, where the device plugin finds
# them (driver root /) and puts them in the CDI spec it generates.
#
# Then, in the node:
# - /usr/lib/wsl/lib goes in the library cache (/etc/ld.so.conf.d, as WSL
#   distros do), or nvidia-ctk and the plugin don't detect WSL;
# - nvidia-cdi-hook from the NVIDIA container toolkit image (pinned), which
#   the CDI spec's hooks run: it updates a GPU container's library cache;
# - label nvidia.com/gpu.present=true, which the device plugin's DaemonSet
#   selects on (WSL2 has no PCI device for feature discovery to find).
#
# Copied, not mounted: a mount needs the node recreated (kind config
# extraMounts), and so the whole cluster. The copy stays in the node
# container across restarts. A Windows driver update changes the
# driver-store folder's name: run this again (idempotent; it compares).
#   scripts/node-gpu.sh          copy (or refresh) the driver into the node
#   scripts/node-gpu.sh status
set -euo pipefail
cd "$(dirname "$0")/.."
NODE=${CLUSTER:-safe-ops}-control-plane
SRC=/usr/lib/wsl
# nvidia-cdi-hook comes from this image; keep it patched (P5-09).
TOOLKIT=nvcr.io/nvidia/k8s/container-toolkit:v1.20.1@sha256:00a422252dd875b112f5974321c2feebbdf11c338f8ad131e5ce18e5b3a3bfac
HOOK=/usr/local/nvidia-toolkit/bin/nvidia-cdi-hook

[ -e /dev/dxg ] || { echo "no /dev/dxg: not WSL2 with a GPU" >&2; exit 1; }
STORE=$(cd $SRC/drivers && for d in nv*.inf_amd64_*; do [ -e "$d/libcuda.so.1.1" ] && echo "$d"; done; true)
[ "$(wc -w <<<"$STORE")" = 1 ] || { echo "expected one NVIDIA driver-store folder with libcuda, found: ${STORE:-none}" >&2; exit 1; }

# A fingerprint of what's on the host, to skip an unchanged copy.
fingerprint() { (cd $SRC && find lib "drivers/$STORE" -type f -printf '%P %s %T@\n' | sort | sha256sum | cut -c1-16); }
want=$(fingerprint)
have=$(docker exec "$NODE" cat /usr/lib/wsl/.safe-ops-fingerprint 2>/dev/null || true)

case "${1:-copy}" in
  status)
    echo "host driver: drivers/$STORE ($want)"
    echo "node copy:   ${have:-none}$([ "$have" = "$want" ] && echo ' (current)' || echo ' (stale or missing)')"
    docker exec "$NODE" ls -la /dev/dxg
    docker exec "$NODE" "$HOOK" --version 2>/dev/null | head -1 || echo "no $HOOK" ;;
  copy)
    if [ "$have" = "$want" ]; then echo "node $NODE: driver current (drivers/$STORE)"; else
    echo "copying the WSL GPU driver into $NODE: lib/ and drivers/$STORE (about 2 GB)"
    docker exec "$NODE" sh -c 'rm -rf /usr/lib/wsl && mkdir -p /usr/lib/wsl/drivers'
    docker cp "$SRC/lib" "$NODE:/usr/lib/wsl/lib"
    docker cp "$SRC/drivers/$STORE" "$NODE:/usr/lib/wsl/drivers/$STORE"
    docker exec "$NODE" sh -c "chown -R root:root /usr/lib/wsl && chmod -R a-w /usr/lib/wsl/lib /usr/lib/wsl/drivers && echo $want > /usr/lib/wsl/.safe-ops-fingerprint"
    echo "node $NODE: driver copied (drivers/$STORE)"; fi
    docker exec "$NODE" sh -c 'echo /usr/lib/wsl/lib > /etc/ld.so.conf.d/ld.wsl.conf && ldconfig'
    want_hook=$(docker run --rm --entrypoint sha256sum "$TOOLKIT" /artifacts/deb/usr/bin/nvidia-cdi-hook | cut -d' ' -f1)
    if [ "$(docker exec "$NODE" sha256sum "$HOOK" 2>/dev/null | cut -d' ' -f1)" != "$want_hook" ]; then
      tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
      docker run --rm --user "$(id -u):$(id -g)" -v "$tmp:/out" --entrypoint cp "$TOOLKIT" /artifacts/deb/usr/bin/nvidia-cdi-hook /out/
      docker exec "$NODE" mkdir -p "$(dirname "$HOOK")"
      docker cp "$tmp/nvidia-cdi-hook" "$NODE:$HOOK"
    fi
    echo "node $NODE: $(docker exec "$NODE" "$HOOK" --version | head -1)"
    kubectl --context "kind-${CLUSTER:-safe-ops}" label node "$NODE" nvidia.com/gpu.present=true --overwrite >/dev/null ;;
  *) echo "usage: $0 [copy|status]" >&2; exit 2 ;;
esac
