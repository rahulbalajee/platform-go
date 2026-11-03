package fsx_test

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"testing/fstest"

	"oskit/fsx"
)

func release(n int) fstest.MapFS {
	v := strconv.Itoa(n)
	return fstest.MapFS{
		"config.yaml": {Data: []byte("version: " + v + "\n")},
		"bin/run.sh":  {Data: []byte("#!/bin/sh\necho " + v + "\n"), Mode: 0o755},
	}
}

// TestInstallDirSwapsWholeTrees installs releases over each other while
// readers read through dst. Every read must find a complete file. On macOS
// an open through a symlink that is being replaced can fail with EINVAL;
// Linux never fails it, so only Darwin gets that allowance.
func TestInstallDirSwapsWholeTrees(t *testing.T) {
	dst := filepath.Join(t.TempDir(), "current")
	if err := fsx.InstallDir(release(0), dst); err != nil {
		t.Fatal(err)
	}
	var done atomic.Bool
	var bad, einval atomic.Int64
	var wg sync.WaitGroup
	for range 4 {
		wg.Go(func() {
			for !done.Load() {
				b, err := os.ReadFile(filepath.Join(dst, "config.yaml"))
				switch {
				case runtime.GOOS == "darwin" && errors.Is(err, syscall.EINVAL):
					einval.Add(1)
				case err != nil || len(b) != len("version: 0\n"):
					bad.Add(1)
				}
			}
		})
	}
	for i := 1; i <= 30; i++ {
		if err := fsx.InstallDir(release(i%10), dst); err != nil {
			t.Error(err)
			break
		}
	}
	done.Store(true)
	wg.Wait()
	if bad.Load() > 0 {
		t.Fatalf("%d reads failed or saw a partial file", bad.Load())
	}
	t.Logf("%d transient EINVAL errors", einval.Load())
	b, _ := os.ReadFile(filepath.Join(dst, "config.yaml"))
	if string(b) != "version: 0\n" {
		t.Fatalf("after the last install config.yaml = %q", b)
	}
	if fi, err := os.Lstat(dst); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("dst should be a symlink: %v, %v", fi, err)
	}
	// dst, the version it points to, and the previous version.
	entries, _ := os.ReadDir(filepath.Dir(dst))
	if len(entries) != 3 {
		t.Fatalf("parent holds %d entries, want 3: %v", len(entries), entries)
	}
	if runtime.GOOS != "windows" {
		fi, err := os.Stat(filepath.Join(dst, "bin", "run.sh"))
		if err != nil || fi.Mode()&0o100 == 0 {
			t.Fatalf("run.sh lost its execute bit: %v, %v", fi, err)
		}
	}
}

func TestInstallDirRefusesARealDirectory(t *testing.T) {
	parent := t.TempDir()
	dst := filepath.Join(parent, "current")
	if err := os.Mkdir(dst, 0o755); err != nil {
		t.Fatal(err)
	}
	keep := filepath.Join(dst, "keep.txt")
	if err := os.WriteFile(keep, []byte("mine"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := fsx.InstallDir(release(1), dst); err == nil {
		t.Fatal("InstallDir replaced a real directory")
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("existing directory was touched: %v", err)
	}
	if entries, _ := os.ReadDir(parent); len(entries) != 1 {
		t.Fatalf("left debris next to dst: %v", entries)
	}
}
