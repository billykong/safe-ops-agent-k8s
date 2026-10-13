// approvalctl: review and decide ChangeRequests (P2-41).
//
//	approvalctl [--kubeconfig F] [--context C] [-n NS] list
//	approvalctl ... show NAME
//	approvalctl ... approve NAME [--comment TEXT] [--yes] [--wait 30s] [--accept-critical]
//	approvalctl ... reject  NAME [--comment TEXT] [--yes] [--wait 30s]
//	approvalctl ... budget
//	approvalctl ... stats
//
// approve/reject show the review packet the controller recorded, ask for
// confirmation, then write the decision to the status subresource with the
// packet's review hash, conditional on the object's resourceVersion: if the
// controller re-planned while you were reading, the write fails instead of
// approving something you didn't see. The cluster records you as the
// approver from your authenticated identity, whatever this tool sends.
//
// The packet shows what the controller computed from the cluster first
// (diff from a server-side dry run, blast radius, rule findings, rollback
// check, budget), and the agent's own account last, labelled as unverified
// (P2-40). Approving a request with a Critical finding needs
// --accept-critical.
//
// budget shows the namespace's change budget: how many changes the
// controller may still apply without a human, and which ones. stats shows
// the oversight metrics (P2-42): outcomes, time to decide, and per-approver
// approval rates, including approvals of flagged requests.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"sort"
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
	"github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/internal/oversight"
)

