// mockmodel: a stand-in for the model provider's Messages API, for tests
// that must be deterministic and free (P3). It answers POST /v1/messages
// in the API's shape, driven by directives in the last user message:
//
//	[mock:500]                    HTTP 500 (provider failure)
//	[mock:slow:N]                 wait N seconds first
//	[mock:refusal]                stop_reason "refusal"
//	[mock:text]                   a text answer, no tool call
//	[mock:usage:N]                report N output tokens
//	[mock:tool:NAME:{json}]       call tool NAME with exactly this input:
//	                              a model that complies with anything
//
// Without a tool directive it does what a sensible model would with the
// agent's tools: "scale ... to N" -> propose_scale_deployment, "restart"
// -> propose_restart_deployment, anything else -> escalate_to_human.
//
// It requires the provider key the gateway should send, and records the
// headers of the last request it got (GET /debug/last), so tests can check
// what left the gateway.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	mu   sync.Mutex
	last map[string]any
	n    int
)

var (
	reSlow  = regexp.MustCompile(`\[mock:slow:(\d+)\]`)
	reUsage = regexp.MustCompile(`\[mock:usage:(\d+)\]`)
	reTool  = regexp.MustCompile(`\[mock:tool:([a-z_]+):(\{.*?\})\]`)
	reScale = regexp.MustCompile(`(?i)scale\b.*?\bto (\d+)`)
	reInstr = regexp.MustCompile(`(?s)<instruction>(.*)</instruction>`)
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	keyFile := os.Getenv("API_KEY_FILE")
	http.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok\n")) })
	http.HandleFunc("GET /debug/last", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"requests": n, "last": last})
	})
	http.HandleFunc("POST /v1/messages", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		hdr := map[string]string{}
		for k, v := range r.Header {
			hdr[strings.ToLower(k)] = strings.Join(v, ",")
		}
		key, _ := os.ReadFile(keyFile)
		keyOK := hdr["x-api-key"] == strings.TrimSpace(string(key)) && len(strings.TrimSpace(string(key))) > 0
		if keyOK {
			hdr["x-api-key"] = "(the expected key)"
		} else if hdr["x-api-key"] != "" {
			hdr["x-api-key"] = "(WRONG KEY)"
		}
		mu.Lock()
		n++
		last = map[string]any{"headers": hdr, "body": json.RawMessage(body)}
		mu.Unlock()
		if !keyOK {
			apiError(w, 401, "authentication_error", "invalid x-api-key")
			return
		}
		var req struct {
			Model    string `json:"model"`
			Messages []struct {
				Role    string          `json:"role"`
				Content json.RawMessage `json:"content"`
			} `json:"messages"`
			Tools []struct {
				Name string `json:"name"`
			} `json:"tools"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			apiError(w, 400, "invalid_request_error", "bad JSON")
			return
		}
		text := ""
		for i := len(req.Messages) - 1; i >= 0; i-- {
			if req.Messages[i].Role == "user" {
				text = textOf(req.Messages[i].Content)
				break
			}
		}
		// Heuristics read only the operator's instruction when the agent
		// marks it, not the observed state around it.
		intent := text
		if m := reInstr.FindStringSubmatch(text); m != nil {
			intent = m[1]
		}
		if m := reSlow.FindStringSubmatch(text); m != nil {
			s, _ := strconv.Atoi(m[1])
			time.Sleep(time.Duration(s) * time.Second)
		}
		if strings.Contains(text, "[mock:500]") {
			apiError(w, 500, "api_error", "mock provider failure")
			return
		}
		out := 60
		if m := reUsage.FindStringSubmatch(text); m != nil {
			out, _ = strconv.Atoi(m[1])
		}
		resp := map[string]any{
			"id": fmt.Sprintf("msg_mock_%d", time.Now().UnixNano()), "type": "message", "role": "assistant",
			"model": req.Model, "stop_sequence": nil, "stop_details": nil,
			"usage": map[string]int{"input_tokens": len(body) / 4, "output_tokens": out},
		}
		hasTool := func(name string) bool {
			for _, t := range req.Tools {
				if t.Name == name {
					return true
				}
			}
			return false
		}
		toolUse := func(name string, input any) {
			resp["stop_reason"] = "tool_use"
			resp["content"] = []any{map[string]any{"type": "tool_use", "id": fmt.Sprintf("toolu_mock_%d", time.Now().UnixNano()), "name": name, "input": input}}
		}
		switch {
		case strings.Contains(text, "[mock:refusal]"):
			resp["stop_reason"] = "refusal"
			resp["content"] = []any{}
			resp["stop_details"] = map[string]any{"type": "refusal", "category": "cyber", "explanation": "mock refusal"}
		case strings.Contains(text, "[mock:text]") || len(req.Tools) == 0:
			resp["stop_reason"] = "end_turn"
			resp["content"] = []any{map[string]any{"type": "text", "text": "I can't tell what to do here."}}
		case reTool.MatchString(text):
			m := reTool.FindStringSubmatch(text)
			var input any
			if json.Unmarshal([]byte(m[2]), &input) != nil {
				input = map[string]any{}
			}
			toolUse(m[1], input)
		case reScale.MatchString(intent) && hasTool("propose_scale_deployment"):
			r, _ := strconv.Atoi(reScale.FindStringSubmatch(intent)[1])
			toolUse("propose_scale_deployment", map[string]any{"replicas": r, "reason": "the instruction asks for " + strconv.Itoa(r) + " replicas"})
		case strings.Contains(strings.ToLower(intent), "restart") && hasTool("propose_restart_deployment"):
			toolUse("propose_restart_deployment", map[string]any{"reason": "the instruction asks for a restart"})
		default:
			toolUse("escalate_to_human", map[string]any{"reason": "the instruction doesn't map to an allowed action"})
		}
		log.Info("answered", "model", req.Model, "stop_reason", resp["stop_reason"])
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("request-id", fmt.Sprintf("req_mock_%d", time.Now().UnixNano()))
		json.NewEncoder(w).Encode(resp)
	})
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Error("serve", "err", err)
		os.Exit(1)
	}
}

// textOf joins the text of a message's content (string or blocks).
func textOf(c json.RawMessage) string {
	var s string
	if json.Unmarshal(c, &s) == nil {
		return s
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	json.Unmarshal(c, &blocks)
	var b strings.Builder
	for _, x := range blocks {
		if x.Type == "text" {
			b.WriteString(x.Text + "\n")
		}
	}
	return b.String()
}

func apiError(w http.ResponseWriter, code int, typ, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{"type": "error", "error": map[string]string{"type": typ, "message": msg}})
}
