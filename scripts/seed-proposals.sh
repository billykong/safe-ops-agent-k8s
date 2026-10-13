#!/usr/bin/env bash
# Seeded known-bad proposals (P4-15): propose the corpus (or some of it) as
# the seeder's identity, for the approvers to decide among the agent's.
#   scripts/seed-proposals.sh [PREFIX [NAME ...]]
# PREFIX starts each ChangeRequest's name (default: ops). Prints
# "<ChangeRequest> <entry> <expected> <rules>" per proposal. How they were
# caught: approvalctl stats, the oversight dashboard, and each request's
# status.seeded once it's final. Needs `make p2 evals`.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
PREFIX=${1:-ops}; shift || true
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
kubectl config view --raw --minify --context "$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$tmp/ca.crt"
API=$(kubectl config view --minify --context "$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.server}') \
TOKEN=$(kubectl create token seeder -n evals --duration=10m) CA=$tmp/ca.crt \
  python3 scripts/seed_proposals.py projects/04-observability/evals/seeded/proposals.yaml "$PREFIX" "$@"
