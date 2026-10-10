// Package pricing turns token usage into an estimated cost (P4-02), from
// a price table in the gateway's configuration: the provider's list
// prices, so the estimate is only as current as the table. A model with
// no price has no cost recorded, and the gateway logs that at start.
package pricing

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/policy"
)

// Price is USD per million tokens of each kind.
type Price struct {
	Input, Output, CacheWrite, CacheRead float64
}

// Table maps a model to its price.
type Table map[string]Price

// Parse reads "model=input:output:cacheWrite:cacheRead,..." in USD per
// million tokens. The cache prices may be left out: then a cache write
// costs 1.25x input and a cache read 0.1x, the provider's usual ratios.
func Parse(s string) (Table, error) {
	t := Table{}
	for _, entry := range strings.Split(s, ",") {
		if entry = strings.TrimSpace(entry); entry == "" {
			continue
		}
		model, prices, ok := strings.Cut(entry, "=")
		if !ok {
			return nil, fmt.Errorf("%q: want model=input:output[:cacheWrite:cacheRead]", entry)
		}
		parts := strings.Split(prices, ":")
		if len(parts) != 2 && len(parts) != 4 {
			return nil, fmt.Errorf("%q: want 2 or 4 prices", entry)
		}
		var v [4]float64
		for i, p := range parts {
			f, err := strconv.ParseFloat(p, 64)
			if err != nil || f < 0 {
				return nil, fmt.Errorf("%q: bad price %q", entry, p)
			}
			v[i] = f
		}
		if len(parts) == 2 {
			v[2], v[3] = v[0]*1.25, v[0]*0.1
		}
		t[strings.TrimSpace(model)] = Price{Input: v[0], Output: v[1], CacheWrite: v[2], CacheRead: v[3]}
	}
	return t, nil
}

// Cost of u on model in USD, and whether the model has a price.
func (t Table) Cost(model string, u policy.Usage) (float64, bool) {
	p, ok := t[model]
	if !ok {
		return 0, false
	}
	return (float64(u.InputTokens)*p.Input + float64(u.OutputTokens)*p.Output +
		float64(u.CacheCreationInputTokens)*p.CacheWrite + float64(u.CacheReadInputTokens)*p.CacheRead) / 1e6, true
}
