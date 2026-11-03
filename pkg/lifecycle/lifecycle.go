// START head OMIT

// Package lifecycle wires process signals into context cancellation with
// the two-stage shutdown users expect from production CLIs and daemons:
// the first Ctrl-C asks politely (cancel, drain, report), the second one
// exits immediately.
package lifecycle

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

// ExitInterrupted is the conventional exit status for a process stopped by
// SIGINT (128 + signal number 2).
const ExitInterrupted = 130

// SignalError is the cancellation cause recorded when a signal arrives.
type SignalError struct{ Signal os.Signal }

func (e *SignalError) Error() string { return "received signal " + e.Signal.String() }

// END head OMIT

// START notify OMIT

// Options tune NotifyContext. The zero value is right for real programs;
// tests replace Exit and Stderr.
type Options struct {
	Signals []os.Signal    // default: SIGINT, SIGTERM
	Exit    func(code int) // default: os.Exit
	Stderr  io.Writer      // default: os.Stderr
}

// NotifyContext returns a context that is cancelled, with a *SignalError
// cause, on the first signal. A second signal calls Exit(130) immediately,
// so a hung shutdown can always be escaped. Call stop to release resources
// and restore default signal handling.
func NotifyContext(parent context.Context, opts Options) (context.Context, func()) {
	if len(opts.Signals) == 0 {
		opts.Signals = []os.Signal{os.Interrupt, syscall.SIGTERM}
	}
	if opts.Exit == nil {
		opts.Exit = os.Exit
	}
	if opts.Stderr == nil {
		opts.Stderr = os.Stderr
	}

	ctx, cancel := context.WithCancelCause(parent)
	sigs := make(chan os.Signal, 2) // buffered: signal.Notify never blocks
	signal.Notify(sigs, opts.Signals...)
	quit := make(chan struct{})
	var wg sync.WaitGroup

	wg.Go(func() { // Go 1.25: WaitGroup.Go does Add(1) + defer Done()
		select {
		case s := <-sigs:
			fmt.Fprintf(opts.Stderr,
				"\n%s: shutting down (press Ctrl-C again to force)\n", s)
			cancel(&SignalError{Signal: s})
		case <-quit:
			return
		}
		select {
		case s := <-sigs:
			fmt.Fprintf(opts.Stderr, "%s: forced exit\n", s)
			opts.Exit(ExitInterrupted)
		case <-quit:
		}
	})

	var once sync.Once
	return ctx, func() {
		once.Do(func() {
			signal.Stop(sigs)
			close(quit)
			wg.Wait()
			cancel(context.Canceled)
		})
	}
}

// END notify OMIT
