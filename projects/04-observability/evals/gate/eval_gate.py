"""The eval regression gate (P4-13). Compares one EvalRun, as the evaluator
wrote it (P4-12), against the baseline in git, and fails if the agent got
worse or if the run can't be compared:

- safety didn't hold in any scenario;
- a scenario the baseline passes now fails, or errored;
- the agent couldn't reach its model in a scenario (a spent token budget,
  the provider down): a rerun, not a verdict;
- a scenario in git is missing from the run, or from the baseline;
- a scenario file changed since it was baselined (a weakened scenario
  would otherwise keep its old pass);
- the run mixed agent versions (an old worker still deciding mid-rollout);
- the agent's model or prompt, or the judge's, changed since the baseline.
  The mock model scores a prompt change the same as before, so the gate
  makes it a deliberate step: re-baseline, after a run on the real model.

A scenario the baseline fails that now passes is reported, not failed:
update the baseline to lock the improvement in.

    eval_gate.py check RUN.json BASELINE.yaml SCENARIOS_DIR [--report FILE]
    eval_gate.py baseline RUN.json SCENARIOS_DIR --mode mock > BASELINE.yaml

Exit 0 if the gate passes, 1 if it fails, 2 on bad input."""
import argparse
import glob
import hashlib
import json
import os
import sys

import yaml


def scenario_shas(directory):
    """id -> the hash the runner records: the file's first 12 hex of sha256."""
    out = {}
    for f in sorted(glob.glob(os.path.join(directory, "*.yaml"))):
        raw = open(f, "rb").read()
        out[yaml.safe_load(raw)["id"]] = hashlib.sha256(raw).hexdigest()[:12]
    return out


# Escalations that say the agent couldn't reach its model: the scenario
# measured the environment, not the agent (agent/model.py).
INFRA = {"gateway_budget", "model_unavailable", "model_request_failed"}


def check(run, baseline, shas):
    """Returns (failures, notes): lists of one-line strings."""
    fails, notes = [], []
    spec = run["spec"]
    results = {r["id"]: r for r in spec["scenarios"]}
    base = baseline.get("scenarios", {})

    for who in ("agent", "judge"):
        for k in ("model", "promptSha"):
            got, want = spec.get(who, {}).get(k, ""), baseline.get(who, {}).get(k, "")
            if "," in got:
                # The runner lists every version that decided: an old worker
                # still polling during a rollout decides some scenarios.
                fails.append(f"the run mixed {who} versions ({k} {got}): run it again once one version is deployed")
            elif got != want:
                fails.append(f"the {who}'s {k} is {got or 'unknown'}, the baseline's is {want or 'unset'}: "
                             f"a {who} change needs a new baseline, from a run on the real model")
    if spec.get("summary", {}).get("safetyHeld") != "true":
        fails.append("safety didn't hold in this run")

    for sid in sorted(set(shas) | set(results) | set(base)):
        r, b = results.get(sid), base.get(sid)
        if sid not in shas:
            fails.append(f"{sid}: in the run or the baseline but not in git")
            continue
        if b is None:
            fails.append(f"{sid}: a new scenario, not in the baseline: add it")
            continue
        if b.get("sha") != shas[sid]:
            fails.append(f"{sid}: the scenario changed since it was baselined ({b.get('sha')} -> {shas[sid]}): re-baseline it")
        if r is None:
            fails.append(f"{sid}: not in the run")
            continue
        if r.get("sha") != shas[sid]:
            fails.append(f"{sid}: the run replayed a different version of the scenario ({r.get('sha')}, git has {shas[sid]})")
        if not r.get("safetyHeld", False):
            fails.append(f"{sid}: safety didn't hold ({r.get('outcome')}, gate {r.get('gate') or '-'})")
        if r.get("escalation") in INFRA:
            fails.append(f"{sid}: the agent couldn't reach its model ({r['escalation']}): "
                         f"this run measured the environment, not the agent; run it again")
        elif r.get("outcome") == "error":
            fails.append(f"{sid}: the scenario errored: {why(r)}")
        elif b.get("passed") and not r.get("passed"):
            fails.append(f"{sid}: regressed: the baseline passes ({b.get('outcome')}), "
                         f"now {r.get('outcome')}, gate {r.get('gate') or '-'}: {why(r)}")
        elif not b.get("passed") and r.get("passed"):
            notes.append(f"{sid}: improved: the baseline fails, now passes ({r.get('outcome')}): update the baseline")
        elif not b.get("passed"):
            notes.append(f"{sid}: fails, as in the baseline ({r.get('outcome')}): known failure")
    return fails, notes


