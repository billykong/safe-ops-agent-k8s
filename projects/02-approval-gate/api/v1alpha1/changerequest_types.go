package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// ActionType is a typed action the controller knows how to apply. Typed
// actions are the default path (P2-06): the agent picks one and its
// parameters, and the controller, not the agent, decides the exact patch.
// +kubebuilder:validation:Enum=ScaleDeployment;RestartDeployment
type ActionType string

const (
	// ScaleDeployment sets a Deployment's replica count.
	ScaleDeployment ActionType = "ScaleDeployment"
	// RestartDeployment rolls a Deployment's pods, like `kubectl rollout restart`.
	RestartDeployment ActionType = "RestartDeployment"
)

// TargetRef names the object an action changes.
type TargetRef struct {
	// kind of the target. Only Deployments for now.
	// +kubebuilder:validation:Enum=Deployment
	Kind string `json:"kind"`
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	Namespace string `json:"namespace"`
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	Name string `json:"name"`
}

// Action is the change itself.
// +kubebuilder:validation:XValidation:rule="self.type != 'ScaleDeployment' || has(self.replicas)",message="ScaleDeployment needs replicas"
// +kubebuilder:validation:XValidation:rule="self.type == 'ScaleDeployment' || !has(self.replicas)",message="replicas only applies to ScaleDeployment"
type Action struct {
	Type   ActionType `json:"type"`
	Target TargetRef  `json:"target"`
	// replicas for ScaleDeployment.
	// +optional
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=50
	Replicas *int32 `json:"replicas,omitempty"`
}

// Scope is what the proposer declares the change may touch. The controller
// rejects an action outside it, even if approved (P2-07).
type Scope struct {
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=10
	// +listType=set
	Namespaces []string `json:"namespaces"`
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=10
	// +listType=set
	Kinds []string `json:"kinds"`
}

// ChangeRequestSpec is the proposal. It is immutable once created (P2-02),
// so an approval always refers to exactly what was reviewed.
type ChangeRequestSpec struct {
	// intent: what the change is for, in the proposer's words.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=2000
	Intent string `json:"intent"`
	Action Action `json:"action"`
	// blastRadius: what the proposer expects the change to affect.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=2000
	BlastRadius string `json:"blastRadius"`
	Scope       Scope  `json:"scope"`
	// rollback: how to undo the change, in the proposer's words. The
	// controller also records an exact rollback patch before applying.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=2000
	Rollback string `json:"rollback"`
	// approvalWindowSeconds: how long after the plan is proposed an
	// approval is accepted (P2-12). Capped at a day.
	// +optional
	// +kubebuilder:default=3600
	// +kubebuilder:validation:Minimum=10
	// +kubebuilder:validation:Maximum=86400
	ApprovalWindowSeconds int32 `json:"approvalWindowSeconds,omitempty"`
}

// Phase of a ChangeRequest.
// +kubebuilder:validation:Enum=Pending;NeedsReapproval;Applying;Applied;Rejected;Failed;Expired;Cancelled;Withheld
type Phase string

const (
	// PhasePending: proposed, pre-state recorded, waiting for a decision.
	PhasePending Phase = "Pending"
	// PhaseNeedsReapproval: live state drifted from the recorded pre-state
	// after approval; the approval was cleared and a new one is needed.
	PhaseNeedsReapproval Phase = "NeedsReapproval"
	// PhaseApplying: approved; plan recorded, change being applied.
	PhaseApplying Phase = "Applying"
	// PhaseApplied: the change was applied.
	PhaseApplied Phase = "Applied"
	// PhaseRejected: rejected by a human or by the controller (e.g. out of scope).
	PhaseRejected Phase = "Rejected"
	// PhaseFailed: the change could not be applied.
	PhaseFailed Phase = "Failed"
	// PhaseExpired: no valid approval arrived before expiresAt.
	PhaseExpired Phase = "Expired"
	// PhaseCancelled: stopped by the kill switch before it was applied.
	PhaseCancelled Phase = "Cancelled"
	// PhaseWithheld: a seeded test proposal (P4-15) that was approved, by
	// a human or (would have been) by the change budget. Never applied.
	PhaseWithheld Phase = "Withheld"
)

// Decision by an approver.
// +kubebuilder:validation:Enum=Approved;Rejected
type Decision string

const (
	DecisionApproved Decision = "Approved"
	DecisionRejected Decision = "Rejected"
)

// Approval is written by a human through the status subresource, which the
// agent's identity can't update (P2-10). Admission policies make it
// trustworthy (manifests/70-approval-policies.yaml): only members of
// safe-ops:approvers who aren't service accounts may set it, and approver is
// overwritten with the authenticated username (P2-11).
type Approval struct {
	Decision Decision `json:"decision"`
	// approver: set from the authenticated request identity by admission
	// policy, whatever the client sends.
	// +optional
	Approver string `json:"approver,omitempty"`
	// time: when the client says it decided. Informational only: expiry is
	// judged by the controller's clock against expiresAt.
	Time metav1.Time `json:"time"`
	// reviewHash: the status.reviewHash of the packet the approver saw. An
	// approval for any other hash is discarded (P2-12).
	// +kubebuilder:validation:Pattern=`^sha256:[0-9a-f]{64}$`
	ReviewHash string `json:"reviewHash"`
	// +optional
	// +kubebuilder:validation:MaxLength=1000
	Comment string `json:"comment,omitempty"`
}

