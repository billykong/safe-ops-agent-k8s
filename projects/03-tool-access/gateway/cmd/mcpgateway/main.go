// mcpgateway: the agents' only way to MCP tools (P3-04, P3-20, P3-21).
//
//	POST /mcp/<server>   one JSON-RPC message (MCP streamable HTTP, JSON responses)
//	mcpgateway pins <url>   print the descriptor pins of a server's tools, for review
//
// Each request is authenticated by workload identity (audience
// mcp-gateway.safe-ops.io) and served from a static registry
// (internal/mcpreg):
//   - initialize: answered with the upstream's protocol version and a
//     tools-only capability set; the server's free-text "instructions"
//     never reach the agent;
//   - tools/list: only tools this identity may use whose descriptors
//     still match their pins; anything else is hidden and logged;
//   - tools/call: the same check, made again against the server's current
//     descriptors at call time, then forwarded with the server's credential
//     (added here, never seen by the agent); the result is capped in size;
//   - every other method (resources, prompts, sampling, ...) is refused.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"

	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/authn"
	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/mcpreg"
)

const maxBody = 256 << 10

type gateway struct {
	log       *slog.Logger
	authn     *authn.Authenticator
	reg       *mcpreg.Registry
	client    *http.Client
	maxResult int
}

type rpcMsg struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	fail := func(msg string, err error) { log.Error(msg, "err", err); os.Exit(1) }
	client := &http.Client{Timeout: 30 * time.Second}
	if len(os.Args) == 3 && os.Args[1] == "pins" {
		if err := printPins(client, os.Args[2]); err != nil {
			fail("pins", err)
		}
		return
	}
	reg, err := mcpreg.Load(env("REGISTRY", "/etc/safe-ops/mcp/registry.json"))
	if err != nil {
		fail("registry", err)
	}
	cfg, err := rest.InClusterConfig()
	if err != nil {
		fail("in-cluster config", err)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		fail("client", err)
	}
	ttl, err := time.ParseDuration(env("REVIEW_CACHE_TTL", "10s"))
	if err != nil {
		fail("REVIEW_CACHE_TTL", err)
	}
	maxResult, err := strconv.Atoi(env("MAX_RESULT_BYTES", "16384"))
	if err != nil {
		fail("MAX_RESULT_BYTES", err)
	}
	var allowed []string
	for id := range reg.Identities {
		allowed = append(allowed, id)
	}
	g := &gateway{
		log: log, reg: reg, client: client, maxResult: maxResult,
		authn: &authn.Authenticator{Reviewer: cs.AuthenticationV1().TokenReviews(),
			Audience: env("AUDIENCE", "mcp-gateway.safe-ops.io"), Allowed: allowed, CacheTTL: ttl},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok\n")) })
	mux.HandleFunc("POST /mcp/{server}", g.serve)
	// No server-to-client stream and no sessions: GET and DELETE aren't offered.
	mux.HandleFunc("/mcp/{server}", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusMethodNotAllowed)
	})
	log.Info("listening", "servers", len(reg.Servers), "identities", allowed, "maxResultBytes", maxResult)
	srv := &http.Server{Addr: env("LISTEN", ":8080"), Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		fail("serve", err)
	}
}

