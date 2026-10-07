// approvalctl: review and decide ChangeRequests (P2-41).
//
//	approvalctl [--kubeconfig F] [--context C] [-n NS] list
//	approvalctl ... show NAME
//	approvalctl ... approve NAME [--comment TEXT] [--yes] [--wait 30s]
//	approvalctl ... reject  NAME [--comment TEXT] [--yes] [--wait 30s]
//	approvalctl ... budget
//
// approve/reject show the review packet the controller recorded, ask for
// confirmation, then write the decision to the status subresource with the
// packet's review hash, conditional on the object's resourceVersion: if the
// controller re-planned while you were reading, the write fails instead of
// approving something you didn't see. The cluster records you as the
// approver from your authenticated identity, whatever this tool sends.
//
// budget shows the namespace's change budget: how many changes the
// controller may still apply without a human, and which ones.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	authnv1 "k8s.io/api/authentication/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/config"

	v1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

func main() {
	kctx := flag.String("context", "", "kubeconfig context")
	ns := flag.String("n", "approvals", "namespace")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: approvalctl [--kubeconfig F] [--context C] [-n NS] list | show NAME | approve NAME | reject NAME | budget")
		flag.PrintDefaults()
	}
	flag.Parse()
	args := flag.Args()
	if len(args) == 0 {
		flag.Usage()
		os.Exit(2)
	}
	cfg, err := config.GetConfigWithContext(*kctx)
	die(err)
	scheme := runtime.NewScheme()
	die(clientgoscheme.AddToScheme(scheme))
	die(v1.AddToScheme(scheme))
	c, err := client.New(cfg, client.Options{Scheme: scheme})
	die(err)
	ctx := context.Background()

	switch args[0] {
	case "list":
		list(ctx, c, *ns)
	case "show":
		need(args, 2)
		cr := get(ctx, c, *ns, args[1])
		printPacket(os.Stdout, cr)
	case "budget":
		budget(ctx, c, *ns)
	case "approve", "reject":
		need(args, 2)
		fs := flag.NewFlagSet(args[0], flag.ExitOnError)
		comment := fs.String("comment", "", "comment recorded with the decision")
		yes := fs.Bool("yes", false, "don't ask for confirmation")
		wait := fs.Duration("wait", 30*time.Second, "how long to wait for the controller's outcome")
		die(fs.Parse(args[2:]))
		decision := v1.DecisionApproved
		if args[0] == "reject" {
			decision = v1.DecisionRejected
		}
		decide(ctx, c, *ns, args[1], decision, *comment, *yes, *wait)
	default:
		flag.Usage()
		os.Exit(2)
	}
}

func list(ctx context.Context, c client.Client, ns string) {
	var l v1.ChangeRequestList
	die(c.List(ctx, &l, client.InNamespace(ns)))
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tPHASE\tACTION\tTARGET\tEXPIRES IN\tAPPROVER")
	for i := range l.Items {
		cr := &l.Items[i]
		approver := "-"
		if a := cr.Status.Approval; a != nil {
			approver = a.Approver
		} else if g := cr.Status.BudgetGrant; g != nil {
			approver = "budget/" + g.Budget
		}
		t := cr.Spec.Action.Target
		fmt.Fprintf(w, "%s\t%s\t%s\t%s/%s\t%s\t%s\n", cr.Name, cr.Status.Phase, cr.Spec.Action.Type,
			t.Namespace, t.Name, expiresIn(cr), approver)
	}
	die(w.Flush())
}

