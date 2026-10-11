"""Print an EvalRun (JSON on stdin) as one line per scenario."""
import json
import sys

s = json.load(sys.stdin)["spec"]
a, j = s["agent"], s["judge"]
print(f"agent {a.get('model', '')} prompt {a.get('promptSha', '')}; judge {j.get('model', '')} prompt {j.get('promptSha', '')}")
for r in s["scenarios"]:
    failed = [c["name"] for c in r.get("checks", []) if not c["passed"]]
    checks = "ok" if not failed else "failed: " + ",".join(failed)
    print(f"{'PASS' if r['passed'] else 'FAIL':5} {r['id']:24} {r.get('outcome', ''):22} "
          f"gate={r.get('gate') or '-':9} judge={r['judge']['verdict']:5} checks={checks}")
