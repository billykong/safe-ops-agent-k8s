// Package upstream picks where a model request goes: the model provider by
// default, or a self-hosted model server for the models routed to it (P5:
// vLLM outside the cluster). Each upstream has its own key, and a request
// carries only its upstream's key: the provider key never reaches the
// self-hosted server, nor the other way round.
package upstream

import (
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

// Upstream is one place requests go.
type Upstream struct {
	URL      string // base URL; requests go to URL + "/v1/messages"
	Provider string // gen_ai.provider.name on the request's span
	KeyFile  string // the key, read per request so a rotated Secret applies
	// Bearer sends the key as "Authorization: Bearer" (vLLM's --api-key);
	// otherwise as the provider's "x-api-key".
	Bearer bool
}

// Router maps a model to its upstream.
type Router struct {
	Default Upstream
	Routes  map[string]Upstream
}

// For is the upstream for model.
func (r Router) For(model string) Upstream {
	if u, ok := r.Routes[model]; ok {
		return u
	}
	return r.Default
}

// ParseRoutes reads "model=http://host:port,..." into routes that all use
// the self-hosted server's provider name and key.
func ParseRoutes(s, provider, keyFile string) (map[string]Upstream, error) {
	routes := map[string]Upstream{}
	for _, entry := range strings.Split(s, ",") {
		if entry = strings.TrimSpace(entry); entry == "" {
			continue
		}
		model, raw, ok := strings.Cut(entry, "=")
		model = strings.TrimSpace(model)
		if !ok || model == "" {
			return nil, fmt.Errorf("%q: want model=url", entry)
		}
		u, err := url.Parse(strings.TrimSpace(raw))
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || (u.Path != "" && u.Path != "/") {
			return nil, fmt.Errorf("%q: want an http(s) URL with no path", entry)
		}
		if _, dup := routes[model]; dup {
			return nil, fmt.Errorf("%q: model routed twice", model)
		}
		routes[model] = Upstream{URL: strings.TrimRight(u.String(), "/"), Provider: provider, KeyFile: keyFile, Bearer: true}
	}
	if len(routes) > 0 && keyFile == "" {
		return nil, fmt.Errorf("routes need a key file for the self-hosted server")
	}
	return routes, nil
}

// SetHeaders sets the only headers a request upstream carries: its body
// type, the upstream's key, and the Messages API version and betas. Not
// the caller's Authorization (its identity token), nor anything else.
func SetHeaders(h http.Header, u Upstream, key, version string, betas []string) {
	h.Set("content-type", "application/json")
	if u.Bearer {
		h.Set("authorization", "Bearer "+key)
	} else {
		h.Set("x-api-key", key)
	}
	h.Set("anthropic-version", version)
	for _, b := range betas {
		h.Add("anthropic-beta", b)
	}
}