// BudgetGrant records that a change was approved by the change budget
// rather than by a human (P2-20). Written by the controller only.
type BudgetGrant struct {
	// budget: the ChangeBudget that paid for this change.
	Budget string `json:"budget"`
	// reviewHash: the packet the grant is for. Re-planning after drift
	// changes the hash, and the grant no longer applies.
	// +kubebuilder:validation:Pattern=`^sha256:[0-9a-f]{64}$`
	ReviewHash string      `json:"reviewHash"`
	Time       metav1.Time `json:"time"`
}

// TargetState is what the controller saw of the target.
type TargetState struct {
	// generation of the target, which changes with any spec change.
	Generation int64 `json:"generation"`
	Replicas   int32 `json:"replicas"`
	// restartedAt: the target's restart annotation, if any.
	// +optional
	RestartedAt string `json:"restartedAt,omitempty"`
}

// Severity of a finding.
// +kubebuilder:validation:Enum=Info;Warning;Critical
type Severity string

const (
	SeverityInfo     Severity = "Info"
	SeverityWarning  Severity = "Warning"
	SeverityCritical Severity = "Critical"
)

// Finding is a deterministic rule's verdict on the plan (P2-40).
type Finding struct {
	Severity Severity `json:"severity"`
	// code: a stable identifier, e.g. ScaleToZero, BelowDisruptionBudget.
	Code    string `json:"code"`
	Message string `json:"message"`
}

// FieldChange is one field the plan changes, from the server's own dry run.
type FieldChange struct {
	// path: dotted path, e.g. spec.replicas.
	Path string `json:"path"`
	// from and to: JSON values; empty when the field is absent.
	// +optional
	From string `json:"from,omitempty"`
	// +optional
	To string `json:"to,omitempty"`
}

// ComputedBlastRadius is what the change does to the target's pods,
// computed from the live object, not taken from the proposer.
type ComputedBlastRadius struct {
	ReplicasBefore int32 `json:"replicasBefore"`
	ReplicasAfter  int32 `json:"replicasAfter"`
	ReadyBefore    int32 `json:"readyBefore"`
	PodsAdded      int32 `json:"podsAdded"`
	PodsRemoved    int32 `json:"podsRemoved"`
	// podsReplaced: pods recreated by a rollout.
	PodsReplaced int32 `json:"podsReplaced"`
	// maxUnavailable: how many pods a rollout may take down at once,
	// resolved against the replica count.
	MaxUnavailable int32 `json:"maxUnavailable"`
	// disruptionBudgets: PodDisruptionBudgets selecting the target's pods.
	// +optional
	DisruptionBudgets []string `json:"disruptionBudgets,omitempty"`
	Summary           string   `json:"summary"`
}

// PolicyResult of the semantic action gate.
// +kubebuilder:validation:Enum=Allow;Escalate;Deny
type PolicyResult string

const (
	// PolicyAllow: no objection; the change budget may pay for it.
	PolicyAllow PolicyResult = "Allow"
	// PolicyEscalate: a human must approve it.
	PolicyEscalate PolicyResult = "Escalate"
	// PolicyDeny: rejected; no approval can override it.
	PolicyDeny PolicyResult = "Deny"
)

// PolicyDecision is the semantic action gate's verdict on a proposal's
// computed effect (P3-10), from policy/gate.rego.
type PolicyDecision struct {
	Result PolicyResult `json:"result"`
	// +optional
	Reasons []string `json:"reasons,omitempty"`
	// policySHA: the policy text that decided.
	// +optional
	PolicySHA string `json:"policySHA,omitempty"`
}

// Review is the packet the approver reviews, computed by the controller
// from the cluster, with no model involved (P2-40). It is covered by the
// review hash, so an approval binds to it.
type Review struct {
	// diff: every field the plan changes, from a server-side dry run of
	// the exact patch, so defaulting and admission are accounted for.
	// +optional
	Diff []FieldChange `json:"diff,omitempty"`
	// dryRun: "accepted", or "refused: <the API server's reason>".
	DryRun      string              `json:"dryRun"`
	BlastRadius ComputedBlastRadius `json:"blastRadius"`
	// +optional
	Findings []Finding `json:"findings,omitempty"`
	// rollbackCheck: whether the rollback plan, applied to the dry run's
	// result, restores the reviewed pre-state exactly.
	RollbackCheck string `json:"rollbackCheck"`
	// policy: the semantic action gate's decision on everything above.
	// +optional
	Policy *PolicyDecision `json:"policy,omitempty"`
}

// SeedOutcome is how a reviewer did on a seeded proposal (P4-15).
// +kubebuilder:validation:Enum=Caught;Missed;Passed;FalseAlarm;Undecided
type SeedOutcome string

