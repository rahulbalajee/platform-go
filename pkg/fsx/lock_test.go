// START locktests OMIT

package fsx_test

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/fsx"
)

// holdLock is the helper process: take the lock, report it, wait to die.
func holdLock(path string) {
	l, err := fsx.TryLock(path)
	if err != nil {
		fmt.Println("error:", err)
		os.Exit(1)
	}
	fmt.Println("locked")
	time.Sleep(time.Minute)
	_ = l.Unlock()
	os.Exit(0)
}

func TestTryLockIsExclusiveWithinOneProcess(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tool.lock")
	l, err := fsx.TryLock(path)
	if err != nil {
		t.Fatal(err)
	}
	// flock locks belong to the open file description, so a second open in
	// the same process conflicts. (fcntl/POSIX locks would not.)
	if _, err := fsx.TryLock(path); !errors.Is(err, fsx.ErrLocked) {
		t.Fatalf("second TryLock: err = %v, want ErrLocked", err)
	}
	if err := l.Unlock(); err != nil {
		t.Fatal(err)
	}
	l2, err := fsx.TryLock(path)
	if err != nil {
		t.Fatalf("TryLock after Unlock: %v", err)
	}
	_ = l2.Unlock()
}

// END locktests OMIT

// START crash OMIT

// TestLockReleasedWhenHolderIsKilled: a SIGKILLed holder cannot clean up,
// but the kernel closes its descriptors and the lock goes with them.
func TestLockReleasedWhenHolderIsKilled(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tool.lock")
	holder := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^$")
	holder.Env = append(os.Environ(), "FSX_HOLD_LOCK="+path)
	out, err := holder.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := holder.Start(); err != nil {
		t.Fatal(err)
	}
	line, _ := bufio.NewReader(out).ReadString('\n')
	if strings.TrimSpace(line) != "locked" {
		t.Fatalf("helper said %q", line)
	}

	_, err = fsx.TryLock(path)
	lockErr, ok := errors.AsType[*fsx.LockedError](err)
	if !ok {
		t.Fatalf("TryLock while held: err = %v, want *LockedError", err)
	}
	wantPID := fmt.Sprintf("pid=%d ", holder.Process.Pid)
	if runtime.GOOS != "windows" && !strings.HasPrefix(lockErr.Holder, wantPID) {
		t.Errorf("Holder = %q, want prefix %q", lockErr.Holder, wantPID)
	}

	_ = holder.Process.Kill() // SIGKILL: no deferred Unlock runs
	_ = holder.Wait()
	l, err := fsx.TryLock(path)
	if err != nil {
		t.Fatalf("TryLock after holder was killed: %v", err)
	}
	_ = l.Unlock()
}

// END crash OMIT

// START acquiretests OMIT

func TestAcquireWaitsForRelease(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tool.lock")
	first, err := fsx.TryLock(path)
	if err != nil {
		t.Fatal(err)
	}
	time.AfterFunc(150*time.Millisecond, func() { _ = first.Unlock() })

	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	start := time.Now()
	second, err := fsx.Acquire(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = second.Unlock() }()
	if waited := time.Since(start); waited < 100*time.Millisecond {
		t.Fatalf("acquired after %v, before the holder released", waited)
	}
}

func TestAcquireGivesUpWithContext(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tool.lock")
	held, err := fsx.TryLock(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = held.Unlock() }()

	ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
	defer cancel()
	_, err = fsx.Acquire(ctx, path)
	if !errors.Is(err, fsx.ErrLocked) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want ErrLocked and DeadlineExceeded", err)
	}
}

// END acquiretests OMIT
