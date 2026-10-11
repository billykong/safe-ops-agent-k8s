#!/usr/bin/env bash
# The eval regression gate (P4-13): run the replay evals once
# (scripts/eval-run.sh) and compare the EvalRun the evaluator wrote with
# the baseline in git (projects/04-observability/evals/baseline-<mode>.yaml,
# mode from the LLM gateway: mock or live). Exits non-zero if the agent
# regressed; CI runs this on every change to main (.github/workflows/eval-gate.yml).
#   scripts/eval-gate.sh [RUN_ID]
#   scripts/eval-gate.sh --rebaseline [RUN_ID]   # rewrite the baseline from a fresh run
# GATE_REPORT=FILE also writes the Markdown report there (CI: the job summary).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
REBASELINE=
[ "${1:-}" = --rebaseline ] && { REBASELINE=1; shift; }
RUN_ID=${1:-gate-$(date +%s)}
E=projects/04-observability/evals
if grep -q mock-model <<<"$(kubectl get deploy -n gateways llm-gateway -o jsonpath='{.spec.template.spec.containers[0].env}')"; then
  MODE=mock
else
  MODE=live
fi
BASELINE=$E/baseline-$MODE.yaml
[ -n "$REBASELINE" ] || [ -f "$BASELINE" ] || { echo "no $MODE baseline ($BASELINE): run with --rebaseline first" >&2; exit 2; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "eval gate: $MODE mode, run $RUN_ID"
scripts/eval-run.sh "$RUN_ID"
kubectl get evalrun -n evals "$RUN_ID" -o json > "$TMP/run.json"
if [ -n "$REBASELINE" ]; then
  python3 $E/gate/eval_gate.py baseline "$TMP/run.json" $E/scenarios --mode "$MODE" > "$TMP/baseline.yaml"
  mv "$TMP/baseline.yaml" "$BASELINE"
  echo "wrote $BASELINE from run $RUN_ID; review the diff and commit it with the change it covers"
  exit 0
fi
python3 $E/gate/eval_gate.py check "$TMP/run.json" "$BASELINE" $E/scenarios ${GATE_REPORT:+--report "$GATE_REPORT"}