def why(r):
    failed = [f"{c['name']} ({c['detail']})" for c in r.get("checks", []) if not c["passed"]]
    j = r.get("judge", {}).get("verdict", "")
    return "; ".join(failed + ([f"judge {j}"] if j != "pass" else [])) or "no detail"


def report(run, baseline, fails, notes):
    spec = run["spec"]
    s = spec.get("summary", {})
    lines = [f"## Eval gate: {'FAIL' if fails else 'PASS'}", "",
             f"Run `{spec.get('runID')}`, {baseline.get('mode', '?')} mode: {s.get('passed')}/{s.get('total')} passed "
             f"(baseline {sum(1 for b in baseline.get('scenarios', {}).values() if b.get('passed'))}), "
             f"safety held: {s.get('safetyHeld')}. Agent {spec.get('agent', {}).get('model')} "
             f"prompt {spec.get('agent', {}).get('promptSha')}; judge {spec.get('judge', {}).get('model')}.", ""]
    if fails:
        lines += ["### Failures", ""] + [f"- {f}" for f in fails] + [""]
    if notes:
        lines += ["### Notes", ""] + [f"- {n}" for n in notes] + [""]
    lines += ["| Scenario | Baseline | Now | Outcome | Gate |", "| --- | --- | --- | --- | --- |"]
    for r in spec["scenarios"]:
        b = baseline.get("scenarios", {}).get(r["id"], {})
        lines.append(f"| {r['id']} | {mark(b.get('passed'))} | {mark(r.get('passed'))} | {r.get('outcome', '')} | {r.get('gate') or '-'} |")
    return "\n".join(lines) + "\n"


def mark(passed):
    return "-" if passed is None else ("pass" if passed else "fail")


def make_baseline(run, shas, mode):
    spec = run["spec"]
    out = {"mode": mode, "run": spec.get("runID"),
           "agent": {k: spec["agent"].get(k, "") for k in ("model", "promptSha")},
           "judge": {k: spec["judge"].get(k, "") for k in ("model", "promptSha")},
           "scenarios": {}}
    for r in sorted(spec["scenarios"], key=lambda r: r["id"]):
        if r.get("sha") != shas.get(r["id"]):
            sys.exit(f"{r['id']}: the run replayed {r.get('sha')}, git has {shas.get(r['id'])}: run it again first")
        if r.get("outcome") == "error" or not r.get("safetyHeld") or r.get("escalation") in INFRA:
            sys.exit(f"{r['id']}: errored or didn't hold safety: not a baseline")
        out["scenarios"][r["id"]] = {"sha": r["sha"], "passed": bool(r["passed"]), "outcome": r.get("outcome", "")}
    return out


HEADER = """# The eval gate's baseline (P4-13): what the agent scores now, in {mode}
# mode. CI fails a change that makes any passing scenario fail, or that
# changes a scenario, the agent's model or prompt, or the judge, without
# updating this file in the same change. Written by
# `scripts/eval-gate.sh --rebaseline`; review its diff like code.
"""


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("run"), c.add_argument("baseline"), c.add_argument("scenarios")
    c.add_argument("--report")
    b = sub.add_parser("baseline")
    b.add_argument("run"), b.add_argument("scenarios")
    b.add_argument("--mode", required=True, choices=["mock", "live"])
    a = p.parse_args()
    try:
        run = json.load(open(a.run))
        shas = scenario_shas(a.scenarios)
    except (OSError, ValueError, KeyError) as e:
        print(f"bad input: {e}", file=sys.stderr)
        sys.exit(2)
    if a.cmd == "baseline":
        sys.stdout.write(HEADER.format(mode=a.mode) + yaml.safe_dump(make_baseline(run, shas, a.mode), sort_keys=False))
        return
    baseline = yaml.safe_load(open(a.baseline))
    fails, notes = check(run, baseline, shas)
    text = report(run, baseline, fails, notes)
    if a.report:
        with open(a.report, "w") as f:
            f.write(text)
    print(text)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
