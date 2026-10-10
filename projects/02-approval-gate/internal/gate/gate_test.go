package gate

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/open-policy-agent/opa/v1/tester"

	v1 "github.com/billykong/safe-ops-agent-k8s/projects/02-approval-gate/api/v1alpha1"
)

// The policy's own unit tests (policy/gate_test.rego), run by OPA's tester.
func TestRegoPolicy(t *testing.T) {
	results, err := tester.Run(context.Background(), filepath.Join("..", "..", "policy"))
	if err != nil {
		t.Fatal(err)
	}
	if len(results) < 10 {
		t.Fatalf("only %d Rego tests found", len(results))
	}
	for _, r := range results {
		if r.Fail || r.Error != nil {
			t.Errorf("rego %s: fail=%v err=%v", r.Name, r.Fail, r.Error)
		}
	}
}

func input(after int, labels map[string]any) map[string]any {
	return map[string]any{
		"action":    map[string]any{"type": "ScaleDeployment", "target": map[string]any{"namespace": "workloads", "name": "web"}},
		"target":    map[string]any{"labels": labels},
		"namespace": map[string]any{"name": "workloads", "labels": map[string]any{"safe-ops.io/agent-managed": "true", "safe-ops.io/max-replicas": "20"}},
		"review":    map[string]any{"dryRun": "accepted", "rollbackCheck": "passed", "findings": []any{}, "blastRadius": map[string]any{"replicasAfter": after}},
	}
}

func TestDecide(t *testing.T) {
	g, err := Load(context.Background(), filepath.Join("..", "..", "policy", "gate.rego"))
	if err != nil {
		t.Fatal(err)
	}
	if d := g.Decide(context.Background(), input(2, map[string]any{})); d.Result != v1.PolicyAllow || !strings.HasPrefix(d.PolicySHA, "sha256:") {
		t.Errorf("allow: %+v", d)
	}
	d := g.Decide(context.Background(), input(25, map[string]any{}))
	if d.Result != v1.PolicyDeny || len(d.Reasons) != 1 || !strings.Contains(d.Reasons[0], "ceiling of 20") {
		t.Errorf("ceiling: %+v", d)
	}
}

func TestFailClosed(t *testing.T) {
	var none *Gate
	if d := none.Decide(context.Background(), input(2, nil)); d.Result != v1.PolicyDeny {
		t.Errorf("no policy: %+v", d)
	}
	g, err := Compile(context.Background(), "x.rego", "package safeops.gate\nimport rego.v1\ndecision := {\"result\": \"Maybe\"}\n")
	if err != nil {
		t.Fatal(err)
	}
	if d := g.Decide(context.Background(), input(2, nil)); d.Result != v1.PolicyDeny || !strings.Contains(d.Reasons[0], "unknown result") {
		t.Errorf("unknown result: %+v", d)
	}
	g, _ = Compile(context.Background(), "y.rego", "package safeops.gate\nimport rego.v1\nother := 1\n")
	if d := g.Decide(context.Background(), input(2, nil)); d.Result != v1.PolicyDeny {
		t.Errorf("no decision rule: %+v", d)
	}
	if _, err := Compile(context.Background(), "z.rego", "package safeops.gate\nthis is not rego"); err == nil {
		t.Error("broken policy compiled")
	}
}
