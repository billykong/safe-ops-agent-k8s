package controller

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	approvalv1alpha1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

// RestartAnnotation is what `kubectl rollout restart` sets on the pod template.
const RestartAnnotation = "kubectl.kubernetes.io/restartedAt"

// ChangeRequestReconciler moves a ChangeRequest from proposal to applied.
// It contains no LLM: every decision below is plain code over the spec,
// the human's approval and the target's live state.
type ChangeRequestReconciler struct {
	client.Client
	// Reader reads targets straight from the API server. The controller may
	// only get and patch Deployments in the namespaces it's granted, so it
	// can't list/watch them cluster-wide as a cached client would need.
	Reader client.Reader
	Scheme *runtime.Scheme
	// Now is the clock, replaceable in tests.
	Now func() time.Time
}

// The controller reads ChangeRequests everywhere and writes only their
// status: it never creates, edits or deletes a proposal.
// +kubebuilder:rbac:groups=approval.safe-ops.io,resources=changerequests,verbs=get;list;watch
// +kubebuilder:rbac:groups=approval.safe-ops.io,resources=changerequests/status,verbs=get;update;patch
// Write access to targets is namespace-scoped, never cluster-wide (P2-03).
// +kubebuilder:rbac:groups=apps,namespace=workloads,resources=deployments,verbs=get;patch

func (r *ChangeRequestReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)
	var cr approvalv1alpha1.ChangeRequest
	if err := r.Get(ctx, req.NamespacedName, &cr); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	st := &cr.Status

	switch st.Phase {
	case approvalv1alpha1.PhaseApplied, approvalv1alpha1.PhaseRejected, approvalv1alpha1.PhaseFailed:
		return ctrl.Result{}, nil

	case "":
		// New proposal. An approval written before the controller has
		// recorded the pre-state and plan didn't review them: drop it.
		st.Approval = nil
		if err := CheckScope(cr.Spec); err != nil {
			return r.finish(ctx, &cr, approvalv1alpha1.PhaseRejected, err.Error())
		}
		dep, err := r.target(ctx, cr.Spec.Action.Target)
		if err != nil {
			return r.finish(ctx, &cr, approvalv1alpha1.PhaseFailed, fmt.Sprintf("reading target: %v", err))
		}
		if err := r.propose(&cr, dep); err != nil {
			return r.finish(ctx, &cr, approvalv1alpha1.PhaseFailed, err.Error())
		}
		st.Phase = approvalv1alpha1.PhasePending
		st.Message = "waiting for approval"
		log.Info("proposed", "plan", st.Plan)
		return ctrl.Result{}, r.Status().Update(ctx, &cr)

	case approvalv1alpha1.PhasePending, approvalv1alpha1.PhaseNeedsReapproval:
		if st.Approval == nil {
			return ctrl.Result{}, nil
		}
		if st.Approval.Decision == approvalv1alpha1.DecisionRejected {
			return r.finish(ctx, &cr, approvalv1alpha1.PhaseRejected, "rejected by "+st.Approval.Approver)
		}
		if err := CheckScope(cr.Spec); err != nil { // the spec is immutable, but check again before writing
			return r.finish(ctx, &cr, approvalv1alpha1.PhaseRejected, err.Error())
		}
		dep, err := r.target(ctx, cr.Spec.Action.Target)
		if err != nil {
			return r.finish(ctx, &cr, approvalv1alpha1.PhaseFailed, fmt.Sprintf("reading target: %v", err))
		}
		// Time-of-check/time-of-use: the human approved a plan computed
		// from the recorded pre-state. If the target changed since, that
		// plan (and its rollback) may be wrong: re-propose from live state
		// and require a fresh approval (P2-04).
		if live := Observe(dep); Drifted(*st.PreState, live) {
			before := *st.PreState
			st.Approval = nil
			if err := r.propose(&cr, dep); err != nil {
				return r.finish(ctx, &cr, approvalv1alpha1.PhaseFailed, err.Error())
			}
			st.Phase = approvalv1alpha1.PhaseNeedsReapproval
			st.Message = fmt.Sprintf("target changed since it was reviewed (generation %d -> %d, replicas %d -> %d): re-approve the new plan",
				before.Generation, live.Generation, before.Replicas, live.Replicas)
			log.Info("drift", "message", st.Message)
			return ctrl.Result{}, r.Status().Update(ctx, &cr)
		}
		// Mark Applying before touching the target, so the record of what
		// is about to run exists even if we crash mid-apply (P2-05).
		st.Phase = approvalv1alpha1.PhaseApplying
		st.Message = "applying the recorded plan"
		if err := r.Status().Update(ctx, &cr); err != nil {
			return ctrl.Result{}, err // usually a conflict: retried with fresh state
		}
		return r.apply(ctx, &cr)

	case approvalv1alpha1.PhaseApplying:
		// We crashed (or a status update failed) after deciding to apply.
		// The plan is a merge patch with fixed values, so applying it again
		// is idempotent.
		return r.apply(ctx, &cr)
	}
	return ctrl.Result{}, nil
}

