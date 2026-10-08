// Package authn authenticates agents to a gateway by workload identity
// (P3-01). An agent presents a projected service account token minted for
// this gateway's audience; the gateway asks the API server to review it
// (TokenReview) and accepts it only if:
//   - it is valid for this gateway's audience, so a token meant for the API
//     server or another gateway is refused, and this one is useless
//     anywhere else;
//   - it is bound to a pod, so it dies with the pod; tokens minted by hand
//     (kubectl create token) are refused;
//   - it belongs to an allowed agent identity (authorization).
//
// TokenReview rather than offline JWT verification against the API
// server's JWKS: a review also checks that the service account and pod
// still exist, so the kill switch's credential revocation (recreating the
// service accounts) takes effect here within the cache TTL, not when the
// token expires.
package authn

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	authnv1 "k8s.io/api/authentication/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Identity is an authenticated agent.
type Identity struct {
	Username       string `json:"username"`
	Namespace      string `json:"namespace"`
	ServiceAccount string `json:"serviceAccount"`
	Pod            string `json:"pod"`
	PodUID         string `json:"podUID"`
	Node           string `json:"node,omitempty"`
	// CredentialID identifies the token (its JTI), for audit logs.
	CredentialID string `json:"credentialID,omitempty"`
}

var (
	ErrUnauthenticated = errors.New("unauthenticated")
	ErrForbidden       = errors.New("forbidden")
)

// Reviewer is the part of the TokenReview client used here.
type Reviewer interface {
	Create(ctx context.Context, tr *authnv1.TokenReview, opts metav1.CreateOptions) (*authnv1.TokenReview, error)
}

type entry struct {
	id      Identity
	err     error
	expires time.Time
}

// Authenticator checks bearer tokens.
type Authenticator struct {
	Reviewer Reviewer
	Audience string
	// Allowed lists the service account usernames that may use the gateway.
	Allowed []string
	// CacheTTL bounds how long a review result is reused, and so how long
	// a revoked identity may still get through. 0 disables caching.
	CacheTTL time.Duration
	Now      func() time.Time

	mu    sync.Mutex
	cache map[[32]byte]entry
}

// Authenticate reviews the request's bearer token.
func (a *Authenticator) Authenticate(ctx context.Context, r *http.Request) (Identity, error) {
	h := r.Header.Get("Authorization")
	token, ok := strings.CutPrefix(h, "Bearer ")
	if !ok || token == "" {
		return Identity{}, fmt.Errorf("%w: no bearer token", ErrUnauthenticated)
	}
	key := sha256.Sum256([]byte(token))
	now := a.now()
	if a.CacheTTL > 0 {
		a.mu.Lock()
		e, hit := a.cache[key]
		a.mu.Unlock()
		if hit && now.Before(e.expires) {
			return e.id, e.err
		}
	}
	id, err := a.review(ctx, token)
	if err != nil && !errors.Is(err, ErrUnauthenticated) && !errors.Is(err, ErrForbidden) {
		return Identity{}, err // the API server is unreachable: fail closed, don't cache
	}
	if a.CacheTTL > 0 {
		a.mu.Lock()
		if a.cache == nil {
			a.cache = map[[32]byte]entry{}
		}
		for k, e := range a.cache { // keep it small
			if now.After(e.expires) {
				delete(a.cache, k)
			}
		}
		a.cache[key] = entry{id: id, err: err, expires: now.Add(a.CacheTTL)}
		a.mu.Unlock()
	}
	return id, err
}

func (a *Authenticator) review(ctx context.Context, token string) (Identity, error) {
	tr, err := a.Reviewer.Create(ctx, &authnv1.TokenReview{Spec: authnv1.TokenReviewSpec{
		Token: token, Audiences: []string{a.Audience},
	}}, metav1.CreateOptions{})
	if err != nil {
		return Identity{}, fmt.Errorf("token review: %w", err)
	}
	return Decide(tr.Status, a.Audience, a.Allowed)
}

// Decide turns a TokenReview status into an identity or a refusal.
func Decide(st authnv1.TokenReviewStatus, audience string, allowed []string) (Identity, error) {
	if !st.Authenticated {
		why := st.Error
		if why == "" {
			why = "token not authenticated"
		}
		return Identity{}, fmt.Errorf("%w: %s", ErrUnauthenticated, why)
	}
	if !slices.Contains(st.Audiences, audience) {
		return Identity{}, fmt.Errorf("%w: token is not for audience %s", ErrUnauthenticated, audience)
	}
	u := st.User
	parts := strings.Split(u.Username, ":")
	if len(parts) != 4 || parts[0] != "system" || parts[1] != "serviceaccount" {
		return Identity{}, fmt.Errorf("%w: %s is not a service account", ErrForbidden, u.Username)
	}
	extra := func(k string) string {
		if v := u.Extra["authentication.kubernetes.io/"+k]; len(v) > 0 {
			return v[0]
		}
		return ""
	}
	id := Identity{Username: u.Username, Namespace: parts[2], ServiceAccount: parts[3],
		Pod: extra("pod-name"), PodUID: extra("pod-uid"), Node: extra("node-name"), CredentialID: extra("credential-id")}
	if id.Pod == "" {
		return id, fmt.Errorf("%w: token for %s isn't bound to a pod (minted by hand?)", ErrForbidden, u.Username)
	}
	if !slices.Contains(allowed, u.Username) {
		return id, fmt.Errorf("%w: %s may not use this gateway", ErrForbidden, u.Username)
	}
	return id, nil
}

func (a *Authenticator) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}
