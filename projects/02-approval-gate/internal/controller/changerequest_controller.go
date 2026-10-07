package controller

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"slices"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

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
// Read the disruption budgets that cover a target, for the review packet.
// +kubebuilder:rbac:groups=policy,namespace=workloads,resources=poddisruptionbudgets,verbs=list
// The change budget: read it, and record grants in its status (P2-20).
// +kubebuilder:rbac:groups=approval.safe-ops.io,resources=changebudgets,verbs=get;list;watch
// +kubebuilder:rbac:groups=approval.safe-ops.io,resources=changebudgets/status,verbs=get;update;patch
// The kill switch flag, read-only, in the controller's own namespace (P2-21).
// +kubebuilder:rbac:groups="",namespace=approval-system,resources=configmaps,verbs=get;list;watch

func (r *ChangeRequestReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)
	var cr approvalv1alpha1.ChangeRequest
	if err := r.Get(ctx, req.NamespacedName, &cr); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	base := cr.DeepCopy()
	st := &cr.Status

	switch st.Phase {
	case approvalv1alpha1.PhaseApplied, approvalv1alpha1.PhaseRejected, approvalv1alpha1.PhaseFailed, approvalv1alpha1.PhaseExpired,
		approvalv1alpha1.PhaseCancelled:
		return ctrl.Result{}, nil
	}

	// Kill switch (P2-21), fail closed: unless it says run, nothing that
	// hasn't started applying will, whoever approved it. An apply already
	// under way is a single idempotent patch and is allowed to finish.
	if st.Phase != approvalv1alpha1.PhaseApplying {
		running, why, err := r.agentRunning(ctx)
		if err != nil {
			return ctrl.Result{}, err // can't tell: apply nothing, retry
		}
		if !running {
			return r.finish(ctx, &cr, base, approvalv1alpha1.PhaseCancelled, why)
		}
	}

	switch st.Phase {
	case "":
		// New proposal. An approval written before the controller has
		// recorded the pre-state and plan didn't review them: drop it.
		st.Approval = nil
		if err := CheckScope(cr.Spec); err != nil {
			return r.finish(ctx, &cr, base, approvalv1alpha1.PhaseRejected, err.Error())
		}
		dep, err := r.target(ctx, cr.Spec.Action.Target)
		if err != nil {
			return r.finish(ctx, &cr, base, approvalv1alpha1.PhaseFailed, fmt.Sprintf("reading target: %v", err))
		}
		if err := r.propose(ctx, &cr, dep); err != nil {
			return r.finish(ctx, &cr, base, approvalv1alpha1.PhaseFailed, err.Error())
		}
		st.Phase = approvalv1alpha1.PhasePending
		// The budget is consulted once, here. A request it doesn't pay
		// for waits for a human, even if budget frees up later.
		grant, why, err := r.spendBudget(ctx, &cr)
		if err != nil {
			return ctrl.Result{}, err // usually a conflict on the budget: retried
		}
		st.BudgetGrant, st.Message = grant, why
		log.Info("proposed", "plan", st.Plan, "budget", why)
		return ctrl.Result{}, r.save(ctx, &cr, base)

	case approvalv1alpha1.PhasePending, approvalv1alpha1.PhaseNeedsReapproval:
		if st.ExpiresAt == nil || st.ReviewHash == "" {
			// Proposed before review hashes and expiry existed: re-propose,
			// and require an approval of the new packet.
			dep, err := r.target(ctx, cr.Spec.Action.Target)
			if err != nil {
				return r.finish(ctx, &cr, base, approvalv1alpha1.PhaseFailed, fmt.Sprintf("reading target: %v", err))
			}
			st.Approval, st.BudgetGrant = nil, nil
			if err := r.propose(ctx, &cr, dep); err != nil {
				return r.finish(ctx, &cr, base, approvalv1alpha1.PhaseFailed, err.Error())
			}
			st.Phase, st.Message = approvalv1alpha1.PhaseNeedsReapproval, "re-proposed with a review hash and expiry: approve again"
			return ctrl.Result{}, r.save(ctx, &cr, base)
		}
		// Expiry is judged by the controller's clock, never by a time a
		// client wrote (P2-12).
		budgeted := st.BudgetGrant != nil && st.BudgetGrant.ReviewHash == st.ReviewHash
		if remaining := st.ExpiresAt.Sub(r.now()); remaining <= 0 {
			st.Approval = nil
			return r.finish(ctx, &cr, base, approvalv1alpha1.PhaseExpired,
				fmt.Sprintf("no valid approval before %s", st.ExpiresAt.UTC().Format(time.RFC3339)))
		} else if st.Approval == nil && !budgeted {
			return ctrl.Result{RequeueAfter: remaining}, nil // expire on time even if nobody answers
		}
		if st.Approval != nil {
			if st.Approval.Decision == approvalv1alpha1.DecisionRejected {
				return r.finish(ctx, &cr, base, approvalv1alpha1.PhaseRejected, "rejected by "+st.Approval.Approver)
			}
			// The approval must be for exactly the packet the controller
			// currently holds. One made for an earlier plan (before drift)
			// or any other hash is discarded, not applied (P2-12).
			if st.Approval.ReviewHash != st.ReviewHash {
				st.Message = fmt.Sprintf("discarded an approval by %s for review hash %s; the current plan's hash is %s: review again",
					st.Approval.Approver, st.Approval.ReviewHash, st.ReviewHash)
				st.Approval = nil
				log.Info("hash mismatch", "message", st.Message)
				return ctrl.Result{}, r.save(ctx, &cr, base)
			}
		}
		if err := CheckScope(cr.Spec); err != nil { // the spec is immutable, but check again before writing
			return r.finish(ctx, &cr, base, approvalv1alpha1.PhaseRejected, err.Error())
		}
		dep, err := r.target(ctx, cr.Spec.Action.Target)
		if err != nil {
			return r.finish(ctx, &cr, base, approvalv1alpha1.PhaseFailed, fmt.Sprintf("reading target: %v", err))
		}
		// Time-of-check/time-of-use: the human approved a plan computed
		// from the recorded pre-state. If the target changed since, that
		// plan (and its rollback) may be wrong: re-propose from live state
		// and require a fresh approval (P2-04).
		if live := Observe(dep); Drifted(*st.PreState, live) {
			before := *st.PreState
			// The budget paid for the old plan only: a re-proposed plan
			// needs a human.
			st.Approval, st.BudgetGrant = nil, nil
			if err := r.propose(ctx, &cr, dep); err != nil {
				return r.finish(ctx, &cr, base, approvalv1alpha1.PhaseFailed, err.Error())
			}
			st.Phase = approvalv1alpha1.PhaseNeedsReapproval
			st.Message = fmt.Sprintf("target changed since it was reviewed (generation %d -> %d, replicas %d -> %d): re-approve the new plan",
				before.Generation, live.Generation, before.Replicas, live.Replicas)
			log.Info("drift", "message", st.Message)
			return ctrl.Result{}, r.save(ctx, &cr, base)
		}
		// Mark Applying before touching the target, so the record of what
		// is about to run exists even if we crash mid-apply (P2-05).
		st.Phase = approvalv1alpha1.PhaseApplying
		st.Message = "applying the recorded plan"
		if err := r.save(ctx, &cr, base); err != nil {
			return ctrl.Result{}, err // usually a conflict: retried with fresh state
		}
		return r.apply(ctx, &cr, base)

	case approvalv1alpha1.PhaseApplying:
		// We crashed (or a status update failed) after deciding to apply.
		// The plan is a merge patch with fixed values, so applying it again
		// is idempotent.
		return r.apply(ctx, &cr, base)
	}
	return ctrl.Result{}, nil
}

