package main

// START imports OMIT
import (
	"bufio"
	"errors"
	"strings"
	"testing"
)

// END imports OMIT

// START naive OMIT
const sample = "t 10.0.0.1 GET /a 200 10 1ms\n" +
	"t 10.0.0.2 GET /b 503 10 1ms\n" +
	"garbage\n" +
	"t 10.0.0.3 GET /c 404 10 1ms" // no trailing newline

// longLine is sample with a 70,000-byte line in front of it.
var longLine = sample[:31] + strings.Repeat("x", 70_000) + "\n" + sample

func TestReadAllCountsEveryLine(t *testing.T) {
	st, err := scanReadAll(strings.NewReader(longLine))
	if err != nil || st.Lines != 6 || st.Status[2] != 2 || st.Malformed != 2 {
		t.Fatalf("readall: %+v, %v", st, err)
	}
}

// TestScannerBugIsSilent pins down the trap the naive version falls into:
// bufio.Scanner stops at a line over 64 KiB, and Scan just returns false.
func TestScannerBugIsSilent(t *testing.T) {
	st, err := scanScanner(strings.NewReader(longLine))
	if err != nil || st.Lines != 1 {
		t.Fatalf("naive scanner: lines=%d err=%v; want 1 line and no error",
			st.Lines, err)
	}
	sc := bufio.NewScanner(strings.NewReader(longLine))
	for sc.Scan() {
	}
	if !errors.Is(sc.Err(), bufio.ErrTooLong) {
		t.Fatalf("Scanner.Err() = %v, want bufio.ErrTooLong", sc.Err())
	}
}

// END naive OMIT
