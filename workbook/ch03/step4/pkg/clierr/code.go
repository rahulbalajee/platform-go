// START head OMIT
// Package clierr is the error and exit-code layer shared by the
// command-line tools in this book. A command's run function returns an
// error; clierr maps it to an exit code from a documented contract and
// reports it exactly once, in terms the person at the terminal can act on.
package clierr

import (
	"errors"
	"flag"
	"io/fs"
	"strconv"
)

// END head OMIT
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
	ExitInterrupted Code = 130
)

// END codes OMIT
// START string OMIT
// String returns the short name used in logs and test failures.
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

// END string OMIT
// START codeof OMIT
// timeouter is the behaviour that net.Error, os.ErrDeadlineExceeded and
// context.DeadlineExceeded share. AsType needs the embedded error.
type timeouter interface {
	error
	Timeout() bool
}

// CodeOf maps an error to the exit code the contract assigns it. Order
// matters: an explicit Error.Code beats inference from the cause.
func CodeOf(err error) Code {
	if err == nil || errors.Is(err, flag.ErrHelp) {
		return ExitOK // -h is a successful request for help
	}
	if e, ok := errors.AsType[*Error](err); ok && e.Code != ExitOK {
		return e.Code
	}
	if t, ok := errors.AsType[timeouter](err); ok && t.Timeout() {
		return ExitTempFail
	}
	if errors.Is(err, fs.ErrPermission) {
		return ExitNoPerm
	}
	return ExitFailure
}

// END codeof OMIT