func (r *ChangeRequestReconciler) apply(ctx context.Context, cr, base *approvalv1alpha1.ChangeRequest) (ctrl.Result, error) {
	t := cr.Spec.Action.Target
	dep := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Namespace: t.Namespace, Name: t.Name}}
	if err := r.Patch(ctx, dep, client.RawPatch(types.MergePatchType, []byte(cr.Status.Plan))); err != nil {
		return r.finish(ctx, cr, base, approvalv1alpha1.PhaseFailed, fmt.Sprintf("applying plan: %v", err))
	}
	now := metav1.NewTime(r.now())
	cr.Status.AppliedAt = &now
	logf.FromContext(ctx).Info("applied", "plan", cr.Status.Plan)
	by := "approved by " + approverOf(cr)
	return r.finish(ctx, cr, base, approvalv1alpha1.PhaseApplied, "applied ("+by+"); rollbackPlan undoes it")
}

// review builds the packet for the current plan: a server-side dry run of
// the exact patch (admission included), the diff it implies, the computed
// blast radius, the rule findings and the rollback check. A refusal by the
// server is a finding; any other error is returned and the proposal retried.
func (r *ChangeRequestReconciler) review(ctx context.Context, cr *approvalv1alpha1.ChangeRequest, dep *appsv1.Deployment) (*approvalv1alpha1.Review, error) {
	live, err := runtime.DefaultUnstructuredConverter.ToUnstructured(dep)
	if err != nil {
		return nil, err
	}
	rv := &approvalv1alpha1.Review{DryRun: "accepted"}
	refusal := ""
	dry := dep.DeepCopy()
	if err := r.Patch(ctx, dry, client.RawPatch(types.MergePatchType, []byte(cr.Status.Plan)), client.DryRunAll); err != nil {
		switch apierrors.ReasonForError(err) {
		case metav1.StatusReasonForbidden, metav1.StatusReasonInvalid, metav1.StatusReasonBadRequest, metav1.StatusReasonNotAcceptable:
			refusal = err.Error()
			rv.DryRun = "refused: " + refusal
		default:
			return nil, fmt.Errorf("dry run: %w", err)
		}
	}
	var pdbs policyv1.PodDisruptionBudgetList
	if err := r.Reader.List(ctx, &pdbs, client.InNamespace(dep.Namespace)); err != nil {
		return nil, fmt.Errorf("listing disruption budgets: %w", err)
	}
	if refusal == "" {
		after, err := runtime.DefaultUnstructuredConverter.ToUnstructured(dry)
		if err != nil {
			return nil, err
		}
		rv.Diff = Diff(live, after, DiffRoots...)
		rv.RollbackCheck = RollbackCheck(live, after, cr.Status.RollbackPlan)
	} else {
		rv.RollbackCheck = "not checked: the dry run was refused"
	}
	rv.BlastRadius = BlastRadius(dep, cr.Spec.Action, pdbs.Items)
	rv.Findings = Findings(dep, cr.Spec.Action, rv.BlastRadius, pdbs.Items, rv.Diff, refusal)
	return rv, nil
}

