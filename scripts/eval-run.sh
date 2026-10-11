#!/usr/bin/env bash
# Run the replay eval suite (P4-10) once: a Job in namespace evals, as the
# evaluator's identity, replaying every scenario in
# projects/04-observability/evals/scenarios/ (or the ones named) against
# the agent. Prints the EvalRun it wrote.
#   scripts/eval-run.sh [RUN_ID] [SCENARIO_ID,...]
# RUN_ID: a lowercase name, at most 30 characters (default ev-<epoch>).
# JUDGE_MODEL overrides the judge's model (default claude-sonnet-5-5), e.g.
# qwen2.5-1.5b-instruct, the local model (P5: make p5).
# Exits non-zero if the run didn't complete; scores don't fail it (that's
# the merge gate's job, milestone 4).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
RUN_ID=${1:-ev-$(date +%s)}
ONLY=${2:-}
# A different model from the agent's (P4-11); the runner refuses the same.
JUDGE_MODEL=${JUDGE_MODEL:-claude-sonnet-5-5}
S=projects/04-observability/evals/scenarios
[[ "$RUN_ID" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || { echo "RUN_ID: lowercase letters, digits and -, at most 30" >&2; exit 2; }
[ "$(kubectl get configmap -n approval-system agent-kill-switch -o jsonpath='{.data.mode}')" = run ] \
  || { echo "the kill switch is engaged: scripts/kill-switch.sh status" >&2; exit 1; }
# A change budget would apply the scenarios' allowed proposals in the
# sandbox, and spend the real budget doing it.
if kubectl get changebudget -n approvals -o name 2>/dev/null | grep -q .; then
  echo "a ChangeBudget exists in approvals: the runner never approves, but the budget would. Remove it first." >&2; exit 1
fi
# The scenarios, from git. Their hashes go in the EvalRun.
kubectl create configmap -n evals eval-scenarios $(for f in $S/*.yaml; do printf -- '--from-file=%s ' "$f"; done) \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: $RUN_ID
  namespace: evals
  labels: {app: eval-runner}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels: {app: eval-runner}
    spec:
      serviceAccountName: evaluator
      automountServiceAccountToken: false
      restartPolicy: Never
      dnsConfig:
        options: [{name: ndots, value: "1"}]
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: runner
        image: eval-runner:dev
        imagePullPolicy: Never
        env:
        - {name: RUN_ID, value: "$RUN_ID"}
        - {name: SCENARIO_IDS, value: "$ONLY"}
        - {name: TEMPORAL_ADDRESS, value: "temporal.temporal.svc.cluster.local:7233"}
        - {name: LLM_GATEWAY_URL, value: "http://llm-gateway.gateways.svc.cluster.local:8080"}
        - {name: JUDGE_MODEL, value: "$JUDGE_MODEL"}
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: {drop: ["ALL"]}
        resources:
          requests: {cpu: 50m, memory: 128Mi}
          limits: {cpu: 500m, memory: 256Mi}
        volumeMounts:
        - {name: scenarios, mountPath: /scenarios, readOnly: true}
        - {name: kube-api, mountPath: /var/run/secrets/kubernetes.io/serviceaccount, readOnly: true}
        - {name: llm-gateway-token, mountPath: /var/run/secrets/safe-ops.io/llm-gateway, readOnly: true}
        - {name: tmp, mountPath: /tmp}
      volumes:
      - name: scenarios
        configMap: {name: eval-scenarios}
      - name: tmp
        emptyDir: {}
      - name: kube-api
        projected:
          sources:
          - serviceAccountToken: {expirationSeconds: 3600, path: token}
          - configMap: {name: kube-root-ca.crt, items: [{key: ca.crt, path: ca.crt}]}
      # The evaluator's identity for the judge's model calls.
      - name: llm-gateway-token
        projected:
          sources:
          - serviceAccountToken: {audience: llm-gateway.safe-ops.io, expirationSeconds: 600, path: token}
YAML
echo "eval run $RUN_ID started"
for _ in $(seq 1 360); do
  st=$(kubectl get job -n evals "$RUN_ID" -o jsonpath='{.status.succeeded}/{.status.failed}')
  [ "$st" = "1/" ] && break
  [ "${st#*/}" = 1 ] && { kubectl logs -n evals "job/$RUN_ID" --tail=20 >&2; echo "the eval run failed" >&2; exit 1; }
  sleep 5
done
[ "$st" = "1/" ] || { echo "the eval run didn't finish in 30 minutes" >&2; exit 1; }
kubectl get evalrun -n evals "$RUN_ID"
kubectl get evalrun -n evals "$RUN_ID" -o json | python3 scripts/eval_summary.py
