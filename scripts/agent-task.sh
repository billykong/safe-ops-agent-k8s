#!/usr/bin/env bash
# Start a task for the model-driven agent, traced end to end (P4-01):
#   scripts/agent-task.sh NAME TARGET "instruction"
# Prints the trace id; open it in Jaeger or Grafana (scripts/observability.sh).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
[ $# -eq 3 ] || { echo "usage: $0 NAME TARGET INSTRUCTION" >&2; exit 2; }
kubectl exec -i -n agent deploy/agent-worker -- python - "$@" < "$(dirname "$0")/agent_task.py"
