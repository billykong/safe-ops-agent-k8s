package pricing

import (
	"math"
	"testing"

	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/policy"
)

func TestParseAndCost(t *testing.T) {
	tab, err := Parse("claude-opus-5-5=5:25, other=1:2:3:4")
	if err != nil {
		t.Fatal(err)
	}
	if p := tab["claude-opus-5-5"]; p.CacheWrite != 6.25 || p.CacheRead != 0.5 {
		t.Errorf("default cache prices: %+v", p)
	}
	c, ok := tab.Cost("claude-opus-5-5", policy.Usage{InputTokens: 1000, OutputTokens: 200, CacheReadInputTokens: 10000})
	if want := (1000*5.0 + 200*25.0 + 10000*0.5) / 1e6; !ok || math.Abs(c-want) > 1e-12 {
		t.Errorf("cost = %v, %v; want %v", c, ok, want)
	}
	if _, ok := tab.Cost("unpriced", policy.Usage{InputTokens: 1}); ok {
		t.Error("an unpriced model has a cost")
	}
	for _, bad := range []string{"m", "m=1", "m=1:2:3", "m=x:1", "m=-1:2"} {
		if _, err := Parse(bad); err == nil {
			t.Errorf("Parse(%q) accepted", bad)
		}
	}
}