func main() {
	kctx := flag.String("context", "", "kubeconfig context")
	ns := flag.String("n", "approvals", "namespace")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: approvalctl [--kubeconfig F] [--context C] [-n NS] list | show NAME | approve NAME | reject NAME | budget | stats")
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
		printPacket(os.Stdout, cr, budgetLine(ctx, c, *ns))
	case "budget":
		budget(ctx, c, *ns)
	case "stats":
		stats(ctx, c, *ns)
	case "approve", "reject":
		need(args, 2)
		fs := flag.NewFlagSet(args[0], flag.ExitOnError)
		comment := fs.String("comment", "", "comment recorded with the decision")
		yes := fs.Bool("yes", false, "don't ask for confirmation")
		wait := fs.Duration("wait", 30*time.Second, "how long to wait for the controller's outcome")
		acceptCritical := fs.Bool("accept-critical", false, "approve even though the review found Critical problems")
		die(fs.Parse(args[2:]))
		decision := v1.DecisionApproved
		if args[0] == "reject" {
			decision = v1.DecisionRejected
		}
		decide(ctx, c, *ns, args[1], decision, *comment, *yes, *wait, *acceptCritical)
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

func decide(ctx context.Context, c client.Client, ns, name string, d v1.Decision, comment string, yes bool, wait time.Duration, acceptCritical bool) {
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
	printPacket(os.Stdout, cr, budgetLine(ctx, c, ns))
	if d == v1.DecisionApproved && st.Review != nil && !acceptCritical {
		for _, f := range st.Review.Findings {
			if f.Severity == v1.SeverityCritical {
				fail("%s has Critical findings (above); reject it, or approve with --accept-critical if you've checked them", name)
			}
		}
	}
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

func printPacket(out *os.File, cr *v1.ChangeRequest, budget string) {
	s, st, a := cr.Spec, cr.Status, cr.Spec.Action
	w := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	row := func(k, v string) { fmt.Fprintf(w, "%s\t%s\n", k, v) }
	more := func(v string) { row("", v) }
	row("ChangeRequest", cr.Namespace+"/"+cr.Name)
	row("phase", string(st.Phase))
	if st.Message != "" {
		row("message", st.Message)
	}
	fmt.Fprintln(w, "\t")
	row("COMPUTED BY THE CONTROLLER", "(from the cluster, by code; this is what runs)")
	act := fmt.Sprintf("%s %s %s/%s", a.Type, a.Target.Kind, a.Target.Namespace, a.Target.Name)
	if a.Replicas != nil {
		act += fmt.Sprintf(" replicas=%d", *a.Replicas)
	}
	row("action", act+"  (typed, schema-checked)")
	row("scope", fmt.Sprintf("namespaces %v, kinds %v", s.Scope.Namespaces, s.Scope.Kinds))
	if p := st.PreState; p != nil {
		rs := p.RestartedAt
		if rs == "" {
			rs = "-"
		}
		row("pre-state", fmt.Sprintf("generation %d, replicas %d, restartedAt %s", p.Generation, p.Replicas, rs))
	}
	if rv := st.Review; rv != nil {
		if len(rv.Diff) == 0 {
			row("diff", "(none)")
		}
		for i, d := range rv.Diff {
			k := ""
			if i == 0 {
				k = "diff"
			}
			row(k, fmt.Sprintf("%s: %s -> %s", d.Path, orNone(d.From), orNone(d.To)))
		}
		row("dry run", rv.DryRun)
		br := rv.BlastRadius
		row("blast radius", br.Summary)
		more(fmt.Sprintf("ready now %d of %d; disruption budgets: %s", br.ReadyBefore, br.ReplicasBefore, orNone(strings.Join(br.DisruptionBudgets, ", "))))
		if len(rv.Findings) == 0 {
			row("findings", "(none)")
		}
		for i, f := range rv.Findings {
			k := ""
			if i == 0 {
				k = "findings"
			}
			row(k, fmt.Sprintf("%s %s: %s", strings.ToUpper(string(f.Severity)), f.Code, f.Message))
		}
	} else {
		row("review", "(not computed yet)")
	}
	if rv := st.Review; rv != nil && rv.Policy != nil {
		for i, r := range append([]string{string(rv.Policy.Result)}, rv.Policy.Reasons...) {
			k := ""
			if i == 0 {
				k = "policy"
			}
			if i > 0 {
				r = "- " + r
			}
			row(k, r)
		}
	}
	row("plan", st.Plan)
	row("rollback plan", st.RollbackPlan)
	if st.Review != nil {
		row("rollback check", st.Review.RollbackCheck)
	}
	row("budget", budget)
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
	// Shown only once it's final: the controller writes it then (P4-15).
	if sd := st.Seeded; sd != nil {
		row("seeded test", fmt.Sprintf("a known-%s proposal (expected: %s): %s", map[bool]string{true: "bad", false: "good"}[sd.Expected == v1.DecisionRejected], sd.Expected, sd.Reason))
		more(fmt.Sprintf("automated review: %s; human: %s %s", sd.Automated, sd.Human, sd.Approver))
	}
	fmt.Fprintln(w, "\t")
	row("PROPOSER'S ACCOUNT", "(free text from the agent, not verified: weigh it last)")
	row("intent", s.Intent)
	row("blast radius", s.BlastRadius+"  (claimed)")
	row("rollback", s.Rollback+"  (claimed)")
	die(w.Flush())
}

func orNone(v string) string {
	if v == "" {
		return "(none)"
	}
	return v
}

// budgetLine summarises the change budget right now, for the packet.
func budgetLine(ctx context.Context, c client.Client, ns string) string {
	var b v1.ChangeBudget
	err := c.Get(ctx, types.NamespacedName{Namespace: ns, Name: v1.DefaultBudgetName}, &b)
	if apierrors.IsNotFound(err) {
		return "no change budget: every change needs an approver"
	}
	if err != nil {
		return "unknown: " + err.Error()
	}
	window := time.Duration(b.Spec.WindowSeconds) * time.Second
	used := 0
	for _, g := range b.Status.Grants {
		if time.Since(g.Time.Time) < window {
			used++
		}
	}
	return fmt.Sprintf("%d of %d autonomous changes left in the last %s", max(int(b.Spec.MaxChanges)-used, 0), b.Spec.MaxChanges, window)
}

func stats(ctx context.Context, c client.Client, ns string) {
	var l v1.ChangeRequestList
	die(c.List(ctx, &l, client.InNamespace(ns)))
	r := oversight.Compute(l.Items)
	phases := []string{}
	for p, n := range r.ByPhase {
		phases = append(phases, fmt.Sprintf("%s %d", p, n))
	}
	sort.Strings(phases)
	fmt.Printf("ChangeRequests in %s: %d (%s)\n", ns, r.Total, strings.Join(phases, ", "))
	fmt.Printf("settled by: humans %d, change budget %d, controller %d, expiry %d, kill switch %d\n",
		r.ByHuman, r.ByBudget, r.ByController, r.Expired, r.Cancelled)
	fmt.Printf("re-proposed after drift: %d\n", r.Reproposed)
	reopen := "-"
	if r.Applied > 0 {
		reopen = fmt.Sprintf("%.0f%%", 100*float64(r.Reopened)/float64(r.Applied))
	}
	fmt.Printf("applied: %d, reopened within %s: %d (%s)\n", r.Applied, oversight.ReopenWindow, r.Reopened, reopen)
	fmt.Printf("time to decision: humans median %s, p90 %s; change budget median %s\n",
		dur(oversight.Quantile(r.HumanSeconds, 0.5)), dur(oversight.Quantile(r.HumanSeconds, 0.9)), dur(oversight.Quantile(r.BudgetSeconds, 0.5)))
	pct := func(v float64) string {
		if math.IsNaN(v) {
			return "-"
		}
		return fmt.Sprintf("%.0f%%", 100*v)
	}
	sa := r.SeededAutomated
	fmt.Printf("seeded test proposals (P4-15): automated review caught %d of %d known-bad (%s), %d false alarms on known-good; %d withheld\n\n",
		sa[v1.SeedCaught], sa[v1.SeedCaught]+sa[v1.SeedMissed], pct(oversight.CatchRate(sa)), sa[v1.SeedFalseAlarm], r.Withheld)
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "APPROVER\tAPPROVED\tREJECTED\tAPPROVAL RATE\tMEDIAN TIME\tP90 TIME\tAPPROVED FLAGGED\tAPPROVED CRITICAL\tSEEDED CAUGHT")
	for _, a := range r.Approvers {
		rate := "-"
		if v := a.ApprovalRate(); !math.IsNaN(v) {
			rate = fmt.Sprintf("%.0f%%", 100*v)
		}
		so := r.SeededHuman[a.Name]
		seeded := "-"
		if n := so[v1.SeedCaught] + so[v1.SeedMissed]; n > 0 {
			seeded = fmt.Sprintf("%d of %d (%s)", so[v1.SeedCaught], n, pct(oversight.CatchRate(so)))
		}
		fmt.Fprintf(w, "%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%s\n", a.Name, a.Approved, a.Rejected, rate,
			dur(oversight.Quantile(a.Seconds, 0.5)), dur(oversight.Quantile(a.Seconds, 0.9)), a.ApprovedFlagged, a.ApprovedCritical, seeded)
	}
	die(w.Flush())
}

func dur(secs float64) string {
	if math.IsNaN(secs) {
		return "-"
	}
	return (time.Duration(secs) * time.Second).Round(time.Second).String()
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
