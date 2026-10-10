# The semantic action gate (P3-10): what may happen to the cluster through
# the agent pipeline, judged on the change's computed effect, not on how it
# was asked for. Evaluated by the approval controller (embedded OPA) on
# every proposal, with the controller's review packet as input:
#
#   input.action      the typed action (type, replicas, target)
#   input.target      the live target: labels, replicas and ready pods
#   input.namespace   the target namespace: name, labels
#   input.review      the controller's review packet: server-side dry run,
#                     blast radius, rule findings, rollback check
#
# decision.result is one of:
#   deny      rejected outright; no approval can override it
#   escalate  a human must approve; the change budget can't pay for it
#   allow     no objection; the change budget may pay for it
# deny beats escalate beats allow. The controller treats a policy it can't
# load or evaluate as deny.
package safeops.gate

import rego.v1

replicas_after := input.review.blastRadius.replicasAfter

target_ref := sprintf("%s/%s", [input.action.target.namespace, input.action.target.name])

# --- deny: never through the agent pipeline, whoever approves

deny contains msg if {
	input.namespace.labels["safe-ops.io/agent-managed"] != "true"
	msg := sprintf("namespace %s isn't agent-managed (label safe-ops.io/agent-managed=true)", [input.namespace.name])
}

deny contains msg if {
	not input.namespace.labels["safe-ops.io/agent-managed"]
	msg := sprintf("namespace %s isn't agent-managed (label safe-ops.io/agent-managed=true)", [input.namespace.name])
}

deny contains msg if {
	input.target.labels["safe-ops.io/protected"] == "true"
	msg := sprintf("%s is protected: change it outside the agent pipeline", [target_ref])
}

deny contains msg if {
	input.target.labels["safe-ops.io/tier"] == "critical"
	replicas_after == 0
	msg := sprintf("would scale critical service %s to zero", [target_ref])
}

deny contains msg if {
	ceiling := to_number(input.namespace.labels["safe-ops.io/max-replicas"])
	replicas_after > ceiling
	msg := sprintf("%d replicas exceeds namespace %s's ceiling of %d", [replicas_after, input.namespace.name, ceiling])
}

deny contains msg if {
	startswith(input.review.dryRun, "refused")
	msg := "the API server refused a dry run of this exact change"
}

deny contains msg if {
	not startswith(input.review.dryRun, "refused")
	not startswith(input.review.rollbackCheck, "passed")
	msg := sprintf("the rollback isn't verified: %s", [input.review.rollbackCheck])
}

# --- escalate: allowed, but only with a human's approval

escalate contains msg if {
	some f in input.review.findings
	f.severity in {"Critical", "Warning"}
	msg := sprintf("%s finding %s: %s", [f.severity, f.code, f.message])
}

escalate contains msg if {
	input.target.labels["safe-ops.io/tier"] == "critical"
	msg := sprintf("%s is a critical service: every change needs a human", [target_ref])
}

# --- the decision

decision := {"result": "Deny", "reasons": sort(deny)} if {
	count(deny) > 0
} else := {"result": "Escalate", "reasons": sort(escalate)} if {
	count(escalate) > 0
} else := {"result": "Allow", "reasons": []}
