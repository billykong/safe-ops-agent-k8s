package safeops.gate_test

import rego.v1

import data.safeops.gate

base := {
	"action": {"type": "ScaleDeployment", "replicas": 2, "target": {"kind": "Deployment", "namespace": "workloads", "name": "web"}},
	"target": {"labels": {"app": "web"}, "replicasBefore": 1, "readyBefore": 1},
	"namespace": {"name": "workloads", "labels": {"safe-ops.io/agent-managed": "true", "safe-ops.io/max-replicas": "20"}},
	"review": {
		"dryRun": "accepted",
		"blastRadius": {"replicasBefore": 1, "replicasAfter": 2},
		"findings": [],
		"rollbackCheck": "passed: restores the pre-state",
	},
}

with_target_labels(l) := object.union(base, {"target": object.union(base.target, {"labels": l})})

with_after(n) := object.union(base, {"review": object.union(base.review, {"blastRadius": {"replicasBefore": 1, "replicasAfter": n}})})

test_small_healthy_change_allowed if {
	gate.decision.result == "Allow" with input as base
}

test_finding_escalates if {
	i := object.union(base, {"review": object.union(base.review, {"findings": [{"severity": "Warning", "code": "LargeScaleUp", "message": "x"}]})})
	gate.decision.result == "Escalate" with input as i
}

test_info_finding_still_allowed if {
	i := object.union(base, {"review": object.union(base.review, {"findings": [{"severity": "Info", "code": "NoChange", "message": "x"}]})})
	gate.decision.result == "Allow" with input as i
}

test_critical_service_escalates if {
	gate.decision.result == "Escalate" with input as with_target_labels({"safe-ops.io/tier": "critical"})
}

test_critical_to_zero_denied if {
	i := object.union(with_target_labels({"safe-ops.io/tier": "critical"}), {"review": object.union(base.review, {"blastRadius": {"replicasBefore": 2, "replicasAfter": 0}})})
	gate.decision.result == "Deny" with input as i
}

test_protected_denied_even_if_harmless if {
	d := gate.decision with input as with_target_labels({"safe-ops.io/protected": "true"})
	d.result == "Deny"
	some r in d.reasons
	contains(r, "protected")
}

test_ceiling_denied if {
	gate.decision.result == "Deny" with input as with_after(21)
}

test_at_ceiling_allowed if {
	gate.decision.result == "Allow" with input as with_after(20)
}

test_unmanaged_namespace_denied if {
	# json.patch, not object.union: union merges the label maps.
	i := json.patch(base, [{"op": "replace", "path": "/namespace", "value": {"name": "kube-system", "labels": {}}}])
	gate.decision.result == "Deny" with input as i
}

test_dry_run_refused_denied if {
	i := object.union(base, {"review": object.union(base.review, {"dryRun": "refused: quota", "rollbackCheck": "not checked: the dry run was refused"})})
	d := gate.decision with input as i
	d.result == "Deny"
	count(d.reasons) == 1 # the refusal, not also the unchecked rollback
}

test_unverified_rollback_denied if {
	i := object.union(base, {"review": object.union(base.review, {"rollbackCheck": "FAILED: leaves spec.replicas changed"})})
	gate.decision.result == "Deny" with input as i
}

test_deny_beats_escalate if {
	i := object.union(with_target_labels({"safe-ops.io/protected": "true", "safe-ops.io/tier": "critical"}), {})
	gate.decision.result == "Deny" with input as i
}