func approverOf(cr *approvalv1alpha1.ChangeRequest) string {
	if a := cr.Status.Approval; a != nil {
		return a.Approver
	}
	if g := cr.Status.BudgetGrant; g != nil {
		return "change budget " + g.Budget
	}
	return "nobody"
}

// agentRunning reads the kill switch. Not found means stopped; any other
// error is returned, so nothing proceeds until the flag can be read.
func (r *ChangeRequestReconciler) agentRunning(ctx context.Context) (bool, string, error) {
	var cm corev1.ConfigMap
	err := r.Get(ctx, types.NamespacedName{Namespace: KillSwitchNamespace, Name: KillSwitchName}, &cm)
	if apierrors.IsNotFound(err) {
		running, why := Running(nil)
		return running, why, nil
	}
	if err != nil {
		return false, "", err
	}
	running, why := Running(&cm)
	return running, why, nil
}

// spendBudget pays for a just-proposed change from the namespace's change
// budget if it's eligible and budget is left (P2-20). The grant is recorded
// in the budget's status, conditional on its resourceVersion, before the
// request can be applied, so two requests can't spend the same slot. It is
// keyed by the request's UID: after a crash between the two writes, the
// retry finds its grant instead of spending another. Returns the grant (nil
// if the change must wait for a human) and a message explaining why.
func (r *ChangeRequestReconciler) spendBudget(ctx context.Context, cr *approvalv1alpha1.ChangeRequest) (*approvalv1alpha1.BudgetGrant, string, error) {
	var b approvalv1alpha1.ChangeBudget
	err := r.Get(ctx, types.NamespacedName{Namespace: cr.Namespace, Name: approvalv1alpha1.DefaultBudgetName}, &b)
	if apierrors.IsNotFound(err) {
		return nil, "waiting for approval (no change budget)", nil
	}
	if err != nil {
		return nil, "", err
	}
	if err := Eligible(b.Spec, cr.Spec.Action); err != nil {
		return nil, "waiting for approval: not covered by the change budget: " + err.Error(), nil
	}
	// The budget pays only for changes the review rules find nothing to
	// warn about (P2-44: risk tiers decided by deterministic policy).
	if rv := cr.Status.Review; rv != nil {
		if w := Worst(rv.Findings); w == approvalv1alpha1.SeverityWarning || w == approvalv1alpha1.SeverityCritical {
			codes := []string{}
			for _, f := range rv.Findings {
				if f.Severity != approvalv1alpha1.SeverityInfo {
					codes = append(codes, f.Code)
				}
			}
			return nil, fmt.Sprintf("waiting for approval: not covered by the change budget: review findings %v", codes), nil
		}
	}
	now, window := r.now(), BudgetWindow(b.Spec)
	live := InWindow(b.Status.Grants, window, now)
	grant := &approvalv1alpha1.BudgetGrant{Budget: b.Name, ReviewHash: cr.Status.ReviewHash, Time: metav1.NewTime(now)}
	left := func(used int) string {
		return fmt.Sprintf("%d of %d left in the last %s", int(b.Spec.MaxChanges)-used, b.Spec.MaxChanges, window)
	}
	if slices.ContainsFunc(live, func(g approvalv1alpha1.Grant) bool { return g.UID == cr.UID }) {
		return grant, "approved by change budget " + b.Name + " (" + left(len(live)) + ")", nil
	}
	if len(live) >= int(b.Spec.MaxChanges) {
		return nil, fmt.Sprintf("waiting for approval: change budget %s is spent (%d of %d autonomous changes used in the last %s)",
			b.Name, len(live), b.Spec.MaxChanges, window), nil
	}
	base := b.DeepCopy()
	b.Status.Grants = append(live, approvalv1alpha1.Grant{ChangeRequest: cr.Name, UID: cr.UID, Time: metav1.NewTime(now)})
	if err := r.Status().Patch(ctx, &b, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{})); err != nil {
		return nil, "", err
	}
	return grant, "approved by change budget " + b.Name + " (" + left(len(b.Status.Grants)) + ")", nil
}

