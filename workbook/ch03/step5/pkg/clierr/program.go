// START imports OMIT
package clierr

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// END imports OMIT
// START program OMIT
// Program describes a command to Run and Main. Only Name is required.
type Program struct {
	Name   string    // prefixes every message and names crash files
	Stderr io.Writer // where people read errors; default os.Stderr
	Exit   func(int) // used by Main; default os.Exit
}

// END program OMIT
// START run OMIT
// Run calls fn, maps its error to an exit code, and reports a failure
// exactly once. It is the testable half of Main: it never exits.
func (p *Program) Run(ctx context.Context, fn func(context.Context) error) Code {
	return p.report(ctx, fn(ctx))
}

// END run OMIT
// START report OMIT
func (p *Program) report(ctx context.Context, err error) Code {
	code := CodeOf(err)
	if code == ExitOK {
		return code
	}
	// Stopped by a signal: that decides the code, whatever error the
	// cancelled work returned (usually a bare "context canceled").
	cause := context.Cause(ctx)
	if se, ok := errors.AsType[*SignalError](cause); ok {
		code = signalCode(se.Signal)
	}

	r := report{ExitCode: int(code), Message: UserMessage(err)}
	if e, ok := errors.AsType[*Error](err); ok {
		r.ID, r.Hint, r.Docs, r.Details = e.ID, e.Hint, e.Docs, details(e.Err)
	}
	p.print(r)
	return code
}

// END report OMIT
// START main OMIT
// Main is the whole of a command's main function. It cancels the context
// on SIGINT or SIGTERM (a second signal kills the process), calls Run, and
// exits with the resulting code. It does not return.
func (p *Program) Main(fn func(context.Context) error) {
	ctx, stop := notifyContext(context.Background(), p.stderr())
	code := p.Run(ctx, fn)
	stop()
	p.exit(int(code))
}

// END main OMIT
// START reportstruct OMIT
// report is what a person (text) or a program (JSON) sees on stderr.
type report struct {
	ExitCode int
	ID       string
	Message  string
	Details  []string
	Hint     string
	Docs     string
}

// END reportstruct OMIT
// START print OMIT
// print writes the report for people, in one Write call so it can't
// interleave with other output.
func (p *Program) print(r report) {
	w := p.stderr()
	var b strings.Builder
	fmt.Fprintf(&b, "%s: %s", p.Name, indent(r.Message))
	if r.ID != "" {
		fmt.Fprintf(&b, " [%s]", r.ID)
	}
	b.WriteByte('\n')
	for _, d := range r.Details {
		fmt.Fprintf(&b, "  - %s\n", indent(d))
	}
	if r.Hint != "" {
		fmt.Fprintf(&b, "  hint: %s\n", r.Hint)
	}
	if r.Docs != "" {
		fmt.Fprintf(&b, "  docs: %s\n", r.Docs)
	}
	_, _ = io.WriteString(w, b.String())
}

// indent keeps continuation lines of multi-line messages under the first.
func indent(s string) string { return strings.ReplaceAll(s, "\n", "\n    ") }

// END print OMIT
// START stderr OMIT
func (p *Program) stderr() io.Writer {
	if p.Stderr != nil {
		return p.Stderr
	}
	return os.Stderr
}

// END stderr OMIT
// START exit OMIT
func (p *Program) exit(code int) {
	if p.Exit != nil {
		p.Exit(code)
		return
	}
	os.Exit(code)
}

// END exit OMIT
