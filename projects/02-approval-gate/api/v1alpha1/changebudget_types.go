package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
)

// DefaultBudgetName is the ChangeBudget the controller consults: the one
// named "default" in the ChangeRequest's namespace. Without it, every change
// waits for a human.
const DefaultBudgetName = "default"

// ChangeBudgetSpec bounds the changes the controller may apply without a
// human (P2-20). Eligibility is decided by plain code over these fields,
// never by a model. Written by operators; the agent can't touch it.
// +kubebuilder:validation:XValidation:rule="self.minReplicas <= self.maxReplicas",message="minReplicas must not exceed maxReplicas"
type ChangeBudgetSpec struct {
	// maxChanges: autonomous changes allowed per window. Once spent, every
	// change waits for a human until older grants age out. 0 always asks.
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	MaxChanges int32 `json:"maxChanges"`
	// windowSeconds: the rolling window maxChanges applies to.
	// +optional
	// +kubebuilder:default=3600
	// +kubebuilder:validation:Minimum=10
	// +kubebuilder:validation:Maximum=604800
	WindowSeconds int32 `json:"windowSeconds,omitempty"`
	// actions: the action types that may be applied autonomously.
	// +kubebuilder:validation:MinItems=1
	// +listType=set
	Actions []ActionType `json:"actions"`
	// namespaces: target namespaces where autonomous changes are allowed.
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=10
	// +listType=set
	Namespaces []string `json:"namespaces"`
	// minReplicas and maxReplicas bound an autonomous ScaleDeployment. Scaling
	// outside them (to zero, say) needs a human.
	// +optional
	// +kubebuilder:default=1
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=50
	MinReplicas int32 `json:"minReplicas"`
	// +optional
	// +kubebuilder:default=3
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=50
	MaxReplicas int32 `json:"maxReplicas"`
}

// Grant is one autonomous change paid for by the budget.
type Grant struct {
	ChangeRequest string      `json:"changeRequest"`
	UID           types.UID   `json:"uid"`
	Time          metav1.Time `json:"time"`
}

// ChangeBudgetStatus is written by the controller only.
type ChangeBudgetStatus struct {
	// grants: autonomous changes within the window, oldest first. The
	// controller records a grant here, with resourceVersion as a
	// precondition, before it applies the change, so concurrent requests
	// can't overspend.
	// +optional
	// +listType=atomic
	Grants []Grant `json:"grants,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Max",type=integer,JSONPath=`.spec.maxChanges`
// +kubebuilder:printcolumn:name="Window",type=integer,JSONPath=`.spec.windowSeconds`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// ChangeBudget lets the controller apply a bounded number of low-risk
// changes without a human approval.
type ChangeBudget struct {
	metav1.TypeMeta `json:",inline"`

	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// +required
	Spec ChangeBudgetSpec `json:"spec"`

	// +optional
	Status ChangeBudgetStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// ChangeBudgetList contains a list of ChangeBudget
type ChangeBudgetList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []ChangeBudget `json:"items"`
}

func init() {
	SchemeBuilder.Register(func(s *runtime.Scheme) error {
		s.AddKnownTypes(SchemeGroupVersion, &ChangeBudget{}, &ChangeBudgetList{})
		return nil
	})
}
