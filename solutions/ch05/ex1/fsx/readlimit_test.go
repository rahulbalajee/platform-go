package fsx_test

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"oskit/fsx"
)

func TestReadFileLimitReturnsSmallFiles(t *testing.T) {
	name := filepath.Join(t.TempDir(), "config.json")
	want := []byte(`{"replicas": 3}`)
	if err := os.WriteFile(name, want, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, limit := range []int64{int64(len(want)), 1 << 20} {
		got, err := fsx.ReadFileLimit(name, limit)
		if err != nil || !bytes.Equal(got, want) {
			t.Fatalf("limit %d: got %q, %v; want %q", limit, got, err, want)
		}
	}
}

func TestReadFileLimitRefusesLargeFiles(t *testing.T) {
	name := filepath.Join(t.TempDir(), "big.log")
	if err := os.WriteFile(name, bytes.Repeat([]byte("x"), 1001), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := fsx.ReadFileLimit(name, 1000)
	if !errors.Is(err, fsx.ErrTooLarge) {
		t.Fatalf("err = %v, want fsx.ErrTooLarge", err)
	}
	if !strings.Contains(err.Error(), name) {
		t.Errorf("error %q does not name the file", err)
	}
	if got != nil {
		t.Errorf("got %d bytes with the error, want nil", len(got))
	}
}

// TestReadFileLimitStopsOnEndlessInput: /dev/zero never ends, so a reader
// that does not stop at the limit runs until it runs out of memory.
func TestReadFileLimitStopsOnEndlessInput(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("no /dev/zero")
	}
	_, err := fsx.ReadFileLimit("/dev/zero", 1<<20)
	if !errors.Is(err, fsx.ErrTooLarge) {
		t.Fatalf("err = %v, want fsx.ErrTooLarge", err)
	}
}

func TestReadFileLimitMissingFile(t *testing.T) {
	_, err := fsx.ReadFileLimit(filepath.Join(t.TempDir(), "nope"), 10)
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("err = %v, want fs.ErrNotExist", err)
	}
}
