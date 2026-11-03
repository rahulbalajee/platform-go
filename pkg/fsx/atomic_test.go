package fsx_test

import (
	"bytes"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"

	"go.uber.org/goleak"

	"github.com/rahulbalajee/platform-go/pkg/fsx"
)

// TestMain doubles as a helper process for the cross-process lock test and
// fails the package if any test leaks a goroutine.
func TestMain(m *testing.M) {
	if path := os.Getenv("FSX_HOLD_LOCK"); path != "" {
		holdLock(path) // never returns
	}
	goleak.VerifyTestMain(m)
}

func TestWriteFileCreatesAndReplaces(t *testing.T) {
	name := filepath.Join(t.TempDir(), "config.json")
	for _, content := range []string{`{"v":1}`, `{"v":2}`} {
		if err := fsx.WriteFile(name, []byte(content), 0o640); err != nil {
			t.Fatal(err)
		}
		got, err := os.ReadFile(name)
		if err != nil || string(got) != content {
			t.Fatalf("read back %q, %v; want %q", got, err, content)
		}
	}
	if runtime.GOOS != "windows" {
		fi, err := os.Stat(name)
		if err != nil || fi.Mode().Perm() != 0o640 {
			t.Fatalf("mode = %v, %v; want 0640", fi.Mode().Perm(), err)
		}
	}
}

func TestWriteFailureLeavesOldFileAndNoDebris(t *testing.T) {
	dir := t.TempDir()
	name := filepath.Join(dir, "state.json")
	if err := fsx.WriteFile(name, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	boom := errors.New("disk on fire")
	err := fsx.Write(name, 0o600, func(w io.Writer) error {
		_, _ = io.WriteString(w, "half of the new cont")
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatalf("err = %v, want it to wrap %v", err, boom)
	}
	if got, _ := os.ReadFile(name); string(got) != "old" {
		t.Fatalf("contents = %q after failed write, want %q", got, "old")
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("directory has %d entries, want only state.json: %v", len(entries), entries)
	}
}

func TestWriteMissingDirectory(t *testing.T) {
	err := fsx.WriteFile(filepath.Join(t.TempDir(), "nope", "x"), nil, 0o600)
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("err = %v, want fs.ErrNotExist", err)
	}
}

// START torn OMIT
// TestReadersNeverSeeTornFiles rewrites a file in a loop while readers read
// it. Every read must be one complete version: never empty, never short,
// never a mix of two versions.
func TestReadersNeverSeeTornFiles(t *testing.T) {
	name := filepath.Join(t.TempDir(), "routes.txt")
	versions := [][]byte{
		bytes.Repeat([]byte("a"), 256<<10), bytes.Repeat([]byte("b"), 256<<10),
	}
	if err := fsx.WriteFile(name, versions[0], 0o600); err != nil {
		t.Fatal(err)
	}
	var done atomic.Bool
	var torn, reads atomic.Int64
	var wg sync.WaitGroup
	for range 4 {
		wg.Go(func() {
			for !done.Load() {
				b, err := os.ReadFile(name)
				reads.Add(1)
				whole := bytes.Equal(b, versions[0]) || bytes.Equal(b, versions[1])
				if err != nil || !whole {
					torn.Add(1)
				}
			}
		})
	}
	for i := range 200 {
		if err := fsx.WriteFile(name, versions[i%2], 0o600); err != nil {
			t.Error(err)
			break
		}
	}
	done.Store(true)
	wg.Wait()
	if torn.Load() > 0 {
		t.Fatalf("%d of %d reads saw a torn file", torn.Load(), reads.Load())
	}
}

// END torn OMIT
