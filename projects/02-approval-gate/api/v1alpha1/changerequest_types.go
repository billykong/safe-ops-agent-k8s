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
}

// Phase of a ChangeRequest.
// +kubebuilder:validation:Enum=Pending;NeedsReapproval;Applying;Applied;Rejected;Failed
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
)

// Decision by an approver.
// +kubebuilder:validation:Enum=Approved;Rejected
type Decision string

const (
	DecisionApproved Decision = "Approved"
	DecisionRejected Decision = "Rejected"
)

// Approval is written by a human through the status subresource, which the
// agent's identity can't update (P2-10). Binding the approver to the
// authenticated request identity, the spec hash and an expiry comes next
// (P2 milestone 2).
type Approval struct {
	Decision Decision `json:"decision"`
	// +kubebuilder:validation:MinLength=1
	Approver string      `json:"approver"`
	Time     metav1.Time `json:"time"`
	// +optional
	Comment string `json:"comment,omitempty"`
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

// ChangeRequestStatus is owned by the controller, except approval.
type ChangeRequestStatus struct {
	// +optional
	Phase Phase `json:"phase,omitempty"`
	// +optional
	Message string `json:"message,omitempty"`
	// approval: the human decision, set through the status subresource.
	// +optional
	Approval *Approval `json:"approval,omitempty"`
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
	// +optional
	AppliedAt *metav1.Time `json:"appliedAt,omitempty"`
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
