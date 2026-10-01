#!/usr/bin/env bash
# One-time host setup for WSL2 (Ubuntu 24.04): Docker Engine + gVisor (runsc).
# Run with: sudo ./scripts/setup-host.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "run with sudo" >&2
  exit 1
fi
TARGET_USER="${SUDO_USER:?run via sudo so the invoking user can be added to the docker group}"

apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings

# Docker Engine (official repo)
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

# gVisor (installs /usr/bin/runsc and /usr/bin/containerd-shim-runsc-v1)
curl -fsSL https://gvisor.dev/archive.key | gpg --dearmor --yes -o /etc/apt/keyrings/gvisor.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/gvisor.gpg] https://storage.googleapis.com/gvisor/releases release main" \
  > /etc/apt/sources.list.d/gvisor.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin runsc

# Register runsc with host Docker too, for quick `docker run --runtime=runsc` checks.
runsc install
systemctl enable --now docker
systemctl restart docker

usermod -aG docker "$TARGET_USER"

# kind runs several nodes' worth of processes; WSL2 defaults are low.
cat > /etc/sysctl.d/99-kind.conf <<'EOF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF
sysctl --system >/dev/null

echo
echo "Done. Open a new shell (or run: newgrp docker) so the docker group applies, then:"
echo "  docker run --rm --runtime=runsc hello-world"
echo "  make up"
