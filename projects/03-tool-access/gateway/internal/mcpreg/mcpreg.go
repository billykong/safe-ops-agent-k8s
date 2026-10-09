// Package mcpreg is the MCP gateway's static registry (P3-04, P3-20,
// P3-21): which MCP servers exist, which tools each identity may use, and
// the hash each tool's descriptor must have. Nothing is discovered at run
// time: a tool the registry doesn't list, or whose descriptor no longer
// matches its pin, is hidden from tools/list and refused on tools/call.
//
// A descriptor is the whole tool object the server advertises (name,
// title, description, input and output schemas, annotations): the model
// reads all of it, so a changed description is a changed tool. Its pin is
// the SHA-256 of its canonical JSON (keys sorted, no whitespace).
package mcpreg

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"sort"
)

// Server is one upstream MCP server.
type Server struct {
	URL string `json:"url"`
	// SecretHeader and SecretFile: the credential the gateway adds to
	// tools/call requests for this server. The agent never sees it.
	SecretHeader string `json:"secretHeader,omitempty"`
	SecretFile   string `json:"secretFile,omitempty"`
	// Tools maps tool name -> pinned descriptor hash ("sha256:...").
	Tools map[string]string `json:"tools"`
}

// Registry is the gateway's configuration, kept in git and reviewed.
type Registry struct {
	Servers map[string]Server `json:"servers"`
	// Identities maps a service account username to the tools it may use,
	// per server.
	Identities map[string]map[string][]string `json:"identities"`
}

// Load reads a registry file.
func Load(path string) (*Registry, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r Registry
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, fmt.Errorf("registry %s: %w", path, err)
	}
	for id, servers := range r.Identities {
		for s, tools := range servers {
			srv, ok := r.Servers[s]
			if !ok {
				return nil, fmt.Errorf("identity %s refers to unknown server %q", id, s)
			}
			for _, t := range tools {
				if _, ok := srv.Tools[t]; !ok {
					return nil, fmt.Errorf("identity %s may use %s/%s, which has no pin", id, s, t)
				}
			}
		}
	}
	return &r, nil
}

// Allowed reports whether identity may call server/tool.
func (r *Registry) Allowed(identity, server, tool string) bool {
	return slices.Contains(r.Identities[identity][server], tool)
}

// HasServer reports whether identity may use server at all.
func (r *Registry) HasServer(identity, server string) bool {
	_, ok := r.Identities[identity][server]
	return ok
}

// Hash is the pin of one tool descriptor.
func Hash(tool json.RawMessage) (string, error) {
	var v any
	if err := json.Unmarshal(tool, &v); err != nil {
		return "", err
	}
	canon, err := json.Marshal(v) // maps marshal with sorted keys
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canon)
	return "sha256:" + hex.EncodeToString(sum[:]), nil
}

// Verdict on one advertised tool.
type Verdict struct {
	Name   string
	Hash   string
	Status string // "ok", "unpinned" (not in the registry), "changed" (hash differs)
}

// Check compares a server's advertised tools with its pins.
func Check(srv Server, tools []json.RawMessage) ([]Verdict, map[string]json.RawMessage, error) {
	var out []Verdict
	byName := map[string]json.RawMessage{}
	for _, t := range tools {
		var named struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal(t, &named); err != nil || named.Name == "" {
			return nil, nil, fmt.Errorf("tool without a name")
		}
		h, err := Hash(t)
		if err != nil {
			return nil, nil, err
		}
		v := Verdict{Name: named.Name, Hash: h, Status: "ok"}
		pin, pinned := srv.Tools[named.Name]
		switch {
		case !pinned:
			v.Status = "unpinned"
		case pin != h:
			v.Status = "changed"
		default:
			byName[named.Name] = t
		}
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, byName, nil
}
