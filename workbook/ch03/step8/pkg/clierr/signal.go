package clierr

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
)

// START signalerror OMIT

// SignalError is the cause Main gives its context when a signal arrives,
// so the report and the exit code can say which signal stopped the run.
type SignalError struct{ Signal os.Signal }

func (e *SignalError) Error() string { return "received signal " + e.Signal.String() }

// signalCode returns 128 + the signal number, the status a shell reports
// for a process killed by that signal.
func signalCode(sig os.Signal) Code {
	if s, ok := sig.(syscall.Signal); ok && s > 0 && s < 32 {
		return Code(128 + int(s))
	}
	return ExitInterrupted
}

// END signalerror OMIT
// START notify OMIT

// notifyContext returns a context that the first SIGINT or SIGTERM cancels
// with a *SignalError cause. It then stops catching signals, so the next one
// gets the handling the process started with: from a terminal, that kills
// it at once, and a stuck shutdown can always be escaped. stop releases the
// handler and waits for its goroutine.
func notifyContext(parent context.Context,
	stderr io.Writer) (ctx context.Context, stop func()) {

	ctx, cancel := context.WithCancelCause(parent)
	sigs := make(chan os.Signal, 1) // Notify never blocks: it drops signals
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)
	done := make(chan struct{})
	go func() {
		defer close(done)
		select {
		case s := <-sigs:
			signal.Stop(sigs) // the next signal gets the default: exit
			fmt.Fprintf(stderr,
				"\n%s: stopping (press Ctrl-C again to force)\n", s)
			cancel(&SignalError{Signal: s})
		case <-ctx.Done():
		}
	}()
	return ctx, func() {
		signal.Stop(sigs)
		cancel(nil)
		<-done
	}
}

// END notify OMIT