func decide(ctx context.Context, c client.Client, ns, name string, d v1.Decision, comment string, yes bool, wait time.Duration) {
	cr := get(ctx, c, ns, name)
	st := cr.Status
	if st.Phase != v1.PhasePending && st.Phase != v1.PhaseNeedsReapproval {
		fail("%s is %s: nothing to decide", name, st.Phase)
	}
	if st.ReviewHash == "" || st.ExpiresAt == nil {
		fail("%s has no review packet yet; try again shortly", name)
	}
	if time.Now().After(st.ExpiresAt.Time) {
		fail("%s expired at %s", name, st.ExpiresAt.UTC().Format(time.RFC3339))
	}
	printPacket(os.Stdout, cr)
	if !yes {
		fmt.Printf("\n%s exactly this plan (review hash %s)? [y/N] ", strings.ToLower(string(d[:len(d)-1])), short(st.ReviewHash))
		line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		if a := strings.TrimSpace(strings.ToLower(line)); a != "y" && a != "yes" {
			fail("not %s", strings.ToLower(string(d)))
		}
	}
	me := whoami(ctx, c)
	approval := map[string]any{
		"decision":   d,
		"approver":   me, // the cluster overwrites this with the authenticated user anyway
		"time":       time.Now().UTC().Format(time.RFC3339),
		"reviewHash": st.ReviewHash,
	}
	if comment != "" {
		approval["comment"] = comment
	}
	patch, err := json.Marshal(map[string]any{
		// Conditional write: fails with a conflict if anything changed since
		// the packet above was read.
		"metadata": map[string]any{"resourceVersion": cr.ResourceVersion},
		"status":   map[string]any{"approval": approval},
	})
	die(err)
	if err := c.Status().Patch(ctx, cr, client.RawPatch(types.MergePatchType, patch)); err != nil {
		fail("recording the decision: %v", err)
	}
	fmt.Printf("\n%s recorded as %s.\n", d, me)
	deadline := time.Now().Add(wait)
	for time.Now().Before(deadline) {
		cr = get(ctx, c, ns, name)
		if p := cr.Status.Phase; p != v1.PhasePending && p != v1.PhaseNeedsReapproval && p != v1.PhaseApplying {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	fmt.Printf("phase: %s: %s\n", cr.Status.Phase, cr.Status.Message)
	if cr.Status.Phase == v1.PhaseFailed || cr.Status.Phase == v1.PhaseExpired {
		os.Exit(1)
	}
}

func printPacket(out *os.File, cr *v1.ChangeRequest) {
	s, st, a := cr.Spec, cr.Status, cr.Spec.Action
	w := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	row := func(k, v string) { fmt.Fprintf(w, "%s\t%s\n", k, v) }
	row("ChangeRequest", cr.Namespace+"/"+cr.Name)
	row("phase", string(st.Phase))
	if st.Message != "" {
		row("message", st.Message)
	}
	fmt.Fprintln(w, "\t")
	row("AGENT'S ACCOUNT", "(free text, not verified)")
	row("intent", s.Intent)
	row("blast radius", s.BlastRadius)
	row("rollback", s.Rollback)
	fmt.Fprintln(w, "\t")
	row("REQUESTED ACTION", "(typed and schema-checked)")
	act := fmt.Sprintf("%s %s %s/%s", a.Type, a.Target.Kind, a.Target.Namespace, a.Target.Name)
	if a.Replicas != nil {
		act += fmt.Sprintf(" replicas=%d", *a.Replicas)
	}
	row("action", act)
	row("scope", fmt.Sprintf("namespaces %v, kinds %v", s.Scope.Namespaces, s.Scope.Kinds))
	fmt.Fprintln(w, "\t")
	row("COMPUTED BY THE CONTROLLER", "(exact; this is what runs)")
	if p := st.PreState; p != nil {
		rs := p.RestartedAt
		if rs == "" {
			rs = "-"
		}
		row("pre-state", fmt.Sprintf("generation %d, replicas %d, restartedAt %s", p.Generation, p.Replicas, rs))
	}
	row("plan", st.Plan)
	row("rollback plan", st.RollbackPlan)
	row("review hash", st.ReviewHash)
	if st.ExpiresAt != nil {
		row("expires", fmt.Sprintf("%s (in %s)", st.ExpiresAt.UTC().Format(time.RFC3339), expiresIn(cr)))
	}
	if ap := st.Approval; ap != nil {
		row("decision", fmt.Sprintf("%s by %s at %s", ap.Decision, ap.Approver, ap.Time.UTC().Format(time.RFC3339)))
	}
	if g := st.BudgetGrant; g != nil {
		row("decision", fmt.Sprintf("approved by change budget %s at %s (no human)", g.Budget, g.Time.UTC().Format(time.RFC3339)))
	}
	die(w.Flush())
}

func budget(ctx context.Context, c client.Client, ns string) {
	var b v1.ChangeBudget
	err := c.Get(ctx, types.NamespacedName{Namespace: ns, Name: v1.DefaultBudgetName}, &b)
	if apierrors.IsNotFound(err) {
		fmt.Printf("no change budget in %s: every change waits for an approver\n", ns)
		return
	}
	die(err)
	s := b.Spec
	window := time.Duration(s.WindowSeconds) * time.Second
	var live []v1.Grant
	for _, g := range b.Status.Grants {
		if time.Since(g.Time.Time) < window {
			live = append(live, g)
		}
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(w, "ChangeBudget\t%s/%s\n", ns, b.Name)
	fmt.Fprintf(w, "remaining\t%d of %d autonomous changes in the last %s\n", max(int(s.MaxChanges)-len(live), 0), s.MaxChanges, window)
	fmt.Fprintf(w, "covers\t%v in namespaces %v; scaling to %d-%d replicas\n", s.Actions, s.Namespaces, s.MinReplicas, s.MaxReplicas)
	for _, g := range live {
		fmt.Fprintf(w, "spent\t%s at %s (frees at %s)\n", g.ChangeRequest, g.Time.UTC().Format(time.RFC3339), g.Time.Add(window).UTC().Format(time.RFC3339))
	}
	die(w.Flush())
}

func whoami(ctx context.Context, c client.Client) string {
	r := &authnv1.SelfSubjectReview{}
	die(c.Create(ctx, r))
	return r.Status.UserInfo.Username
}

func get(ctx context.Context, c client.Client, ns, name string) *v1.ChangeRequest {
	var cr v1.ChangeRequest
	die(c.Get(ctx, types.NamespacedName{Namespace: ns, Name: name}, &cr))
	return &cr
}

func expiresIn(cr *v1.ChangeRequest) string {
	if cr.Status.ExpiresAt == nil {
		return "-"
	}
	d := time.Until(cr.Status.ExpiresAt.Time).Round(time.Second)
	if d <= 0 {
		return "expired"
	}
	return d.String()
}

func short(h string) string {
	if len(h) > 19 {
		return h[:19] + "..."
	}
	return h
}

func need(args []string, n int) {
	if len(args) < n {
		flag.Usage()
		os.Exit(2)
	}
}

func die(err error) {
	if err != nil {
		fail("%v", err)
	}
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "approvalctl: "+format+"\n", a...)
	os.Exit(1)
}