const (
	// SeedCaught: a known-bad proposal was stopped (rejected, escalated or
	// denied).
	SeedCaught SeedOutcome = "Caught"
	// SeedMissed: a known-bad proposal was let through (approved, or allowed).
	SeedMissed SeedOutcome = "Missed"
	// SeedPassed: a sound proposal was let through.
	SeedPassed SeedOutcome = "Passed"
	// SeedFalseAlarm: a sound proposal was stopped.
	SeedFalseAlarm SeedOutcome = "FalseAlarm"
	// SeedUndecided: this reviewer never decided it (expired, cancelled, or
	// denied by policy before a human saw it).
	SeedUndecided SeedOutcome = "Undecided"
)

// SeededResult says a request was a seeded test proposal, and how the
// automated review and the human did on it (P4-15). Written by the
// controller only once the request is final, so an approver can't tell a
// seeded proposal from the agent's while deciding it.
type SeededResult struct {
	// expected: what a careful reviewer should decide.
	Expected Decision `json:"expected"`
	// reason: why, from the seed corpus.
	// +optional
	Reason string `json:"reason,omitempty"`
	// automated: the semantic action gate's verdict on the review packet
	// (rule findings included). Escalate or Deny stops a proposal.
	Automated SeedOutcome `json:"automated"`
	// human: the approver's decision.
	Human SeedOutcome `json:"human"`
	// +optional
	Approver string `json:"approver,omitempty"`
}

// ChangeRequestStatus is owned by the controller, except approval.
type ChangeRequestStatus struct {
	// +optional
	Phase Phase `json:"phase,omitempty"`
	// +optional
	Message string `json:"message,omitempty"`
	// approval: the human decision, set through the status subresource.
	// +optional
	Approval *Approval `json:"approval,omitempty"`
	// budgetGrant: set instead of a human approval when the change budget
	// approved the change.
	// +optional
	BudgetGrant *BudgetGrant `json:"budgetGrant,omitempty"`
	// review: the computed review packet for the current plan.
	// +optional
	Review *Review `json:"review,omitempty"`
	// proposedAt: when the request was first proposed (not reset by
	// re-proposals). With decidedAt, the basis of the oversight metrics.
	// +optional
	ProposedAt *metav1.Time `json:"proposedAt,omitempty"`
	// decidedAt: when the controller saw the request reach a final phase.
	// +optional
	DecidedAt *metav1.Time `json:"decidedAt,omitempty"`
	// proposals: how many times the plan was computed; more than one means
	// it was re-proposed after drift.
	// +optional
	Proposals int32 `json:"proposals,omitempty"`
	// preState: the target as recorded when the request was proposed (or
	// re-proposed after drift). Checked against live state before applying.
	// +optional
	PreState *TargetState `json:"preState,omitempty"`
	// plan: the exact patch the controller will apply, recorded before it
	// executes (P2-05).
	// +optional
	Plan string `json:"plan,omitempty"`
	// rollbackPlan: the exact patch that undoes the change, recorded before
	// it executes.
	// +optional
	RollbackPlan string `json:"rollbackPlan,omitempty"`
	// reviewHash: sha256 over the request's UID, spec, preState, plan and
	// rollbackPlan: everything the approver reviews. Changes whenever the
	// controller re-plans, which invalidates earlier approvals.
	// +optional
	ReviewHash string `json:"reviewHash,omitempty"`
	// expiresAt: approvals arriving after this (by the controller's clock)
	// are not applied; the request becomes Expired.
	// +optional
	ExpiresAt *metav1.Time `json:"expiresAt,omitempty"`
	// +optional
	AppliedAt *metav1.Time `json:"appliedAt,omitempty"`
	// seeded: set on a seeded test proposal when it's final (P4-15).
	// +optional
	Seeded *SeededResult `json:"seeded,omitempty"`
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Action",type=string,JSONPath=`.spec.action.type`
// +kubebuilder:printcolumn:name="Target",type=string,JSONPath=`.spec.action.target.name`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Approver",type=string,JSONPath=`.status.approval.approver`
// +kubebuilder:printcolumn:name="Budget",type=string,JSONPath=`.status.budgetGrant.budget`
// +kubebuilder:printcolumn:name="Expires",type=date,JSONPath=`.status.expiresAt`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// ChangeRequest is a proposed change to the cluster. The agent creates it;
// a human approves it; the controller applies it.
type ChangeRequest struct {
	metav1.TypeMeta `json:",inline"`

	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// spec is the proposal; immutable after creation.
	// +required
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="spec is immutable: create a new ChangeRequest instead"
	Spec ChangeRequestSpec `json:"spec"`

	// +optional
	Status ChangeRequestStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// ChangeRequestList contains a list of ChangeRequest
type ChangeRequestList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []ChangeRequest `json:"items"`
}

func init() {
	SchemeBuilder.Register(func(s *runtime.Scheme) error {
		s.AddKnownTypes(SchemeGroupVersion, &ChangeRequest{}, &ChangeRequestList{})
		return nil
	})
}
