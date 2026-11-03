package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"errors"
	"strings"
	"testing"
	"testing/fstest"
)

const sample = "t 10.0.0.1 GET /a 200 10 1ms\n" +
	"t 10.0.0.2 GET /b 503 10 1ms\n" +
	"garbage\n" +
	"t 10.0.0.3 GET /c 404 10 1ms" // no trailing newline

func gz(t *testing.T, s string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write([]byte(s)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestLinesTruncatesLongLinesAndKeepsGoing(t *testing.T) {
	in := "short\n" + strings.Repeat("x", 100) + "\nafter\nlast"
	var got []string
	var truncated []bool
	for line, err := range Lines(strings.NewReader(in), 16) {
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, string(line.Bytes))
		truncated = append(truncated, line.Truncated)
	}
	want := []string{"short", strings.Repeat("x", 16), "after", "last"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("lines = %q, want %q", got, want)
	}
	if !truncated[1] || truncated[0] || truncated[2] {
		t.Fatalf("truncated flags = %v", truncated)
	}
}

// START fstest OMIT
func TestScanFSReadsPlainAndGzippedFiles(t *testing.T) {
	fsys := fstest.MapFS{
		"access.log":      {Data: []byte(sample)},
		"access.log.1.gz": {Data: gz(t, sample)},
		"error.txt":       {Data: []byte("not matched by the glob\n")},
	}
	st, err := scanFS(fsys, "access.log*", 64<<10)
	if err != nil {
		t.Fatal(err)
	}
	if st.Lines != 8 || st.Status[2] != 2 || st.Status[4] != 2 ||
		st.Status[5] != 2 || st.Malformed != 2 {
		t.Fatalf("stats = %+v", st)
	}
}

// END fstest OMIT

// TestScannerBugIsSilent pins down the trap the naive version falls into:
// bufio.Scanner stops at a line over 64 KiB, and Scan just returns false.
func TestScannerBugIsSilent(t *testing.T) {
	in := sample[:31] + strings.Repeat("x", 70_000) + "\n" + sample
	st, err := scanScanner(strings.NewReader(in))
	if err != nil || st.Lines != 1 {
		t.Fatalf("naive scanner: lines=%d err=%v; want 1 line and no error", st.Lines, err)
	}
	sc := bufio.NewScanner(strings.NewReader(in))
	for sc.Scan() {
	}
	if !errors.Is(sc.Err(), bufio.ErrTooLong) {
		t.Fatalf("Scanner.Err() = %v, want bufio.ErrTooLong", sc.Err())
	}
	st, err = scan(strings.NewReader(in), 64<<10)
	if err != nil || st.Lines != 6 || st.Truncated != 1 {
		t.Fatalf("stream: %+v, %v", st, err)
	}
}
