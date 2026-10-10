// Package chain is the audit sink's store (P4-04): an append-only file of
// JSON lines, each holding one audit event, its sequence number, the hash
// of the previous line and its own hash. Changing, removing or reordering
// any line breaks every hash after it, so an edit is detectable by anyone
// who re-reads the file. Cutting lines off the end leaves a valid shorter
// chain; that shows only against a record of the length kept elsewhere
// (the running sink's own count, its log, Prometheus).
//
// A line is {"seq":N,"prev":"<hex>","hash":"<hex>","event":<event>}, and
// hash = sha256(prev + "\n" + N + "\n" + event), with event exactly the
// bytes stored. Lines are written by hand, not by encoding/json, which
// would HTML-escape the event and change its bytes.
package chain

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"sync"
)

// Genesis is the prev of the first line.
var Genesis = string(bytes.Repeat([]byte("0"), 64))

// Hash is a line's hash.
func Hash(prev string, seq uint64, event []byte) string {
	h := sha256.New()
	h.Write([]byte(prev))
	h.Write([]byte("\n" + strconv.FormatUint(seq, 10) + "\n"))
	h.Write(event)
	return hex.EncodeToString(h.Sum(nil))
}

type line struct {
	Seq   uint64          `json:"seq"`
	Prev  string          `json:"prev"`
	Hash  string          `json:"hash"`
	Event json.RawMessage `json:"event"`
}

// State is where a chain ends: how many lines and the last hash.
type State struct {
	Entries uint64
	Head    string
}

// BrokenError says where a chain stops verifying.
type BrokenError struct {
	Line   uint64 // 1-based line number
	Reason string
}

func (e *BrokenError) Error() string { return fmt.Sprintf("line %d: %s", e.Line, e.Reason) }

// Verify reads a whole chain and checks every line, calling fn (if not
// nil) with each event. It returns the chain's state up to the first
// broken line.
func Verify(r io.Reader, fn func(seq uint64, event json.RawMessage)) (State, error) {
	st := State{Head: Genesis}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 1<<20), 64<<20)
	for sc.Scan() {
		n := st.Entries + 1
		var l line
		if err := json.Unmarshal(sc.Bytes(), &l); err != nil {
			return st, &BrokenError{n, "not a chain line: " + err.Error()}
		}
		switch {
		case l.Seq != n:
			return st, &BrokenError{n, fmt.Sprintf("seq %d, want %d (a line removed, added or moved)", l.Seq, n)}
		case l.Prev != st.Head:
			return st, &BrokenError{n, "prev doesn't match the line before"}
		case l.Hash != Hash(l.Prev, l.Seq, l.Event):
			return st, &BrokenError{n, "hash doesn't match the line's content (edited)"}
		}
		if fn != nil {
			fn(l.Seq, l.Event)
		}
		st = State{Entries: n, Head: l.Hash}
	}
	if err := sc.Err(); err != nil {
		return st, &BrokenError{st.Entries + 1, err.Error()}
	}
	return st, nil
}

// Log appends to a chain file. Safe for concurrent use.
type Log struct {
	mu   sync.Mutex
	f    *os.File
	path string
	size int64
	st   State
}

// Open opens or creates the chain at path and verifies it. A partly
// written last line (a crash mid-append, never acknowledged, so the API
// server sends it again) is cut off. If the chain doesn't verify, Open
// still returns a Log that appends after the last good line's count, so
// nothing new is lost, together with the BrokenError: the file keeps the
// evidence, and every later verification fails until someone looks.
func Open(path string) (*Log, error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_APPEND, 0o640)
	if err != nil {
		return nil, err
	}
	data, err := io.ReadAll(f)
	if err != nil {
		f.Close()
		return nil, err
	}
	if i := bytes.LastIndexByte(data, '\n'); i+1 != len(data) {
		if err := f.Truncate(int64(i + 1)); err != nil {
			f.Close()
			return nil, err
		}
		data = data[:i+1]
	}
	l := &Log{f: f, path: path, size: int64(len(data))}
	l.st, err = Verify(bytes.NewReader(data), nil)
	if err != nil {
		// Continue after the line count actually in the file, so the
		// sequence stays unique; the break stays where it is.
		l.st.Entries = uint64(bytes.Count(data, []byte("\n")))
	}
	return l, err
}

// Append adds events as one write and syncs it to disk before returning,
// so an acknowledged batch is durable. On error nothing is kept.
func (l *Log) Append(events []json.RawMessage) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	var buf bytes.Buffer
	st := l.st
	for _, ev := range events {
		var c bytes.Buffer
		if err := json.Compact(&c, ev); err != nil {
			return fmt.Errorf("event %d: %w", st.Entries+1, err)
		}
		seq := st.Entries + 1
		h := Hash(st.Head, seq, c.Bytes())
		fmt.Fprintf(&buf, `{"seq":%d,"prev":"%s","hash":"%s","event":`, seq, st.Head, h)
		buf.Write(c.Bytes())
		buf.WriteString("}\n")
		st = State{Entries: seq, Head: h}
	}
	if _, err := l.f.Write(buf.Bytes()); err != nil {
		l.f.Truncate(l.size)
		return err
	}
	if err := l.f.Sync(); err != nil {
		l.f.Truncate(l.size)
		return err
	}
	l.size += int64(buf.Len())
	l.st = st
	return nil
}

// State is what this Log has written: the chain as it must be on disk.
func (l *Log) State() State {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.st
}

// Check re-reads the file from disk and compares it with what this Log
// wrote: every line must verify, and the chain must reach exactly the
// count and head it had when the check began. That catches edits (a
// hash fails) and lines cut off the end (fewer entries than written).
func (l *Log) Check() (State, error) {
	l.mu.Lock()
	want, size := l.st, l.size
	l.mu.Unlock()
	f, err := os.Open(l.path)
	if err != nil {
		return State{}, err
	}
	defer f.Close()
	got, err := Verify(io.LimitReader(f, size), nil)
	if err != nil {
		return got, err
	}
	if got != want {
		return got, &BrokenError{got.Entries + 1, fmt.Sprintf("file ends at %d entries (head %.12s), the sink wrote %d (head %.12s): lines cut off or replaced",
			got.Entries, got.Head, want.Entries, want.Head)}
	}
	return got, nil
}

// Close closes the file.
func (l *Log) Close() error { return l.f.Close() }

// IsBroken says whether err is a verification failure (not an I/O error).
func IsBroken(err error) bool {
	var b *BrokenError
	return errors.As(err, &b)
}
