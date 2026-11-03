// START head OMIT

//go:build unix

package lifecycle_test

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"sweep/lifecycle"
)

// syncBuffer is a goroutine-safe strings.Builder for capturing stderr.
type syncBuffer struct {
	mu sync.Mutex
	b  strings.Builder
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// END head OMIT

// START test OMIT
func TestTwoStageShutdown(t *testing.T) {
	exited := make(chan int, 1)
	var stderr syncBuffer
	ctx, stop := lifecycle.NotifyContext(t.Context(), lifecycle.Options{
		Signals: []os.Signal{syscall.SIGUSR1}, // SIGINT would also hit `go test`
		Exit:    func(code int) { exited <- code },
		Stderr:  &stderr,
	})
	defer stop()

	// First signal: cancel with a SignalError cause, but don't exit.
	_ = syscall.Kill(syscall.Getpid(), syscall.SIGUSR1)
	select {
	case <-ctx.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("context not cancelled by first signal")
	}
	se, ok := errors.AsType[*lifecycle.SignalError](context.Cause(ctx))
	if !ok || se.Signal != syscall.SIGUSR1 {
		t.Fatalf("cause = %v, want SignalError(SIGUSR1)", context.Cause(ctx))
	}

	// Second signal: forced exit with status 130.
	_ = syscall.Kill(syscall.Getpid(), syscall.SIGUSR1)
	select {
	case code := <-exited:
		if code != lifecycle.ExitInterrupted {
			t.Errorf("exit code = %d, want %d", code, lifecycle.ExitInterrupted)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("second signal did not force exit")
	}
	if !strings.Contains(stderr.String(), "forced exit") {
		t.Errorf("stderr = %q, want a forced-exit message", stderr.String())
	}
}

func TestStopIsIdempotentAndCancels(t *testing.T) {
	ctx, stop := lifecycle.NotifyContext(t.Context(), lifecycle.Options{
		Signals: []os.Signal{syscall.SIGUSR2},
	})
	stop()
	stop()
	if ctx.Err() == nil {
		t.Fatal("stop must cancel the context")
	}
}

// END test OMIT