// propose records the target's pre-state, the exact patch and rollback
// patch computed from it, the hash an approval must carry, and the expiry.
func (r *ChangeRequestReconciler) propose(ctx context.Context, cr *approvalv1alpha1.ChangeRequest, dep *appsv1.Deployment) error {
	pre := Observe(dep)
	now := r.now()
	plan, rollback, err := Plan(cr.Spec.Action, pre, now)
	if err != nil {
		return err
	}
	st := &cr.Status
	st.PreState, st.Plan, st.RollbackPlan = &pre, plan, rollback
	if st.Review, err = r.review(ctx, cr, dep); err != nil {
		return err
	}
	st.Proposals++
	if st.ProposedAt == nil {
		t := metav1.NewTime(now)
		st.ProposedAt = &t
	}
	if st.ReviewHash, err = ReviewHash(cr); err != nil {
		return err
	}
	window := cr.Spec.ApprovalWindowSeconds
	if window <= 0 {
		window = 3600
	}
	expires := metav1.NewTime(now.Add(time.Duration(window) * time.Second))
	st.ExpiresAt = &expires
	return nil
}

// ReviewHash covers everything an approver reviews: which object (UID, so
// a deleted and re-created namesake doesn't inherit approvals), the
// proposal, and the controller's pre-state, plan, rollback and review
// packet.
func ReviewHash(cr *approvalv1alpha1.ChangeRequest) (string, error) {
	b, err := json.Marshal(struct {
		UID          types.UID                          `json:"uid"`
		Spec         approvalv1alpha1.ChangeRequestSpec `json:"spec"`
		PreState     *approvalv1alpha1.TargetState      `json:"preState"`
		Plan         string                             `json:"plan"`
		RollbackPlan string                             `json:"rollbackPlan"`
		Review       *approvalv1alpha1.Review           `json:"review"`
	}{cr.UID, cr.Spec, cr.Status.PreState, cr.Status.Plan, cr.Status.RollbackPlan, cr.Status.Review})
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(sum[:]), nil
}