func (r *ChangeRequestReconciler) apply(ctx context.Context, cr *approvalv1alpha1.ChangeRequest) (ctrl.Result, error) {
	t := cr.Spec.Action.Target
	dep := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Namespace: t.Namespace, Name: t.Name}}
	if err := r.Patch(ctx, dep, client.RawPatch(types.MergePatchType, []byte(cr.Status.Plan))); err != nil {
		return r.finish(ctx, cr, approvalv1alpha1.PhaseFailed, fmt.Sprintf("applying plan: %v", err))
	}
	now := metav1.NewTime(r.now())
	cr.Status.AppliedAt = &now
	logf.FromContext(ctx).Info("applied", "plan", cr.Status.Plan)
	return r.finish(ctx, cr, approvalv1alpha1.PhaseApplied, "applied; rollbackPlan undoes it")
}

// propose records the target's pre-state, and the exact patch and rollback
// patch computed from it.
func (r *ChangeRequestReconciler) propose(cr *approvalv1alpha1.ChangeRequest, dep *appsv1.Deployment) error {
	pre := Observe(dep)
	plan, rollback, err := Plan(cr.Spec.Action, pre, r.now())
	if err != nil {
		return err
	}
	cr.Status.PreState, cr.Status.Plan, cr.Status.RollbackPlan = &pre, plan, rollback
	return nil
}

func (r *ChangeRequestReconciler) finish(ctx context.Context, cr *approvalv1alpha1.ChangeRequest, phase approvalv1alpha1.Phase, msg string) (ctrl.Result, error) {
	cr.Status.Phase, cr.Status.Message = phase, msg
	logf.FromContext(ctx).Info("finished", "phase", phase, "message", msg)
	return ctrl.Result{}, r.Status().Update(ctx, cr)
}

func (r *ChangeRequestReconciler) target(ctx context.Context, t approvalv1alpha1.TargetRef) (*appsv1.Deployment, error) {
	var dep appsv1.Deployment
	err := r.Reader.Get(ctx, types.NamespacedName{Namespace: t.Namespace, Name: t.Name}, &dep)
	if apierrors.IsNotFound(err) {
		return nil, fmt.Errorf("%s %s/%s not found", t.Kind, t.Namespace, t.Name)
	}
	return &dep, err
}

func (r *ChangeRequestReconciler) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

// CheckScope rejects an action whose target lies outside the declared scope.
func CheckScope(spec approvalv1alpha1.ChangeRequestSpec) error {
	t := spec.Action.Target
	if !slices.Contains(spec.Scope.Namespaces, t.Namespace) {
		return fmt.Errorf("target namespace %q is outside the declared scope %v", t.Namespace, spec.Scope.Namespaces)
	}
	if !slices.Contains(spec.Scope.Kinds, t.Kind) {
		return fmt.Errorf("target kind %q is outside the declared scope %v", t.Kind, spec.Scope.Kinds)
	}
	return nil
}

// Observe extracts the state that an approval depends on.
func Observe(dep *appsv1.Deployment) approvalv1alpha1.TargetState {
	s := approvalv1alpha1.TargetState{Generation: dep.Generation, Replicas: 1}
	if dep.Spec.Replicas != nil {
		s.Replicas = *dep.Spec.Replicas
	}
	s.RestartedAt = dep.Spec.Template.Annotations[RestartAnnotation]
	return s
}

// Drifted reports whether the target changed since its pre-state was
// recorded. Any spec change bumps the generation.
func Drifted(pre, live approvalv1alpha1.TargetState) bool {
	return pre != live
}

// Plan computes the exact merge patch for an action, and the merge patch
// that undoes it, from the recorded pre-state. Values are fixed at proposal
// time (including the restart timestamp), so the approved plan is exactly
// what runs, and re-running it is idempotent.
func Plan(a approvalv1alpha1.Action, pre approvalv1alpha1.TargetState, now time.Time) (plan, rollback string, err error) {
	var p, rb any
	switch a.Type {
	case approvalv1alpha1.ScaleDeployment:
		if a.Replicas == nil {
			return "", "", fmt.Errorf("ScaleDeployment without replicas")
		}
		p = map[string]any{"spec": map[string]any{"replicas": *a.Replicas}}
		rb = map[string]any{"spec": map[string]any{"replicas": pre.Replicas}}
	case approvalv1alpha1.RestartDeployment:
		restart := func(v any) any {
			return map[string]any{"spec": map[string]any{"template": map[string]any{
				"metadata": map[string]any{"annotations": map[string]any{RestartAnnotation: v}}}}}
		}
		p = restart(now.UTC().Format(time.RFC3339))
		// A restart can't be undone; restoring the previous annotation
		// rolls the pods once more, back to the previous template.
		var prev any // null removes the annotation
		if pre.RestartedAt != "" {
			prev = pre.RestartedAt
		}
		rb = restart(prev)
	default:
		return "", "", fmt.Errorf("unknown action type %q", a.Type)
	}
	pj, err := json.Marshal(p)
	if err != nil {
		return "", "", err
	}
	rj, err := json.Marshal(rb)
	return string(pj), string(rj), err
}

// SetupWithManager sets up the controller with the Manager.
func (r *ChangeRequestReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&approvalv1alpha1.ChangeRequest{}).
		Named("changerequest").
		Complete(r)
}
