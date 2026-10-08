package authn

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	authnv1 "k8s.io/api/authentication/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const aud = "llm-gateway.safe-ops.io"

var allowed = []string{"system:serviceaccount:agent:runner"}

func status(user string, auds []string, pod bool) authnv1.TokenReviewStatus {
	extra := map[string]authnv1.ExtraValue{}
	if pod {
		extra["authentication.kubernetes.io/pod-name"] = authnv1.ExtraValue{"runner-abc"}
		extra["authentication.kubernetes.io/pod-uid"] = authnv1.ExtraValue{"uid-1"}
	}
	return authnv1.TokenReviewStatus{Authenticated: true, Audiences: auds, User: authnv1.UserInfo{Username: user, Extra: extra}}
}

func TestDecide(t *testing.T) {
	runner := "system:serviceaccount:agent:runner"
	cases := []struct {
		name string
		st   authnv1.TokenReviewStatus
		want error
	}{
		{"pod-bound runner token for this audience", status(runner, []string{aud}, true), nil},
		{"not authenticated", authnv1.TokenReviewStatus{Error: "token audiences invalid"}, ErrUnauthenticated},
		{"other audience", status(runner, []string{"https://kubernetes.default.svc"}, true), ErrUnauthenticated},
		{"not pod-bound", status(runner, []string{aud}, false), ErrForbidden},
		{"not allowed", status("system:serviceaccount:agent:default", []string{aud}, true), ErrForbidden},
		{"a human", status("alice", []string{aud}, true), ErrForbidden},
	}
	for _, c := range cases {
		id, err := Decide(c.st, aud, allowed)
		if (c.want == nil) != (err == nil) || (c.want != nil && !errors.Is(err, c.want)) {
			t.Errorf("%s: err %v, want %v", c.name, err, c.want)
		}
		if c.want == nil && (id.ServiceAccount != "runner" || id.Namespace != "agent" || id.Pod != "runner-abc") {
			t.Errorf("%s: identity %+v", c.name, id)
		}
	}
}

type fakeReviewer struct {
	calls int
	st    authnv1.TokenReviewStatus
	err   error
}

func (f *fakeReviewer) Create(_ context.Context, tr *authnv1.TokenReview, _ metav1.CreateOptions) (*authnv1.TokenReview, error) {
	f.calls++
	if len(tr.Spec.Audiences) != 1 || tr.Spec.Audiences[0] != aud {
		return nil, errors.New("review must ask for this gateway's audience")
	}
	return &authnv1.TokenReview{Status: f.st}, f.err
}

func req(token string) *http.Request {
	r, _ := http.NewRequest("GET", "/", nil)
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	return r
}

func TestAuthenticateCachesAndFailsClosed(t *testing.T) {
	now := time.Unix(0, 0)
	f := &fakeReviewer{st: status("system:serviceaccount:agent:runner", []string{aud}, true)}
	a := &Authenticator{Reviewer: f, Audience: aud, Allowed: allowed, CacheTTL: 10 * time.Second, Now: func() time.Time { return now }}
	if _, err := a.Authenticate(context.Background(), req("")); !errors.Is(err, ErrUnauthenticated) {
		t.Errorf("no token: %v", err)
	}
	for range 3 {
		if _, err := a.Authenticate(context.Background(), req("t1")); err != nil {
			t.Fatal(err)
		}
	}
	if f.calls != 1 {
		t.Errorf("cached: %d reviews, want 1", f.calls)
	}
	// Revoked: after the TTL, the review is redone and refuses.
	f.st = authnv1.TokenReviewStatus{Error: "service account UID does not match"}
	now = now.Add(11 * time.Second)
	if _, err := a.Authenticate(context.Background(), req("t1")); !errors.Is(err, ErrUnauthenticated) {
		t.Errorf("after revocation and TTL: %v", err)
	}
	// API server down: refuse, and don't cache the failure.
	f.err = errors.New("connection refused")
	if _, err := a.Authenticate(context.Background(), req("t2")); err == nil || errors.Is(err, ErrUnauthenticated) || errors.Is(err, ErrForbidden) {
		t.Errorf("API down: %v", err)
	}
	f.err, f.st = nil, status("system:serviceaccount:agent:runner", []string{aud}, true)
	if _, err := a.Authenticate(context.Background(), req("t2")); err != nil {
		t.Errorf("API back: %v", err)
	}
}
