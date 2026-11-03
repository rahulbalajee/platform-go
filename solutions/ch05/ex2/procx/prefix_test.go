package procx_test

import (
	"bytes"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"

	"oskit/procx"
)

func TestPrefixWriterPrefixesEveryLine(t *testing.T) {
	var out bytes.Buffer
	w := procx.NewPrefixWriter(&out, "[tf] ")
	n, err := w.Write([]byte("plan\napply\n"))
	if n != 11 || err != nil {
		t.Fatalf("Write = %d, %v; want 11, nil", n, err)
	}
	if got, want := out.String(), "[tf] plan\n[tf] apply\n"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// TestPrefixWriterHandlesAnyChunking writes the same text one byte at a
// time: a pipe can split a child's output anywhere.
func TestPrefixWriterHandlesAnyChunking(t *testing.T) {
	var out bytes.Buffer
	w := procx.NewPrefixWriter(&out, "> ")
	for _, b := range []byte("one\ntwo\nthree\n") {
		if _, err := w.Write([]byte{b}); err != nil {
			t.Fatal(err)
		}
	}
	if got, want := out.String(), "> one\n> two\n> three\n"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestPrefixWriterHoldsPartialLinesUntilFlush(t *testing.T) {
	var out bytes.Buffer
	w := procx.NewPrefixWriter(&out, "> ")
	fmt.Fprint(w, "done\nalmost")
	if got := out.String(); got != "> done\n" {
		t.Fatalf("before Flush: got %q, want only the complete line", got)
	}
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	if got, want := out.String(), "> done\n> almost\n"; got != want {
		t.Fatalf("after Flush: got %q, want %q", got, want)
	}
	if err := w.Flush(); err != nil || out.String() != "> done\n> almost\n" {
		t.Fatalf("a second Flush wrote again: %q, %v", out.String(), err)
	}
}

// TestPrefixWriterIsSafeForConcurrentUse: os/exec copies stdout and stderr
// on two goroutines, and both may write to the same PrefixWriter.
func TestPrefixWriterIsSafeForConcurrentUse(t *testing.T) {
	var out bytes.Buffer
	w := procx.NewPrefixWriter(&out, "> ")
	var wg sync.WaitGroup
	for g := range 2 {
		wg.Go(func() {
			for i := range 100 {
				fmt.Fprintf(w, "g%d line %d\n", g, i)
			}
		})
	}
	wg.Wait()
	lines := strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n")
	if len(lines) != 200 {
		t.Fatalf("got %d lines, want 200", len(lines))
	}
	for _, l := range lines {
		if !strings.HasPrefix(l, "> g") || strings.Count(l, ">") != 1 {
			t.Fatalf("mangled line %q", l)
		}
	}
}

type failWriter struct{}

func (failWriter) Write([]byte) (int, error) { return 0, errors.New("disk full") }

func TestPrefixWriterReportsWriteErrors(t *testing.T) {
	w := procx.NewPrefixWriter(failWriter{}, "> ")
	if _, err := w.Write([]byte("x\n")); err == nil {
		t.Fatal("Write succeeded on a failing writer")
	}
}
