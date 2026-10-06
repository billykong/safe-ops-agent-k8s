#!/usr/bin/env bash
# One-time, no sudo: install Go into ~/.local/go for the P2 controller
# (kubebuilder). The Makefile puts ~/.local/go/bin on PATH for its targets.
# The tarball's sha256 is checked against go.dev's published list.
set -euo pipefail
GO_VERSION=${GO_VERSION:-1.27.1}
FILE=go${GO_VERSION}.linux-amd64.tar.gz
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 5 -o "$tmp/$FILE" "https://go.dev/dl/$FILE"
want=$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | python3 -c '
import json, sys
f = sys.argv[1]
print(next(x["sha256"] for r in json.load(sys.stdin) for x in r["files"] if x["filename"] == f))' "$FILE")
echo "$want  $tmp/$FILE" | sha256sum -c -
rm -rf "$HOME/.local/go" && mkdir -p "$HOME/.local" && tar -C "$HOME/.local" -xzf "$tmp/$FILE"
"$HOME/.local/go/bin/go" version