func (g *gateway) serve(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	server := r.PathValue("server")
	id, err := g.authn.Authenticate(r.Context(), r)
	if err != nil {
		code := http.StatusServiceUnavailable
		switch {
		case errors.Is(err, authn.ErrUnauthenticated):
			code = http.StatusUnauthorized
		case errors.Is(err, authn.ErrForbidden):
			code = http.StatusForbidden
		}
		g.log.Info("mcp", "server", server, "status", code, "identity", id.Username, "reason", err.Error())
		http.Error(w, err.Error(), code)
		return
	}
	srv, known := g.reg.Servers[server]
	if !known || !g.reg.HasServer(id.Username, server) {
		g.log.Info("mcp", "server", server, "status", 403, "identity", id.Username, "reason", "server not allowed for this identity")
		http.Error(w, fmt.Sprintf("%s may not use MCP server %q", id.Username, server), http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil || len(body) > maxBody {
		http.Error(w, "request too large", http.StatusRequestEntityTooLarge)
		return
	}
	var msg rpcMsg
	if err := json.Unmarshal(body, &msg); err != nil || msg.JSONRPC != "2.0" {
		http.Error(w, "one JSON-RPC 2.0 message per request (no batches)", http.StatusBadRequest)
		return
	}
	audit := func(outcome string, kv ...any) {
		g.log.Info("mcp", append([]any{"server", server, "method", msg.Method, "identity", id.Username, "pod", id.Pod,
			"credentialID", id.CredentialID, "outcome", outcome, "ms", time.Since(start).Milliseconds()}, kv...)...)
	}
	fwd := forwardHeaders(r)
	switch msg.Method {
	case "notifications/initialized", "notifications/cancelled":
		w.WriteHeader(http.StatusAccepted)
		return
	case "ping":
		reply(w, msg.ID, json.RawMessage(`{}`), nil)
	case "initialize":
		res, err := g.upstream(srv, body, fwd, false)
		if err != nil {
			audit("upstream error", "reason", err.Error())
			reply(w, msg.ID, nil, &rpcError{-32000, "tool server unavailable: " + err.Error()})
			return
		}
		var init struct {
			ProtocolVersion string `json:"protocolVersion"`
			ServerInfo      struct {
				Name    string `json:"name"`
				Version string `json:"version"`
			} `json:"serverInfo"`
		}
		json.Unmarshal(res, &init)
		out, _ := json.Marshal(map[string]any{
			"protocolVersion": init.ProtocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
			"serverInfo":      map[string]string{"name": "mcp-gateway/" + server, "version": init.ServerInfo.Version},
		})
		audit("ok")
		reply(w, msg.ID, out, nil)
	case "tools/list":
		tools, verdicts, err := g.verified(srv, fwd)
		if err != nil {
			audit("upstream error", "reason", err.Error())
			reply(w, msg.ID, nil, &rpcError{-32000, "tool server unavailable: " + err.Error()})
			return
		}
		var list []json.RawMessage
		for _, v := range verdicts {
			if v.Status != "ok" {
				g.log.Warn("mcp descriptor rejected", "server", server, "tool", v.Name, "status", v.Status, "hash", v.Hash, "pin", srv.Tools[v.Name])
				continue
			}
			if g.reg.Allowed(id.Username, server, v.Name) {
				list = append(list, tools[v.Name])
			}
		}
		out, _ := json.Marshal(map[string]any{"tools": nonNil(list)})
		audit("ok", "tools", len(list))
		reply(w, msg.ID, out, nil)
	case "tools/call":
		var p struct {
			Name string `json:"name"`
		}
		json.Unmarshal(msg.Params, &p)
		if !g.reg.Allowed(id.Username, server, p.Name) {
			audit("refused", "tool", p.Name, "reason", "not allowed for this identity")
			reply(w, msg.ID, nil, &rpcError{-32602, fmt.Sprintf("tool %q is not available to %s", p.Name, id.Username)})
			return
		}
		// The pin is checked against what the server advertises now, so a
		// server that changed since the agent listed its tools is caught.
		_, verdicts, err := g.verified(srv, fwd)
		if err != nil {
			audit("upstream error", "tool", p.Name, "reason", err.Error())
			reply(w, msg.ID, nil, &rpcError{-32000, "tool server unavailable: " + err.Error()})
			return
		}
		status := "missing"
		for _, v := range verdicts {
			if v.Name == p.Name {
				status = v.Status
			}
		}
		if status != "ok" {
			g.log.Warn("mcp descriptor rejected", "server", server, "tool", p.Name, "status", status)
			audit("refused", "tool", p.Name, "reason", "descriptor "+status)
			reply(w, msg.ID, nil, &rpcError{-32602, fmt.Sprintf("tool %q refused: its descriptor is %s (doesn't match the pinned one)", p.Name, status)})
			return
		}
		res, err := g.upstream(srv, body, fwd, true)
		if err != nil {
			audit("upstream error", "tool", p.Name, "reason", err.Error())
			reply(w, msg.ID, nil, &rpcError{-32000, "tool server unavailable: " + err.Error()})
			return
		}
		capped, n, truncated := g.cap(res)
		audit("ok", "tool", p.Name, "resultBytes", n, "truncated", truncated)
		reply(w, msg.ID, capped, nil)
	default:
		audit("refused", "reason", "method not allowed")
		reply(w, msg.ID, nil, &rpcError{-32601, fmt.Sprintf("method %q is not available through the MCP gateway", msg.Method)})
	}
}

// verified lists the server's tools now and checks them against the pins.
func (g *gateway) verified(srv mcpreg.Server, fwd http.Header) (map[string]json.RawMessage, []mcpreg.Verdict, error) {
	res, err := g.upstream(srv, []byte(`{"jsonrpc":"2.0","id":"gw-list","method":"tools/list"}`), fwd, false)
	if err != nil {
		return nil, nil, err
	}
	var list struct {
		Tools []json.RawMessage `json:"tools"`
	}
	if err := json.Unmarshal(res, &list); err != nil {
		return nil, nil, fmt.Errorf("tools/list: %w", err)
	}
	verdicts, ok, err := mcpreg.Check(srv, list.Tools)
	return ok, verdicts, err
}

// upstream sends one JSON-RPC message and returns its result.
func (g *gateway) upstream(srv mcpreg.Server, body []byte, fwd http.Header, withSecret bool) (json.RawMessage, error) {
	req, err := http.NewRequest(http.MethodPost, srv.URL, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header = fwd.Clone()
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	if withSecret && srv.SecretHeader != "" {
		secret, err := os.ReadFile(srv.SecretFile)
		if err != nil {
			return nil, errors.New("the gateway has no credential for this server")
		}
		req.Header.Set(srv.SecretHeader, strings.TrimSpace(string(secret)))
	}
	resp, err := g.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var m rpcMsg
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("not a JSON-RPC response")
	}
	if m.Error != nil {
		return nil, fmt.Errorf("%d %s", m.Error.Code, m.Error.Message)
	}
	return m.Result, nil
}

// cap truncates a tools/call result's text so it fits maxResult bytes, and
// says so in the result, where the model will see it.
func (g *gateway) cap(res json.RawMessage) (json.RawMessage, int, bool) {
	n := len(res)
	if n <= g.maxResult {
		return res, n, false
	}
	var r map[string]any
	if json.Unmarshal(res, &r) != nil {
		out, _ := json.Marshal(map[string]any{"isError": true, "content": []any{map[string]any{"type": "text",
			"text": fmt.Sprintf("result of %d bytes withheld by the MCP gateway (cap %d)", n, g.maxResult)}}})
		return out, n, true
	}
	delete(r, "structuredContent") // a second copy of the same data
	budget := g.maxResult
	if content, ok := r["content"].([]any); ok {
		for _, c := range content {
			if item, ok := c.(map[string]any); ok && item["type"] == "text" {
				if s, ok := item["text"].(string); ok {
					if len(s) > budget {
						item["text"] = s[:max(budget, 0)] + fmt.Sprintf("\n[truncated by the MCP gateway: %d of %d bytes shown]", max(budget, 0), len(s))
					}
					budget -= len(s)
				}
			}
		}
	}
	out, _ := json.Marshal(r)
	return out, n, true
}

// forwardHeaders keeps only the MCP protocol headers from the agent's
// request: not its Authorization (its identity token), not anything else.
func forwardHeaders(r *http.Request) http.Header {
	h := http.Header{}
	for k, v := range r.Header {
		lk := strings.ToLower(k)
		if strings.HasPrefix(lk, "mcp-") && lk != "mcp-session-id" {
			h[k] = v
		}
	}
	return h
}

func reply(w http.ResponseWriter, id json.RawMessage, result json.RawMessage, rerr *rpcError) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(rpcMsg{JSONRPC: "2.0", ID: id, Result: result, Error: rerr})
}

func printPins(client *http.Client, url string) error {
	g := &gateway{client: client}
	res, err := g.upstream(mcpreg.Server{URL: url}, []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`),
		http.Header{"Mcp-Protocol-Version": []string{"2025-06-18"}}, false)
	if err != nil {
		return err
	}
	var list struct {
		Tools []json.RawMessage `json:"tools"`
	}
	if err := json.Unmarshal(res, &list); err != nil {
		return err
	}
	pins := map[string]string{}
	for _, t := range list.Tools {
		var named struct {
			Name string `json:"name"`
		}
		json.Unmarshal(t, &named)
		if pins[named.Name], err = mcpreg.Hash(t); err != nil {
			return err
		}
	}
	out, _ := json.MarshalIndent(pins, "", "  ")
	fmt.Println(string(out))
	return nil
}

func nonNil(l []json.RawMessage) []json.RawMessage {
	if l == nil {
		return []json.RawMessage{}
	}
	return l
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
