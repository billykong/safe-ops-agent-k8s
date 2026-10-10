// Package gate evaluates the semantic action gate (P3-10): the Rego policy
// in policy/gate.rego, embedded with OPA's Go library, over a proposal's
// computed effect. It fails closed: a missing, unloadable or failing policy
// gives Deny, never Allow.
package gate

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"

	"github.com/open-policy-agent/opa/v1/rego"

	approvalv1alpha1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

const query = "data.safeops.gate.decision"

// Gate is a loaded policy.
type Gate struct {
	prepared rego.PreparedEvalQuery
	// SHA identifies the policy text in every decision.
	SHA string
}

// Load compiles a policy file.
func Load(ctx context.Context, path string) (*Gate, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Compile(ctx, path, string(src))
}

// Compile prepares a policy from source.
func Compile(ctx context.Context, name, src string) (*Gate, error) {
	pq, err := rego.New(rego.Query(query), rego.Module(name, src)).PrepareForEval(ctx)
	if err != nil {
		return nil, fmt.Errorf("policy %s: %w", name, err)
	}
	sum := sha256.Sum256([]byte(src))
	return &Gate{prepared: pq, SHA: "sha256:" + hex.EncodeToString(sum[:])}, nil
}

func deny(sha, why string) *approvalv1alpha1.PolicyDecision {
	return &approvalv1alpha1.PolicyDecision{Result: approvalv1alpha1.PolicyDeny, Reasons: []string{why}, PolicySHA: sha}
}

// Decide evaluates the policy. A nil gate (no policy loaded) denies.
func (g *Gate) Decide(ctx context.Context, input map[string]any) *approvalv1alpha1.PolicyDecision {
	if g == nil {
		return deny("", "no policy is loaded (fail closed)")
	}
	rs, err := g.prepared.Eval(ctx, rego.EvalInput(input))
	if err != nil {
		return deny(g.SHA, "policy evaluation failed (fail closed): "+err.Error())
	}
	if len(rs) != 1 || len(rs[0].Expressions) != 1 {
		return deny(g.SHA, "the policy produced no decision (fail closed)")
	}
	m, ok := rs[0].Expressions[0].Value.(map[string]any)
	if !ok {
		return deny(g.SHA, "the policy's decision isn't an object (fail closed)")
	}
	result, _ := m["result"].(string)
	d := &approvalv1alpha1.PolicyDecision{Result: approvalv1alpha1.PolicyResult(result), PolicySHA: g.SHA}
	switch d.Result {
	case approvalv1alpha1.PolicyAllow, approvalv1alpha1.PolicyEscalate, approvalv1alpha1.PolicyDeny:
	default:
		return deny(g.SHA, fmt.Sprintf("the policy returned an unknown result %q (fail closed)", result))
	}
	if rs, ok := m["reasons"].([]any); ok {
		for _, r := range rs {
			if s, ok := r.(string); ok {
				d.Reasons = append(d.Reasons, s)
			}
		}
	}
	return d
}
