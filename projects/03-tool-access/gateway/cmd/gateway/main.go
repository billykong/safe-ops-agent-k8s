// gateway: the agents' LLM gateway (P3-02, P3-03). Every request:
//
//  1. authenticates the agent by workload identity (internal/authn);
//  2. is checked as data (internal/policy): allowed model, bounded
//     max_tokens, no streaming, no server tools or remote MCP;
//  3. reserves tokens against the identity's budget (internal/budget);
//  4. is sent upstream with the provider key, read from a mounted Secret,
//     and none of the agent's own headers (its token never leaves);
//  5. is charged its actual usage, and logged.
//
// If the provider can't be reached or fails, the agent gets 503 with
// type "model_unavailable": its cue to escalate to a human (P3-06).
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
	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/budget"
	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/policy"
)

const maxBody = 1 << 20

type gateway struct {
	log      *slog.Logger
	authn    *authn.Authenticator
	policy   policy.Config
	budget   *budget.Limiter
	upstream string
	keyFile  string
	client   *http.Client
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	fail := func(msg string, err error) { log.Error(msg, "err", err); os.Exit(1) }
	cfg, err := rest.InClusterConfig()
	if err != nil {
		fail("in-cluster config", err)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		fail("client", err)
	}
	dur := func(k, def string) time.Duration {
		d, err := time.ParseDuration(env(k, def))
		if err != nil {
			fail(k, err)
		}
		return d
	}
	num := func(k, def string) int {
		n, err := strconv.Atoi(env(k, def))
		if err != nil {
			fail(k, err)
		}
		return n
	}
	g := &gateway{
		log: log,
		authn: &authn.Authenticator{
			Reviewer: cs.AuthenticationV1().TokenReviews(),
			Audience: env("AUDIENCE", "llm-gateway.safe-ops.io"),
			Allowed:  list(env("ALLOWED_IDENTITIES", "")),
			CacheTTL: dur("REVIEW_CACHE_TTL", "10s"),
		},
		policy: policy.Config{
			Models:       list(env("MODELS", "claude-opus-5-5")),
			MaxTokensCap: num("MAX_TOKENS_CAP", "16000"),
			Betas:        list(env("BETAS", "server-side-fallback-2026-07-01")),
			Fallbacks:    list(env("FALLBACKS", "default")),
		},
		budget: &budget.Limiter{
			TokensPerWindow:   num("BUDGET_TOKENS", "200000"),
			Window:            dur("BUDGET_WINDOW", "1h"),
			RequestsPerMinute: num("REQUESTS_PER_MINUTE", "30"),
		},
		upstream: strings.TrimRight(env("UPSTREAM_URL", "https://api.anthropic.com"), "/"),
		keyFile:  env("API_KEY_FILE", "/var/run/secrets/safe-ops.io/upstream/api-key"),
		client:   &http.Client{Timeout: dur("UPSTREAM_TIMEOUT", "120s")},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok\n")) })
	mux.HandleFunc("GET /whoami", g.whoami)
	mux.HandleFunc("GET /v1/budget", g.remaining)
	mux.HandleFunc("POST /v1/messages", g.messages)
	addr := env("LISTEN", ":8080")
	log.Info("listening", "addr", addr, "upstream", g.upstream, "models", g.policy.Models, "maxTokensCap", g.policy.MaxTokensCap,
		"budgetTokens", g.budget.TokensPerWindow, "budgetWindow", g.budget.Window.String(), "allowed", g.authn.Allowed)
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		fail("serve", err)
	}
}

// identify authenticates the caller, writing the error response if it fails.
func (g *gateway) identify(w http.ResponseWriter, r *http.Request) (authn.Identity, bool) {
	id, err := g.authn.Authenticate(r.Context(), r)
	if err == nil {
		return id, true
	}
	code, typ := http.StatusServiceUnavailable, "api_error" // couldn't review: fail closed
	switch {
	case errors.Is(err, authn.ErrUnauthenticated):
		code, typ = http.StatusUnauthorized, "authentication_error"
	case errors.Is(err, authn.ErrForbidden):
		code, typ = http.StatusForbidden, "permission_error"
	}
	g.log.Info("request", "path", r.URL.Path, "status", code, "identity", id.Username, "pod", id.Pod, "reason", err.Error())
	writeError(w, code, typ, err.Error())
	return id, false
}

func (g *gateway) whoami(w http.ResponseWriter, r *http.Request) {
	id, ok := g.identify(w, r)
	if !ok {
		return
	}
	g.log.Info("request", "path", r.URL.Path, "status", 200, "identity", id.Username, "pod", id.Pod, "credentialID", id.CredentialID)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(id)
}

