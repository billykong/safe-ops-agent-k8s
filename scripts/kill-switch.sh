#!/usr/bin/env bash
# Kill switch for the agent (P2-21). Runbook: docs/runbooks/kill-switch.md.
#
#   kill-switch.sh status
#   kill-switch.sh stop   --reason TEXT
#   kill-switch.sh resume --reason TEXT
#
# stop, in order (each step narrows what the next has to catch):
#   1. flag: approval-system/agent-kill-switch mode=stop. From this moment
#      admission refuses the agent's new claims and proposals, any new pod
#      in the agent namespace, and new tokens for it (manifests/90-kill-
#      switch.yaml); the approval controller cancels every ChangeRequest
#      that hasn't started applying, and applies nothing more.
#   2. scale to zero: suspend Jobs and CronJobs, scale Deployments and
#      StatefulSets to 0, delete the remaining pods in the agent namespace.
#   3. revoke credentials: delete and recreate ServiceAccount agent/agent.
#      Every token issued for it, including copies taken out of the
#      cluster, names the old UID and is refused from then on, for reads
#      too (admission never sees reads).
#   4. release the agent's sandboxes: delete its SandboxClaims (agent-*).
# Needs cluster-admin. Safe to re-run. resume sets mode=run and nothing
# else: the agent's workloads stay suspended until someone restarts them.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
CM_NS=approval-system CM=agent-kill-switch AGENT_NS=agent SA=agent

usage() { echo "usage: $0 status | stop --reason TEXT | resume --reason TEXT" >&2; exit 2; }
cmd=${1:-}; shift || true
reason=""
while [ $# -gt 0 ]; do
  case $1 in --reason) reason=${2:-}; shift 2 || usage ;; *) usage ;; esac
done

flag() { # mode reason
  local by; by=$(kubectl auth whoami -o jsonpath='{.status.userInfo.username}')
  kubectl apply --server-side --force-conflicts --field-manager=kill-switch -f - >/dev/null <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CM
  namespace: $CM_NS
  labels: {app.kubernetes.io/part-of: safe-ops}
data:
  mode: "$1"
  reason: $(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  by: "$by"
  at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
YAML
}

open_crs() { # ChangeRequests not yet in a final phase
  kubectl get changerequests -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.status.phase}{"\n"}{end}' \
    | awk '$2 !~ /^(Applied|Rejected|Failed|Expired|Cancelled)$/'
}

status() {
  local mode
  mode=$(kubectl get configmap -n $CM_NS $CM -o jsonpath='{.data.mode}' 2>/dev/null) || mode="(flag missing: stopped, fail closed)"
  echo "flag:          mode=${mode:-<empty>: stopped} $(kubectl get configmap -n $CM_NS $CM -o jsonpath='reason="{.data.reason}" by={.data.by} at={.data.at}' 2>/dev/null || true)"
  echo "agent pods:    $(kubectl get pods -n $AGENT_NS --no-headers 2>/dev/null | wc -l)"
  echo "jobs:          $(kubectl get jobs -n $AGENT_NS -o jsonpath='{range .items[*]}{.metadata.name}(suspend={.spec.suspend}) {end}')"
  echo "agent SA uid:  $(kubectl get sa -n $AGENT_NS $SA -o jsonpath='{.metadata.uid}' 2>/dev/null || echo missing)"
  echo "agent claims:  $(kubectl get sandboxclaims -n sandboxes -o name 2>/dev/null | grep -c '/agent-' || true)"
  echo "open requests: $(open_crs | wc -l)"
}

case $cmd in
status) status ;;
stop)
  [ -n "$reason" ] || usage
  t0=$(date +%s.%N)
  flag stop "$reason"
  echo "1. flag set to stop: admission now refuses the agent's claims and proposals, new agent pods and tokens"
  for j in $(kubectl get jobs -n $AGENT_NS -o name); do kubectl patch -n $AGENT_NS "$j" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null; done
  for j in $(kubectl get cronjobs -n $AGENT_NS -o name); do kubectl patch -n $AGENT_NS "$j" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null; done
  for w in $(kubectl get deployments,statefulsets -n $AGENT_NS -o name); do kubectl scale -n $AGENT_NS "$w" --replicas=0 >/dev/null; done
  kubectl delete pods -n $AGENT_NS --all --wait=false >/dev/null
  echo "2. scaled to zero: jobs suspended, pods deleting"
  old=$(kubectl get sa -n $AGENT_NS $SA -o jsonpath='{.metadata.uid}' 2>/dev/null || echo none)
  kubectl delete sa -n $AGENT_NS $SA --ignore-not-found >/dev/null
  kubectl create sa -n $AGENT_NS $SA >/dev/null
  echo "3. credentials revoked: ServiceAccount $AGENT_NS/$SA recreated (uid $old -> $(kubectl get sa -n $AGENT_NS $SA -o jsonpath='{.metadata.uid}'))"
  claims=$(kubectl get sandboxclaims -n sandboxes -o name 2>/dev/null | grep '/agent-' || true)
  [ -z "$claims" ] || kubectl delete -n sandboxes $claims --wait=false >/dev/null
  echo "4. sandboxes released: $(wc -w <<<"$claims") claim(s)"
  # The controller cancels open requests on its own; wait for it so the
  # report below is the settled state.
  for _ in $(seq 1 30); do [ -z "$(open_crs | grep -v ' Applying$' || true)" ] && break; sleep 1; done
  kubectl wait -n $AGENT_NS --for=delete pod --all --timeout=60s >/dev/null 2>&1 || true
  awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "stopped in %.1fs\n", b - a }'
  status
  ;;
resume)
  [ -n "$reason" ] || usage
  flag run "$reason"
  echo "flag set to run. The agent's workloads stay suspended or scaled to zero: restart them deliberately."
  status
  ;;
*) usage ;;
esac
