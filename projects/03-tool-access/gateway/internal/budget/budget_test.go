package budget

import (
	"testing"
	"time"
)

func TestBudget(t *testing.T) {
	now := time.Unix(0, 0)
	l := &Limiter{TokensPerWindow: 20000, Window: time.Hour, RequestsPerMinute: 100, Now: func() time.Time { return now }}
	d := l.Reserve("a", 16000)
	if !d.OK {
		t.Fatal(d)
	}
	if l.Reserve("a", 16000).OK {
		t.Error("two 16k reservations fit in 20k")
	}
	l.Settle("a", 16000, 9000)
	if r := l.Remaining("a"); r != 11000 {
		t.Errorf("remaining %d after spending 9000", r)
	}
	if !l.Reserve("a", 10000).OK {
		t.Error("10k should fit in 11k")
	}
	l.Settle("a", 10000, 10000)
	d = l.Reserve("a", 2000)
	if d.OK || d.Reason != "token budget exhausted" || d.RetryAfter != time.Hour {
		t.Errorf("exhausted: %+v", d)
	}
	if !l.Reserve("b", 16000).OK {
		t.Error("budgets are per identity")
	}
	now = now.Add(time.Hour + time.Second)
	if r := l.Remaining("a"); r != 20000 {
		t.Errorf("window rolled: remaining %d", r)
	}
}

func TestRequestRate(t *testing.T) {
	now := time.Unix(0, 0)
	l := &Limiter{TokensPerWindow: 1 << 30, Window: time.Hour, RequestsPerMinute: 3, Now: func() time.Time { return now }}
	for range 3 {
		d := l.Reserve("a", 1)
		l.Settle("a", 1, 1)
		if !d.OK {
			t.Fatal(d)
		}
	}
	if d := l.Reserve("a", 1); d.OK || d.Reason != "request rate limit" {
		t.Errorf("4th request in a minute: %+v", d)
	}
	now = now.Add(61 * time.Second)
	if !l.Reserve("a", 1).OK {
		t.Error("rate window rolled")
	}
}
