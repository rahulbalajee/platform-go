// START readertest OMIT

package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/iotest"
)

// TestLogReaderIsAWellBehavedReader reads the log in many small pieces.
// iotest.TestReader fails if the piece size changes the bytes, or if Read
// breaks the io.Reader contract for empty buffers and at the end.
func TestLogReaderIsAWellBehavedReader(t *testing.T) {
	want, err := io.ReadAll(newLogReader(200, -1))
	if err != nil {
		t.Fatal(err)
	}
	if err := iotest.TestReader(newLogReader(200, -1), want); err != nil {
		t.Fatal(err)
	}
}

func TestLogReaderLines(t *testing.T) {
	b, err := io.ReadAll(newLogReader(3, 1))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("got %d lines, want 3", len(lines))
	}
	for i, line := range lines {
		if f := strings.Fields(line); len(f) != 7 {
			t.Errorf("line %d has %d fields, want 7", i, len(f))
		}
	}
	if n := len(lines[1]); n < 1<<20 {
		t.Errorf("line 1 is %d bytes, want more than 1 MiB", n)
	}
}

// END readertest OMIT

// START writertest OMIT
func TestCountWriter(t *testing.T) {
	var c countWriter
	fmt.Fprint(&c, "a\nb")
	fmt.Fprint(&c, "c\n")
	if want := (countWriter{Bytes: 5, Lines: 2, MaxWrite: 3}); c != want {
		t.Fatalf("got %+v, want %+v", c, want)
	}
}

func TestRunWritesFileAndSummary(t *testing.T) {
	out := filepath.Join(t.TempDir(), "access.log")
	var stdout, stderr bytes.Buffer
	if err := run(&stdout, &stderr, 100, -1, 0, out); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("%s: 100 lines, %d bytes, sha256 %x\n",
		out, len(data), sha256.Sum256(data))
	if stderr.String() != want || stdout.Len() != 0 {
		t.Fatalf("stderr = %q, want %q", stderr.String(), want)
	}
}

func TestRunLimitCutsAnEndlessLog(t *testing.T) {
	var stdout bytes.Buffer
	if err := run(&stdout, io.Discard, 0, -1, 300, ""); err != nil {
		t.Fatal(err)
	}
	if stdout.Len() != 300 {
		t.Fatalf("wrote %d bytes, want 300", stdout.Len())
	}
}

// END writertest OMIT
