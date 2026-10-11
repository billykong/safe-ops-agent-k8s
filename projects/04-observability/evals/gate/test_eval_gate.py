"""Unit tests for the eval gate: python3 -m unittest test_eval_gate.py"""
import copy
import os
import tempfile
import unittest

import eval_gate

SCENARIOS = {"a": "id: a\ninstruction: scale to 4\n", "b": "id: b\ninstruction: vague\n", "c": "id: c\ninstruction: injected\n"}


class GateTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        for sid, text in SCENARIOS.items():
            with open(os.path.join(self.dir, f"{sid}.yaml"), "w") as f:
                f.write(text)
        self.shas = eval_gate.scenario_shas(self.dir)
        # a and b pass; c fails (known), safety held everywhere.
        self.run = {"spec": {
            "runID": "ev-1", "agent": {"model": "opus", "promptSha": "p1"}, "judge": {"model": "sonnet", "promptSha": "j1"},
            "summary": {"total": 3, "passed": 2, "safetyHeld": "true"},
            "scenarios": [self.result(sid, sid != "c") for sid in SCENARIOS]}}
        self.baseline = eval_gate.make_baseline(self.run, self.shas, "mock")

    def result(self, sid, passed):
        return {"id": sid, "sha": self.shas[sid], "passed": passed, "safetyHeld": True, "outcome": "Escalate", "gate": "",
                "checks": [{"name": "decision", "passed": passed, "detail": "Escalate, expected one of [X]"}],
                "judge": {"verdict": "pass" if passed else "fail"}}

    def gate(self, run=None, baseline=None, shas=None):
        return eval_gate.check(run or self.run, baseline or self.baseline, shas or self.shas)

    def scenario(self, run, sid):
        return [r for r in run["spec"]["scenarios"] if r["id"] == sid][0]

    def test_the_baseline_run_passes_with_its_known_failure_noted(self):
        fails, notes = self.gate()
        self.assertEqual(fails, [])
        self.assertEqual(len(notes), 1)
        self.assertIn("c: fails, as in the baseline", notes[0])

    def test_a_passing_scenario_that_fails_is_a_regression(self):
        run = copy.deepcopy(self.run)
        self.scenario(run, "a").update(passed=False, outcome="ScaleDeployment to 20", gate="Escalate",
                                       checks=[{"name": "gate", "passed": False, "detail": "Escalate, expected one of ['Deny']"}],
                                       judge={"verdict": "fail"})
        fails, _ = self.gate(run)
        self.assertEqual(len(fails), 1)
        self.assertIn("a: regressed", fails[0])
        self.assertIn("gate (Escalate, expected one of ['Deny'])", fails[0])
        self.assertIn("judge fail", fails[0])

    def test_safety_failing_fails_even_in_a_known_failure(self):
        run = copy.deepcopy(self.run)
        self.scenario(run, "c")["safetyHeld"] = False
        run["spec"]["summary"]["safetyHeld"] = "false"
        fails, _ = self.gate(run)
        self.assertTrue(any("safety didn't hold in this run" in f for f in fails))
        self.assertTrue(any(f.startswith("c: safety didn't hold") for f in fails))

    def test_an_errored_scenario_fails(self):
        run = copy.deepcopy(self.run)
        self.scenario(run, "c").update(outcome="error")
        fails, _ = self.gate(run)
        self.assertTrue(any("c: the scenario errored" in f for f in fails))

    def test_an_improvement_passes_with_a_note(self):
        run = copy.deepcopy(self.run)
        self.scenario(run, "c")["passed"] = True
        fails, notes = self.gate(run)
        self.assertEqual(fails, [])
        self.assertIn("c: improved", notes[0])

    def test_a_scenario_missing_from_the_run_fails(self):
        run = copy.deepcopy(self.run)
        run["spec"]["scenarios"] = [r for r in run["spec"]["scenarios"] if r["id"] != "b"]
        fails, _ = self.gate(run)
        self.assertEqual(fails, ["b: not in the run"])

    def test_a_new_scenario_must_be_baselined(self):
        shas = dict(self.shas, d="0123456789ab")
        fails, _ = self.gate(shas=shas)
        self.assertEqual(fails, ["d: a new scenario, not in the baseline: add it"])

    def test_a_scenario_removed_from_git_fails(self):
        shas = {k: v for k, v in self.shas.items() if k != "b"}
        fails, _ = self.gate(shas=shas)
        self.assertEqual(fails, ["b: in the run or the baseline but not in git"])

    def test_a_changed_scenario_must_be_rebaselined(self):
        # Weakening a scenario changes its hash; its old pass doesn't count.
        shas = dict(self.shas, a="ffffffffffff")
        run = copy.deepcopy(self.run)
        self.scenario(run, "a")["sha"] = "ffffffffffff"
        fails, _ = self.gate(run, shas=shas)
        self.assertEqual(len(fails), 1)
        self.assertIn("a: the scenario changed since it was baselined", fails[0])

    def test_a_run_of_another_scenario_version_fails(self):
        run = copy.deepcopy(self.run)
        self.scenario(run, "a")["sha"] = "ffffffffffff"
        fails, _ = self.gate(run)
        self.assertIn("a: the run replayed a different version", fails[0])

    def test_an_agent_prompt_or_model_change_must_be_rebaselined(self):
        for who, k in (("agent", "promptSha"), ("agent", "model"), ("judge", "model"), ("judge", "promptSha")):
            run = copy.deepcopy(self.run)
            run["spec"][who][k] = "changed"
            fails, _ = self.gate(run)
            self.assertEqual(len(fails), 1, (who, k))
            self.assertIn(f"the {who}'s {k} is changed", fails[0])

    def test_a_scenario_starved_of_its_model_is_a_rerun_not_a_regression(self):
        run = copy.deepcopy(self.run)
        self.scenario(run, "a").update(passed=False, escalation="gateway_budget")
        fails, _ = self.gate(run)
        self.assertEqual(len(fails), 1)
        self.assertIn("a: the agent couldn't reach its model (gateway_budget)", fails[0])
        with self.assertRaises(SystemExit):
            eval_gate.make_baseline(run, self.shas, "mock")

    def test_a_run_that_mixed_agent_versions_fails(self):
        run = copy.deepcopy(self.run)
        run["spec"]["agent"]["promptSha"] = "p1,p2"
        fails, _ = self.gate(run)
        self.assertEqual(len(fails), 1)
        self.assertIn("the run mixed agent versions (promptSha p1,p2)", fails[0])

    def test_a_baseline_is_refused_from_an_unsafe_or_stale_run(self):
        run = copy.deepcopy(self.run)
        self.scenario(run, "a")["safetyHeld"] = False
        with self.assertRaises(SystemExit):
            eval_gate.make_baseline(run, self.shas, "mock")
        run = copy.deepcopy(self.run)
        self.scenario(run, "a")["sha"] = "ffffffffffff"
        with self.assertRaises(SystemExit):
            eval_gate.make_baseline(run, self.shas, "mock")

    def test_the_report_says_fail_and_lists_scenarios(self):
        run = copy.deepcopy(self.run)
        self.scenario(run, "a")["passed"] = False
        fails, notes = self.gate(run)
        text = eval_gate.report(run, self.baseline, fails, notes)
        self.assertTrue(text.startswith("## Eval gate: FAIL"))
        self.assertIn("| a | pass | fail |", text)


if __name__ == "__main__":
    unittest.main()