func (g *gateway) remaining(w http.ResponseWriter, r *http.Request) {
	id, ok := g.identify(w, r)
	if !ok {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"identity": id.Username, "remainingTokens": g.budget.Remaining(id.Username),
		"windowTokens": g.budget.TokensPerWindow, "window": g.budget.Window.String()})
}

func (g *gateway) messages(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	id, ok := g.identify(w, r)
	if !ok {
		return
	}
	audit := func(status int, fields ...any) {
		g.log.Info("request", append([]any{"path", r.URL.Path, "status", status, "identity", id.Username, "pod", id.Pod,
			"credentialID", id.CredentialID, "ms", time.Since(start).Milliseconds()}, fields...)...)
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil || len(body) > maxBody {
		audit(413, "reason", "body too large or unreadable")
		writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "request body over 1 MiB")
		return
	}
	req, err := policy.Check(g.policy, body, r.Header.Values("anthropic-beta"))
	if err != nil {
		audit(400, "model", req.Model, "reason", err.Error())
		writeError(w, http.StatusBadRequest, "invalid_request_error", "gateway policy: "+err.Error())
		return
	}
	d := g.budget.Reserve(id.Username, req.MaxTokens)
	if !d.OK {
		audit(429, "model", req.Model, "reason", d.Reason, "remainingTokens", d.Remaining)
		w.Header().Set("Retry-After", strconv.Itoa(int(d.RetryAfter.Seconds())+1))
		writeError(w, http.StatusTooManyRequests, "rate_limit_error",
			fmt.Sprintf("gateway budget: %s for %s (%d tokens left, this request may use %d)", d.Reason, id.Username, d.Remaining, req.MaxTokens))
		return
	}
	charged := 0
	defer func() { g.budget.Settle(id.Username, req.MaxTokens, charged) }()

	key, err := os.ReadFile(g.keyFile)
	if err != nil || len(bytes.TrimSpace(key)) == 0 {
		audit(503, "model", req.Model, "reason", "no provider key mounted")
		writeError(w, http.StatusServiceUnavailable, "model_unavailable", "the gateway has no provider key")
		return
	}
	up, err := http.NewRequestWithContext(r.Context(), http.MethodPost, g.upstream+"/v1/messages", bytes.NewReader(body))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "api_error", err.Error())
		return
	}
	// Only these headers go upstream. Not the agent's Authorization (its
	// identity token), not anything else it sent.
	up.Header.Set("content-type", "application/json")
	up.Header.Set("x-api-key", string(bytes.TrimSpace(key)))
	up.Header.Set("anthropic-version", firstNonEmpty(r.Header.Get("anthropic-version"), "2023-06-01"))
	for _, b := range r.Header.Values("anthropic-beta") {
		up.Header.Add("anthropic-beta", b)
	}
	resp, err := g.client.Do(up)
	if err != nil {
		audit(503, "model", req.Model, "reason", "upstream unreachable: "+err.Error())
		writeError(w, http.StatusServiceUnavailable, "model_unavailable", "the model provider can't be reached; escalate to a human")
		return
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		audit(503, "model", req.Model, "reason", "upstream read: "+err.Error())
		writeError(w, http.StatusServiceUnavailable, "model_unavailable", "the model provider's response was cut off; escalate to a human")
		return
	}
	u, _ := policy.ParseUsage(out)
	charged = u.Total()
	reqID := resp.Header.Get("request-id")
	if resp.StatusCode >= 500 {
		audit(503, "model", req.Model, "upstreamStatus", resp.StatusCode, "upstreamRequestID", reqID)
		writeError(w, http.StatusServiceUnavailable, "model_unavailable",
			fmt.Sprintf("the model provider failed (HTTP %d); escalate to a human", resp.StatusCode))
		return
	}
	audit(resp.StatusCode, "model", req.Model, "inputTokens", u.InputTokens, "outputTokens", u.OutputTokens,
		"charged", charged, "remainingTokens", g.budget.Remaining(id.Username)+req.MaxTokens-charged, "upstreamRequestID", reqID)
	w.Header().Set("Content-Type", "application/json")
	if reqID != "" {
		w.Header().Set("request-id", reqID)
	}
	w.WriteHeader(resp.StatusCode)
	w.Write(out)
}

// writeError answers in the Messages API's error shape, so SDK clients
// raise their usual typed errors.
func writeError(w http.ResponseWriter, code int, typ, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{"type": "error", "error": map[string]string{"type": typ, "message": msg}})
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func list(s string) []string {
	var out []string
	for _, v := range strings.Split(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
