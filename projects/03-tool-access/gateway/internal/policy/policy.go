// Package policy decides which model requests the gateway forwards
// (P3-02). The agent's request is checked as data before anything leaves
// the cluster: an allowed model, a bounded max_tokens, no streaming (the
// budget needs the final usage), and no capability that would let the
// model act outside our network fence.
//
// That last point is why server tools are refused: web search, web fetch,
// code execution and remote MCP servers run on the provider's
// infrastructure, not in the cluster, so Cilium's egress rules never see
// them. A prompt-injected model with web_fetch could send the agent's
// context to any URL. The agent gets only its own client-side tools,
// whose effects go through our gates.
package policy

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
)

// Config is what the gateway allows.
type Config struct {
	Models       []string
	MaxTokensCap int
	// Betas the agent may send in anthropic-beta.
	Betas []string
	// Fallbacks values allowed for the fallbacks parameter ("default").
	Fallbacks []string
}

// Request is the part of a Messages API request the gateway inspects.
type Request struct {
	Model     string
	MaxTokens int
}

// Refusal is a request the gateway won't forward, with why.
type Refusal struct{ Reason string }

func (r *Refusal) Error() string { return r.Reason }

// Check validates a request body and the anthropic-beta header values.
func Check(cfg Config, body []byte, betas []string) (Request, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		return Request{}, &Refusal{"body is not a JSON object"}
	}
	var req Request
	if err := json.Unmarshal(raw["model"], &req.Model); err != nil || req.Model == "" {
		return req, &Refusal{"model is required"}
	}
	if !slices.Contains(cfg.Models, req.Model) {
		return req, &Refusal{fmt.Sprintf("model %q is not allowed (allowed: %v)", req.Model, cfg.Models)}
	}
	if err := json.Unmarshal(raw["max_tokens"], &req.MaxTokens); err != nil || req.MaxTokens <= 0 {
		return req, &Refusal{"max_tokens is required"}
	}
	if req.MaxTokens > cfg.MaxTokensCap {
		return req, &Refusal{fmt.Sprintf("max_tokens %d exceeds the gateway's cap of %d", req.MaxTokens, cfg.MaxTokensCap)}
	}
	if s, ok := raw["stream"]; ok && string(s) != "false" {
		return req, &Refusal{"streaming is not supported through the gateway"}
	}
	for _, field := range []string{"mcp_servers", "container", "speed"} {
		if _, ok := raw[field]; ok {
			return req, &Refusal{fmt.Sprintf("%s is not allowed: it runs outside the cluster's network controls", field)}
		}
	}
	if f, ok := raw["fallbacks"]; ok {
		var v string
		if err := json.Unmarshal(f, &v); err != nil || !slices.Contains(cfg.Fallbacks, v) {
			return req, &Refusal{fmt.Sprintf("fallbacks must be one of %v", cfg.Fallbacks)}
		}
	}
	if t, ok := raw["tools"]; ok {
		var tools []map[string]json.RawMessage
		if err := json.Unmarshal(t, &tools); err != nil {
			return req, &Refusal{"tools must be a list"}
		}
		for _, tool := range tools {
			var typ, name string
			_ = json.Unmarshal(tool["type"], &typ)
			_ = json.Unmarshal(tool["name"], &name)
			if typ != "" && typ != "custom" {
				return req, &Refusal{fmt.Sprintf("server tool %q (%s) is not allowed: it runs outside the cluster's network controls", name, typ)}
			}
			if _, ok := tool["input_schema"]; !ok {
				return req, &Refusal{fmt.Sprintf("tool %q has no input_schema: only client-side tools are allowed", name)}
			}
		}
	}
	for _, b := range betas {
		for _, v := range strings.Split(b, ",") {
			if v = strings.TrimSpace(v); v != "" && !slices.Contains(cfg.Betas, v) {
				return req, &Refusal{fmt.Sprintf("beta %q is not allowed", v)}
			}
		}
	}
	return req, nil
}

// Usage is the token usage in a Messages API response.
type Usage struct {
	InputTokens              int `json:"input_tokens"`
	OutputTokens             int `json:"output_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
}

// Total is what the budget charges: every token processed.
func (u Usage) Total() int {
	return u.InputTokens + u.OutputTokens + u.CacheCreationInputTokens + u.CacheReadInputTokens
}

// ParseUsage reads usage from a response body, if present.
func ParseUsage(body []byte) (Usage, bool) {
	var r struct {
		Usage *Usage `json:"usage"`
	}
	if json.Unmarshal(body, &r) != nil || r.Usage == nil {
		return Usage{}, false
	}
	return *r.Usage, true
}
