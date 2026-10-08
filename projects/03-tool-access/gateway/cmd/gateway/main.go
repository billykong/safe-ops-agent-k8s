// gateway: the agents' gateway (P3). Milestone 1 provides its front door:
// workload-identity authentication of every request (internal/authn) and
// an audit line per decision. /whoami returns the caller's identity; the
// model proxy (P3 milestone 2) sits behind the same check.
package main

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"

	"github.com/billykong/safe-ops-agent-k8s/projects/03-tool-access/gateway/internal/authn"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := rest.InClusterConfig()
	if err != nil {
		log.Error("in-cluster config", "err", err)
		os.Exit(1)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Error("client", "err", err)
		os.Exit(1)
	}
	ttl, err := time.ParseDuration(env("REVIEW_CACHE_TTL", "10s"))
	if err != nil {
		log.Error("REVIEW_CACHE_TTL", "err", err)
		os.Exit(1)
	}
	a := &authn.Authenticator{
		Reviewer: cs.AuthenticationV1().TokenReviews(),
		Audience: env("AUDIENCE", "llm-gateway.safe-ops.io"),
		Allowed:  strings.Split(env("ALLOWED_IDENTITIES", ""), ","),
		CacheTTL: ttl,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok\n")) })
	mux.HandleFunc("GET /whoami", func(w http.ResponseWriter, r *http.Request) {
		id, err := a.Authenticate(r.Context(), r)
		code := http.StatusOK
		switch {
		case errors.Is(err, authn.ErrUnauthenticated):
			code = http.StatusUnauthorized
		case errors.Is(err, authn.ErrForbidden):
			code = http.StatusForbidden
		case err != nil:
			code = http.StatusServiceUnavailable // couldn't review: fail closed
		}
		// Audit: who (as far as known), what, the outcome and why.
		log.Info("request", "path", r.URL.Path, "status", code, "identity", id.Username, "pod", id.Pod,
			"credentialID", id.CredentialID, "reason", errString(err))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		if err != nil {
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		json.NewEncoder(w).Encode(id)
	})
	addr := env("LISTEN", ":8080")
	log.Info("listening", "addr", addr, "audience", a.Audience, "allowed", a.Allowed, "cacheTTL", ttl.String())
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		log.Error("serve", "err", err)
		os.Exit(1)
	}
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
