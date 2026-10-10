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
// It is also where model use is measured (P4-01, P4-02): a span per
// request, joined to the agent's trace, with the GenAI semantic
// conventions' attributes and token counts, and Prometheus metrics for
// requests, tokens and estimated cost per identity, on a separate port.
// These are the trusted numbers: the agent can't change what the gateway
// counted.
//
// If the provider can't be reached or fails, the agent gets 503 with
// type "model_unavailable": its cue to escalate to a human (P3-06).
package main

import (
	"bytes"
	"context"
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

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"

	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/authn"
	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/budget"
	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/policy"
	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/pricing"
	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/telemetry"
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
	prices   pricing.Table
	m        metrics
}

// outcomes of a model request, for the metrics.
var outcomes = []string{"ok", "unauthenticated", "forbidden", "auth_unavailable", "too_large", "policy",
	"rate_limit", "token_budget", "unavailable", "provider_error"}

// metrics: labels are bounded: identities are the allowed service
// accounts (or "" when unauthenticated), models the allowed ones or
// "other", outcomes a fixed set.
type metrics struct {
	requests *prometheus.CounterVec
	tokens   *prometheus.CounterVec
	cost     *prometheus.CounterVec
	duration *prometheus.HistogramVec
}

func newMetrics(reg prometheus.Registerer) metrics {
	m := metrics{
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "safeops_llm_requests_total",
			Help: "Model requests by identity, model and outcome (ok, or why the gateway refused or failed it)."},
			[]string{"identity", "model", "outcome"}),
		tokens: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "safeops_llm_tokens_total",
			Help: "Tokens the provider reported, by identity, model and type (input, output, cache_write, cache_read)."},
			[]string{"identity", "model", "type"}),
		cost: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "safeops_llm_cost_usd_total",
			Help: "Estimated cost in USD at the configured list prices, by identity and model."},
			[]string{"identity", "model"}),
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: "safeops_llm_request_duration_seconds",
			Help: "Time from request to response, by model and outcome.", Buckets: []float64{.1, .5, 1, 2.5, 5, 10, 30, 60, 120}},
			[]string{"model", "outcome"}),
	}
	reg.MustRegister(m.requests, m.tokens, m.cost, m.duration)
	return m
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
	shutdown, err := telemetry.Setup(context.Background(), "llm-gateway")
	if err != nil {
		fail("telemetry", err)
	}
	defer shutdown(context.Background())
	prices, err := pricing.Parse(env("PRICES", ""))
	if err != nil {
		fail("PRICES", err)
	}
	reg := prometheus.NewRegistry()
	g := &gateway{
		log:    log,
		prices: prices,
		m:      newMetrics(reg),
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
	for _, m := range g.policy.Models {
		if _, ok := prices[m]; !ok {
			log.Warn("no price for model: its cost isn't recorded", "model", m)
		}
		// Series start at zero, so a series' first increase is counted.
		for _, id := range g.authn.Allowed {
			for _, o := range outcomes {
				g.m.requests.WithLabelValues(id, m, o)
			}
			for _, t := range []string{"input", "output", "cache_write", "cache_read"} {
				g.m.tokens.WithLabelValues(id, m, t)
			}
			g.m.cost.WithLabelValues(id, m)
		}
	}
	// Metrics on their own port, which only Prometheus may reach.
	go func() {
		mm := http.NewServeMux()
		mm.Handle("GET /metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
		ms := &http.Server{Addr: env("METRICS_LISTEN", ":9090"), Handler: mm, ReadHeaderTimeout: 5 * time.Second}
		if err := ms.ListenAndServe(); err != nil {
			fail("metrics", err)
		}
	}()
	addr := env("LISTEN", ":8080")
	log.Info("listening", "addr", addr, "upstream", g.upstream, "models", g.policy.Models, "maxTokensCap", g.policy.MaxTokensCap,
		"budgetTokens", g.budget.TokensPerWindow, "budgetWindow", g.budget.Window.String(), "allowed", g.authn.Allowed)
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		fail("serve", err)
	}
}

// identify authenticates the caller, writing the error response if it
// fails; outcome says why, for the metrics.
func (g *gateway) identify(w http.ResponseWriter, r *http.Request) (id authn.Identity, outcome string, ok bool) {
	id, err := g.authn.Authenticate(r.Context(), r)
	if err == nil {
		return id, "", true
	}
	code, typ, outcome := http.StatusServiceUnavailable, "api_error", "auth_unavailable" // couldn't review: fail closed
	switch {
	case errors.Is(err, authn.ErrUnauthenticated):
		code, typ, outcome = http.StatusUnauthorized, "authentication_error", "unauthenticated"
	case errors.Is(err, authn.ErrForbidden):
		code, typ, outcome = http.StatusForbidden, "permission_error", "forbidden"
	}
	g.log.Info("request", "path", r.URL.Path, "status", code, "identity", id.Username, "pod", id.Pod, "reason", err.Error())
	writeError(w, code, typ, err.Error())
	return id, outcome, false
}

func (g *gateway) whoami(w http.ResponseWriter, r *http.Request) {
	id, _, ok := g.identify(w, r)
	if !ok {
		return
	}
	g.log.Info("request", "path", r.URL.Path, "status", 200, "identity", id.Username, "pod", id.Pod, "credentialID", id.CredentialID)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(id)
}

func (g *gateway) remaining(w http.ResponseWriter, r *http.Request) {
	id, _, ok := g.identify(w, r)
	if !ok {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"identity": id.Username, "remainingTokens": g.budget.Remaining(id.Username),
		"windowTokens": g.budget.TokensPerWindow, "window": g.budget.Window.String()})
}

