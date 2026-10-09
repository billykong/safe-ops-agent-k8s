package policy

import (
	"errors"
	"testing"
)

var cfg = Config{Models: []string{"claude-opus-5-5"}, MaxTokensCap: 16000,
	Betas: []string{"server-side-fallback-2026-07-01"}, Fallbacks: []string{"default"}}

func TestCheck(t *testing.T) {
	tool := `{"name":"propose_restart_deployment","strict":true,"input_schema":{"type":"object"}}`
	cases := []struct {
		name  string
		body  string
		betas []string
		ok    bool
	}{
		{"plain", `{"model":"claude-opus-5-5","max_tokens":1000,"messages":[]}`, nil, true},
		{"client tool, fallbacks, beta", `{"model":"claude-opus-5-5","max_tokens":1000,"fallbacks":"default","tools":[` + tool + `]}`,
			[]string{"server-side-fallback-2026-07-01"}, true},
		{"other model", `{"model":"claude-fable-5-1","max_tokens":1000}`, nil, false},
		{"over cap", `{"model":"claude-opus-5-5","max_tokens":64000}`, nil, false},
		{"no max_tokens", `{"model":"claude-opus-5-5"}`, nil, false},
		{"streaming", `{"model":"claude-opus-5-5","max_tokens":10,"stream":true}`, nil, false},
		{"web fetch", `{"model":"claude-opus-5-5","max_tokens":10,"tools":[{"type":"web_fetch_20260209","name":"web_fetch"}]}`, nil, false},
		{"code execution", `{"model":"claude-opus-5-5","max_tokens":10,"tools":[{"type":"code_execution_20260521","name":"code_execution"}]}`, nil, false},
		{"remote MCP", `{"model":"claude-opus-5-5","max_tokens":10,"mcp_servers":[{"type":"url","url":"https://x","name":"x"}]}`, nil, false},
		{"skills container", `{"model":"claude-opus-5-5","max_tokens":10,"container":{"skills":[]}}`, nil, false},
		{"pinned fallback model", `{"model":"claude-opus-5-5","max_tokens":10,"fallbacks":[{"model":"claude-opus-4-8"}]}`, nil, false},
		{"unlisted beta", `{"model":"claude-opus-5-5","max_tokens":10}`, []string{"mcp-client-2025-11-20"}, false},
		{"one bad beta among several", `{"model":"claude-opus-5-5","max_tokens":10}`, []string{"server-side-fallback-2026-07-01, files-api-2025-04-14"}, false},
		{"not JSON", `nope`, nil, false},
	}
	for _, c := range cases {
		_, err := Check(cfg, []byte(c.body), c.betas)
		var r *Refusal
		if c.ok != (err == nil) || (err != nil && !errors.As(err, &r)) {
			t.Errorf("%s: err %v, want ok=%v", c.name, err, c.ok)
		}
	}
}

func TestUsage(t *testing.T) {
	u, ok := ParseUsage([]byte(`{"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100}}`))
	if !ok || u.Total() != 115 {
		t.Errorf("usage %+v %v", u, ok)
	}
	if _, ok := ParseUsage([]byte(`{"type":"error"}`)); ok {
		t.Error("usage from an error body")
	}
}
