// START imports OMIT
package clierr

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"slices"
	"strings"
)

// END imports OMIT
// START program OMIT
// Program describes a command to Run and Main. Only Name is required.
// The run function may set JSON and Logger after it has parsed its flags,
// because Run reads them only after the function returns.
type Program struct {
	Name   string       // prefixes every message and names crash files
	Stderr io.Writer    // where people read errors; default os.Stderr
	JSON   bool         // report errors as one JSON object, not text
	Logger *slog.Logger // operator log; default discards everything
	Exit   func(int)    // used by Main; default os.Exit

	cleanups []func()
}

// END program OMIT
// START cleanup OMIT
// Cleanup registers f to run after Run has reported the outcome, in
// last-registered-first order, like testing.T.Cleanup. Use it for anything
// the report itself needs, such as the file behind Logger: a defer inside
// the run function would close it before the failure is logged.
func (p *Program) Cleanup(f func()) { p.cleanups = append(p.cleanups, f) }

func (p *Program) runCleanups() {
	for _, f := range slices.Backward(p.cleanups) {
		f()
	}
	p.cleanups = nil
}

// END cleanup OMIT
// START run OMIT
// Run calls fn, maps its error to an exit code, and reports a failure
// exactly once. It is the testable half of Main: it never exits.
func (p *Program) Run(ctx context.Context, fn func(context.Context) error) Code {
	defer p.runCleanups() // runs after the report below
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
	p.log(ctx, err, cause, r)
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
	ExitCode int      `json:"exit_code"`
	ID       string   `json:"id,omitempty"`
	Message  string   `json:"message"`
	Details  []string `json:"details,omitempty"`
	Hint     string   `json:"hint,omitempty"`
	Docs     string   `json:"docs,omitempty"`
}

// END reportstruct OMIT
// START print OMIT
// print writes the report in one Write call, so it can't interleave with
// other output, as text for people or as one JSON object for programs.
func (p *Program) print(r report) {
	w := p.stderr()
	if p.JSON {
		_ = json.NewEncoder(w).Encode(struct {
			Error report `json:"error"`
		}{r})
		return
	}
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
// START log OMIT
// log records the failure for operators: the whole cause chain and its
// types, the code, the ID, and what cancelled the context, if anything.
func (p *Program) log(ctx context.Context, err, cause error, r report) {
	attrs := []slog.Attr{
		slog.Int("exit_code", r.ExitCode),
		slog.String("error", err.Error()),
		slog.Any("chain", Chain(err)),
	}
	if r.ID != "" {
		attrs = append(attrs, slog.String("error_id", r.ID))
	}
	if cause != nil {
		attrs = append(attrs, slog.String("ctx_cause", cause.Error()))
	}
	p.logger().LogAttrs(ctx, slog.LevelError, "command failed", attrs...)
}

// END log OMIT
// START stderr OMIT
func (p *Program) stderr() io.Writer {
	if p.Stderr != nil {
		return p.Stderr
	}
	return os.Stderr
}

// END stderr OMIT
// START logger OMIT
func (p *Program) logger() *slog.Logger {
	if p.Logger != nil {
		return p.Logger
	}
	return slog.New(slog.DiscardHandler)
}

// END logger OMIT
// START exit OMIT
func (p *Program) exit(code int) {
	if p.Exit != nil {
		p.Exit(code)
		return
	}
	os.Exit(code)
}

// END exit OMIT
