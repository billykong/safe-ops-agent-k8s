package upstream

import (
	"net/http"
	"testing"
)

func TestParseRoutes(t *testing.T) {
	r, err := ParseRoutes(" qwen=http://172.30.99.10:8000/ , other=https://m.example:8443", "vllm", "/k")
	if err != nil {
		t.Fatal(err)
	}
	if got := r["qwen"]; got != (Upstream{URL: "http://172.30.99.10:8000", Provider: "vllm", KeyFile: "/k", Bearer: true}) {
		t.Errorf("qwen: %+v", got)
	}
	if r["other"].URL != "https://m.example:8443" {
		t.Errorf("other: %+v", r["other"])
	}
	if r, err := ParseRoutes("", "vllm", ""); err != nil || len(r) != 0 {
		t.Errorf("empty: %v %v", r, err)
	}
	for _, bad := range []string{"qwen", "=http://a:1", "qwen=a:1", "qwen=ftp://a", "qwen=http://a/v1", "qwen=http://a,qwen=http://b"} {
		if _, err := ParseRoutes(bad, "vllm", "/k"); err == nil {
			t.Errorf("%q: accepted", bad)
		}
	}
	if _, err := ParseRoutes("qwen=http://a:1", "vllm", ""); err == nil {
		t.Error("a route with no key file: accepted")
	}
}

func TestFor(t *testing.T) {
	def := Upstream{URL: "https://api.anthropic.com", Provider: "anthropic", KeyFile: "/p"}
	r := Router{Default: def, Routes: map[string]Upstream{"qwen": {URL: "http://m:8000", Provider: "vllm", KeyFile: "/l", Bearer: true}}}
	if r.For("claude-opus-5-5") != def || r.For("") != def {
		t.Error("unrouted models must go to the provider")
	}
	if u := r.For("qwen"); u.URL != "http://m:8000" || u.KeyFile != "/l" {
		t.Errorf("qwen: %+v", u)
	}
}

func TestSetHeaders(t *testing.T) {
	// The provider gets x-api-key, the self-hosted server a bearer key;
	// neither gets the other's.
	h := http.Header{}
	SetHeaders(h, Upstream{}, "provider-key", "2023-06-01", []string{"b1", "b2"})
	if h.Get("x-api-key") != "provider-key" || h.Get("authorization") != "" || len(h.Values("anthropic-beta")) != 2 {
		t.Errorf("provider: %v", h)
	}
	h = http.Header{}
	SetHeaders(h, Upstream{Bearer: true}, "local-key", "2023-06-01", nil)
	if h.Get("authorization") != "Bearer local-key" || h.Get("x-api-key") != "" || h.Get("anthropic-version") != "2023-06-01" {
		t.Errorf("self-hosted: %v", h)
	}
}
