#!/usr/bin/env bash
# Open the telemetry UIs (P4): port-forwards to Grafana, Jaeger and
# Prometheus on localhost until Ctrl-C. Nothing in namespace observability
# is exposed any other way.
#   scripts/observability.sh            # Grafana :3000, Jaeger :16686, Prometheus :9090
#   GRAFANA_PORT=13000 scripts/observability.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
G=${GRAFANA_PORT:-3000} J=${JAEGER_PORT:-16686} P=${PROMETHEUS_PORT:-9090}
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
for f in "grafana $G 3000" "jaeger $J 16686" "prometheus $P 9090"; do
  set -- $f
  command kubectl --context "$KUBE_CONTEXT" port-forward -n observability "svc/$1" "$2:$3" >/dev/null & pids+=($!)
done
echo "Grafana     http://localhost:$G  (dashboard: Safe-ops / Safe-ops agent; anonymous view)"
echo "Jaeger      http://localhost:$J  (service safe-ops-agent; a trace id from scripts/agent-task.sh)"
echo "Prometheus  http://localhost:$P"
echo "Grafana admin password: kubectl --context $KUBE_CONTEXT get secret -n observability grafana-admin -o jsonpath='{.data.password}' | base64 -d"
echo "Ctrl-C to stop."
wait