func (g *gateway) messages(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	// One span per request, in the agent's trace if it sent one, named
	// "chat <model>" once the model is known (GenAI conventions).
	ctx, span := telemetry.Tracer().Start(telemetry.Extract(r), "chat", trace.WithSpanKind(trace.SpanKindServer),
		trace.WithAttributes(attribute.String("gen_ai.operation.name", "chat"), attribute.String("gen_ai.provider.name", "anthropic")))
	defer span.End()
	r = r.WithContext(ctx)
	var (
		id      authn.Identity
		model   string
		outcome = "ok"
	)
	defer func() { g.record(span, id.Username, model, outcome, time.Since(start)) }()
	id, authOutcome, ok := g.identify(w, r)
	if !ok {
		outcome = authOutcome
		return
	}
	audit := func(status int, fields ...any) {
		g.log.Info("request", append([]any{"path", r.URL.Path, "status", status, "identity", id.Username, "pod", id.Pod,
			"credentialID", id.CredentialID, "ms", time.Since(start).Milliseconds()}, fields...)...)
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil || len(body) > maxBody {
		outcome = "too_large"
		audit(413, "reason", "body too large or unreadable")
		writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "request body over 1 MiB")
		return
	}
	req, err := policy.Check(g.policy, body, r.Header.Values("anthropic-beta"))
	model = g.knownModel(req.Model)
	span.SetName("chat " + model)
	span.SetAttributes(attribute.String("gen_ai.request.model", model), attribute.Int("gen_ai.request.max_tokens", req.MaxTokens))
	if err != nil {
		outcome = "policy"
		audit(400, "model", req.Model, "reason", err.Error())
		writeError(w, http.StatusBadRequest, "invalid_request_error", "gateway policy: "+err.Error())
		return
	}
	d := g.budget.Reserve(id.Username, req.MaxTokens)
	if !d.OK {
		outcome = "token_budget"
		if d.Reason == "request rate limit" {
			outcome = "rate_limit"
		}
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
		outcome = "unavailable"
		audit(503, "model", req.Model, "reason", "no provider key mounted")
		writeError(w, http.StatusServiceUnavailable, "model_unavailable", "the gateway has no provider key")
		return
	}
	up, err := http.NewRequestWithContext(r.Context(), http.MethodPost, g.upstream+"/v1/messages", bytes.NewReader(body))
	if err != nil {
		outcome = "unavailable"
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
		outcome = "unavailable"
		audit(503, "model", req.Model, "reason", "upstream unreachable: "+err.Error())
		writeError(w, http.StatusServiceUnavailable, "model_unavailable", "the model provider can't be reached; escalate to a human")
		return
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		outcome = "unavailable"
		audit(503, "model", req.Model, "reason", "upstream read: "+err.Error())
		writeError(w, http.StatusServiceUnavailable, "model_unavailable", "the model provider's response was cut off; escalate to a human")
		return
	}
	u, _ := policy.ParseUsage(out)
	charged = u.Total()
	g.charge(span, id.Username, model, u, out)
	reqID := resp.Header.Get("request-id")
	if resp.StatusCode >= 400 {
		outcome = "provider_error"
	}
	if resp.StatusCode >= 500 {
		outcome = "unavailable"
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

// knownModel is m if the gateway allows it, else "other": the request's
// model is the agent's text, so it can't be a label as it is.
func (g *gateway) knownModel(m string) string {
	for _, a := range g.policy.Models {
		if m == a {
			return m
		}
	}
	return "other"
}

// charge records what the provider reported: tokens and estimated cost
// in the metrics, and the GenAI usage attributes on the span.
func (g *gateway) charge(span trace.Span, identity, model string, u policy.Usage, body []byte) {
	for typ, n := range map[string]int{"input": u.InputTokens, "output": u.OutputTokens,
		"cache_write": u.CacheCreationInputTokens, "cache_read": u.CacheReadInputTokens} {
		if n > 0 {
			g.m.tokens.WithLabelValues(identity, model, typ).Add(float64(n))
		}
	}
	cost, priced := g.prices.Cost(model, u)
	if priced {
		g.m.cost.WithLabelValues(identity, model).Add(cost)
	}
	var meta struct {
		ID         string `json:"id"`
		Model      string `json:"model"`
		StopReason string `json:"stop_reason"`
	}
	json.Unmarshal(body, &meta)
	span.SetAttributes(
		attribute.Int("gen_ai.usage.input_tokens", u.InputTokens+u.CacheCreationInputTokens+u.CacheReadInputTokens),
		attribute.Int("gen_ai.usage.output_tokens", u.OutputTokens),
		attribute.Int("gen_ai.usage.cache_read.input_tokens", u.CacheReadInputTokens),
		attribute.Int("gen_ai.usage.cache_creation.input_tokens", u.CacheCreationInputTokens),
		attribute.String("gen_ai.response.id", meta.ID),
		attribute.String("gen_ai.response.model", g.knownModel(meta.Model)),
		attribute.StringSlice("gen_ai.response.finish_reasons", []string{meta.StopReason}),
	)
	if priced {
		span.SetAttributes(attribute.Float64("safeops.cost_usd", cost))
	}
}

// record counts the request and closes out its span.
func (g *gateway) record(span trace.Span, identity, model, outcome string, d time.Duration) {
	if model == "" {
		model = "other"
	}
	g.m.requests.WithLabelValues(identity, model, outcome).Inc()
	g.m.duration.WithLabelValues(model, outcome).Observe(d.Seconds())
	span.SetAttributes(attribute.String("safeops.identity", identity), attribute.String("safeops.outcome", outcome))
	if outcome != "ok" {
		span.SetAttributes(attribute.String("error.type", outcome))
		span.SetStatus(codes.Error, outcome)
	}
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
