package chain

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func events(n int, tag string) []json.RawMessage {
	var out []json.RawMessage
	for i := 0; i < n; i++ {
		out = append(out, json.RawMessage(`{"auditID":"`+tag+string(rune('a'+i))+`", "verb": "create", "note":"<&>"}`))
	}
	return out
}

func newLog(t *testing.T) (*Log, string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "audit.jsonl")
	l, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	return l, p
}

func lines(t *testing.T, p string) []string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return strings.SplitAfter(strings.TrimSuffix(string(b), "\n"), "\n")
}

func write(t *testing.T, p string, ls []string) {
	t.Helper()
	s := strings.Join(ls, "")
	if !strings.HasSuffix(s, "\n") {
		s += "\n"
	}
	if err := os.WriteFile(p, []byte(s), 0o640); err != nil {
		t.Fatal(err)
	}
}

func TestAppendVerifyReopen(t *testing.T) {
	l, p := newLog(t)
	if err := l.Append(events(3, "x")); err != nil {
		t.Fatal(err)
	}
	if err := l.Append(events(2, "y")); err != nil {
		t.Fatal(err)
	}
	st, err := l.Check()
	if err != nil || st.Entries != 5 {
		t.Fatalf("check: %v %+v", err, st)
	}
	// The event is stored compacted but otherwise as sent: not HTML-escaped.
	if !strings.Contains(lines(t, p)[0], `"note":"<&>"`) {
		t.Fatalf("event bytes changed: %s", lines(t, p)[0])
	}
	l.Close()
	l2, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer l2.Close()
	if l2.State() != st {
		t.Fatalf("reopened at %+v, want %+v", l2.State(), st)
	}
	if err := l2.Append(events(1, "z")); err != nil {
		t.Fatal(err)
	}
	if st, err := l2.Check(); err != nil || st.Entries != 6 {
		t.Fatalf("after reopen: %v %+v", err, st)
	}
}

func TestTamperingIsDetected(t *testing.T) {
	cases := map[string]func([]string) []string{
		"edit an event": func(ls []string) []string {
			ls[1] = strings.Replace(ls[1], `"verb":"create"`, `"verb":"get"`, 1)
			return ls
		},
		"remove a line": func(ls []string) []string { return append(ls[:1:1], ls[2:]...) },
		"swap two lines": func(ls []string) []string {
			ls[1], ls[2] = ls[2], ls[1]
			return ls
		},
		"rewrite a line and its hash": func(ls []string) []string {
			// An editor who recomputes the edited line's hash still breaks
			// the next line's prev.
			var l line
			json.Unmarshal([]byte(ls[1]), &l)
			ev := bytes.Replace(l.Event, []byte("create"), []byte("get"), 1)
			h := Hash(l.Prev, l.Seq, ev)
			ls[1] = `{"seq":2,"prev":"` + l.Prev + `","hash":"` + h + `","event":` + string(ev) + "}\n"
			return ls
		},
	}
	for name, tamper := range cases {
		t.Run(name, func(t *testing.T) {
			l, p := newLog(t)
			l.Append(events(4, "x"))
			write(t, p, tamper(lines(t, p)))
			if _, err := l.Check(); !IsBroken(err) {
				t.Fatalf("not detected by the running sink: %v", err)
			}
			f, _ := os.Open(p)
			defer f.Close()
			if _, err := Verify(f, nil); !IsBroken(err) {
				t.Fatalf("not detected by a fresh verify: %v", err)
			}
		})
	}
}

func TestTruncationNeedsTheRecord(t *testing.T) {
	l, p := newLog(t)
	l.Append(events(4, "x"))
	write(t, p, lines(t, p)[:2])
	// The shorter file is a valid chain by itself...
	f, _ := os.Open(p)
	if st, err := Verify(f, nil); err != nil || st.Entries != 2 {
		t.Fatalf("prefix: %v %+v", err, st)
	}
	f.Close()
	// ...but not against what the sink wrote.
	if _, err := l.Check(); !IsBroken(err) {
		t.Fatalf("truncation not detected: %v", err)
	}
}

func TestPartialTailIsCut(t *testing.T) {
	l, p := newLog(t)
	l.Append(events(2, "x"))
	l.Close()
	f, _ := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"seq":3,"prev":"`)
	f.Close()
	l2, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer l2.Close()
	if l2.State().Entries != 2 {
		t.Fatalf("state %+v", l2.State())
	}
	if err := l2.Append(events(1, "y")); err != nil {
		t.Fatal(err)
	}
	if _, err := l2.Check(); err != nil {
		t.Fatal(err)
	}
}

func TestOpenBrokenKeepsAppending(t *testing.T) {
	l, p := newLog(t)
	l.Append(events(3, "x"))
	l.Close()
	ls := lines(t, p)
	ls[0] = strings.Replace(ls[0], "create", "delete", 1)
	write(t, p, ls)
	l2, err := Open(p)
	if !IsBroken(err) {
		t.Fatalf("open: %v", err)
	}
	defer l2.Close()
	if err := l2.Append(events(1, "y")); err != nil {
		t.Fatal(err)
	}
	got := lines(t, p)
	if len(got) != 4 || !strings.HasPrefix(got[3], `{"seq":4,`) {
		t.Fatalf("appended %q", got[len(got)-1])
	}
}

func TestBadEventRejectsTheBatch(t *testing.T) {
	l, p := newLog(t)
	if err := l.Append([]json.RawMessage{json.RawMessage(`{"a":1}`), json.RawMessage(`{bad`)}); err == nil {
		t.Fatal("accepted invalid JSON")
	}
	if b, _ := os.ReadFile(p); len(b) != 0 || l.State().Entries != 0 {
		t.Fatalf("partial batch kept: %q", b)
	}
}
