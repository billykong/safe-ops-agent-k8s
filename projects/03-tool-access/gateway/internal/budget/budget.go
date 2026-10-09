// Package budget caps each agent identity's model use (P3-03): tokens per
// rolling window and requests per minute. A request is refused before it
// is sent if its max_tokens could overrun what's left, so a runaway loop
// is cut off by the gateway, not discovered on the bill.
//
// State is in memory: one gateway replica, and a restart starts every
// window afresh (documented limit).
package budget

import (
	"sync"
	"time"
)

type event struct {
	at     time.Time
	tokens int
}

type account struct {
	spent    []event     // tokens charged within the window
	requests []time.Time // requests within the last minute
	reserved int         // max_tokens of requests in flight
}

// Limiter tracks every identity's spend.
type Limiter struct {
	TokensPerWindow   int
	Window            time.Duration
	RequestsPerMinute int
	Now               func() time.Time

	mu       sync.Mutex
	accounts map[string]*account
}

// Decision is the outcome of Reserve.
type Decision struct {
	OK         bool
	Reason     string
	RetryAfter time.Duration
	Remaining  int
}

func (l *Limiter) now() time.Time {
	if l.Now != nil {
		return l.Now()
	}
	return time.Now()
}

func (l *Limiter) acct(id string, now time.Time) *account {
	if l.accounts == nil {
		l.accounts = map[string]*account{}
	}
	a := l.accounts[id]
	if a == nil {
		a = &account{}
		l.accounts[id] = a
	}
	keep := a.spent[:0]
	for _, e := range a.spent {
		if now.Sub(e.at) < l.Window {
			keep = append(keep, e)
		}
	}
	a.spent = keep
	reqs := a.requests[:0]
	for _, t := range a.requests {
		if now.Sub(t) < time.Minute {
			reqs = append(reqs, t)
		}
	}
	a.requests = reqs
	return a
}

func (a *account) used() int {
	n := a.reserved
	for _, e := range a.spent {
		n += e.tokens
	}
	return n
}

// Reserve admits a request that may use up to maxTokens of output, or
// says why not.
func (l *Limiter) Reserve(id string, maxTokens int) Decision {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	a := l.acct(id, now)
	remaining := l.TokensPerWindow - a.used()
	if len(a.requests) >= l.RequestsPerMinute {
		return Decision{Reason: "request rate limit", RetryAfter: time.Minute - now.Sub(a.requests[0]), Remaining: remaining}
	}
	if maxTokens > remaining {
		d := Decision{Reason: "token budget exhausted", Remaining: remaining, RetryAfter: l.Window}
		if len(a.spent) > 0 {
			d.RetryAfter = l.Window - now.Sub(a.spent[0].at)
		}
		return d
	}
	a.requests = append(a.requests, now)
	a.reserved += maxTokens
	return Decision{OK: true, Remaining: remaining - maxTokens}
}

// Settle replaces a reservation with what the request actually used.
func (l *Limiter) Settle(id string, maxTokens, used int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	a := l.acct(id, now)
	a.reserved = max(a.reserved-maxTokens, 0)
	if used > 0 {
		a.spent = append(a.spent, event{at: now, tokens: used})
	}
}

// Remaining is what id may still spend in the window.
func (l *Limiter) Remaining(id string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.TokensPerWindow - l.acct(id, l.now()).used()
}
