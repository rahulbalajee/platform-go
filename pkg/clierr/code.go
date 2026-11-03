// Package clierr is the error and exit-code layer shared by the command-line
// tools in this book.
//
// It has four parts:
//
//   - an exit-code contract (the Exit* constants), which shells, CI systems
//     and wrapper scripts branch on;
//   - Error, which carries a message, a hint and a docs link for the person
//     at the terminal, separately from the cause chain meant for operators;
//   - Program.Run and Program.Main, which map an error to an exit code,
//     report it once (text or JSON on stderr), log the details with
//     log/slog, honour signal causes, and turn panics into crash reports;
//   - Safe and PanicError, which carry panics across goroutine boundaries
//     as values, and Secret, a string type that refuses to be printed.
package clierr

import (
	"context"
	"errors"
	"flag"
	"io/fs"
	"os"
	"strconv"
	"syscall"

	"github.com/rahulbalajee/platform-go/pkg/lifecycle"
)

// START codes OMIT
// Code is a process exit status. The values are a contract with shells, CI
// systems and wrapper scripts: renumbering one breaks somebody's pipeline.
type Code int

const (
	ExitOK       Code = 0  // success
	ExitFailure  Code = 1  // ran, and the answer is "no": checks or deploys failed
	ExitUsage    Code = 2  // bad flags, arguments or config: fix the command
	ExitInternal Code = 70 // a bug: a panic or an impossible state (EX_SOFTWARE)
	ExitTempFail Code = 75 // timed out or unavailable: retry later (EX_TEMPFAIL)
	ExitNoPerm   Code = 77 // authentication or permission denied (EX_NOPERM)

	// ExitInterrupted is 128 + SIGINT. Other signals map to 128 + their
	// number, so SIGTERM gives 143, as it would for a process it killed.
	ExitInterrupted Code = lifecycle.ExitInterrupted
)

// END codes OMIT

// String returns the short name used in logs and JSON reports.
func (c Code) String() string {
	switch c {
	case ExitOK:
		return "ok"
	case ExitFailure:
		return "failure"
	case ExitUsage:
		return "usage"
	case ExitInternal:
		return "internal"
	case ExitTempFail:
		return "tempfail"
	case ExitNoPerm:
		return "noperm"
	}
	if c > 128 && c < 160 {
		return "signal " + strconv.Itoa(int(c)-128)
	}
	return "code " + strconv.Itoa(int(c))
}

// START codeof OMIT
// timeouter is the behaviour net.Error, os.ErrDeadlineExceeded and
// context.DeadlineExceeded share. AsType needs the embedded error.
type timeouter interface {
	error
	Timeout() bool
}

// CodeOf maps an error to the exit code the contract assigns it. Order
// matters: a panic beats everything, a signal beats whatever the interrupted
// work returned, and an explicit Error.Code beats inference from the cause.
func CodeOf(err error) Code {
	if err == nil || errors.Is(err, flag.ErrHelp) {
		return ExitOK // -h is a successful request for help
	}
	if _, ok := errors.AsType[*PanicError](err); ok {
		return ExitInternal
	}
	if se, ok := errors.AsType[*lifecycle.SignalError](err); ok {
		return signalCode(se.Signal)
	}
	if e, ok := errors.AsType[*Error](err); ok && e.Code != ExitOK {
		return e.Code
	}
	if t, ok := errors.AsType[timeouter](err); ok && t.Timeout() {
		return ExitTempFail
	}
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return ExitTempFail
	case errors.Is(err, fs.ErrPermission):
		return ExitNoPerm
	}
	return ExitFailure
}

// END codeof OMIT

// signalCode returns 128 + the signal number, the status a shell reports
// for a process killed by that signal.
func signalCode(sig os.Signal) Code {
	if s, ok := sig.(syscall.Signal); ok && s > 0 && s < 32 {
		return Code(128 + int(s))
	}
	return ExitInterrupted
}