// finish moves a request to a final phase and records when.
func (r *ChangeRequestReconciler) finish(ctx context.Context, cr, base *approvalv1alpha1.ChangeRequest, phase approvalv1alpha1.Phase, msg string) (ctrl.Result, error) {
	cr.Status.Phase, cr.Status.Message = phase, msg
	if cr.Status.DecidedAt == nil {
		t := metav1.NewTime(r.now())
		cr.Status.DecidedAt = &t
	}
	logf.FromContext(ctx).Info("finished", "phase", phase, "message", msg)
	return ctrl.Result{}, r.save(ctx, cr, base)
}

// save writes the controller's status changes as a merge patch against
// base, the last state the controller read or wrote, with resourceVersion
// as a precondition. Only fields the controller changed are sent. A full
// Update re-serializes the whole status, and a human's approval that
// doesn't round-trip byte for byte through the Go type (an empty
// "comment", say) would look changed, which the admission policy rightly
// refuses from the controller. A human writing concurrently still causes a
// conflict and a retry, never an overwrite.
func (r *ChangeRequestReconciler) save(ctx context.Context, cr, base *approvalv1alpha1.ChangeRequest) error {
	if err := r.Status().Patch(ctx, cr, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{})); err != nil {
		return err
	}
	*base = *cr.DeepCopy()
	return nil
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
		// When the kill switch changes, revisit every open request. The
		// manager caches only that one ConfigMap (cmd/main.go).
		Watches(&corev1.ConfigMap{}, handler.EnqueueRequestsFromMapFunc(r.openRequests),
			builder.WithPredicates(predicate.NewPredicateFuncs(func(o client.Object) bool {
				return o.GetNamespace() == KillSwitchNamespace && o.GetName() == KillSwitchName
			}))).
		Named("changerequest").
		Complete(r)
}

func (r *ChangeRequestReconciler) openRequests(ctx context.Context, _ client.Object) []reconcile.Request {
	var l approvalv1alpha1.ChangeRequestList
	if err := r.List(ctx, &l); err != nil {
		logf.FromContext(ctx).Error(err, "listing ChangeRequests for the kill switch")
		return nil
	}
	var reqs []reconcile.Request
	for _, cr := range l.Items {
		switch cr.Status.Phase {
		case approvalv1alpha1.PhaseApplied, approvalv1alpha1.PhaseRejected, approvalv1alpha1.PhaseFailed,
			approvalv1alpha1.PhaseExpired, approvalv1alpha1.PhaseCancelled:
			continue
		}
		reqs = append(reqs, reconcile.Request{NamespacedName: client.ObjectKeyFromObject(&cr)})
	}
	return reqs
}
