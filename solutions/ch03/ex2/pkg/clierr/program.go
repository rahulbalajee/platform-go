package clierr

// START imports OMIT
import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"runtime/debug"
	"slices"
	"strings"
)

// END imports OMIT
// START program OMIT
// Program describes a command to Run and Main. Only Name is required.
// The run function may set JSON and Logger after it has parsed its flags,
// because Run reads them only after the function returns.
type Program struct {
	Name     string       // prefixes every message and names crash files
	Version  string       // shown in crash reports; default from build info
	Stderr   io.Writer    // where people read errors; default os.Stderr
	JSON     bool         // report errors as one JSON object, not text
	Logger   *slog.Logger // operator log; default discards everything
	CrashDir string       // where crash reports go; default os.TempDir()
	BugURL   string       // where users should file crash reports
	Exit     func(int)    // used by Main; default os.Exit

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
// Run calls fn, recovers a panic on the calling goroutine, maps the outcome
// to an exit code, and reports a failure exactly once: a message for the
// person on Stderr, a record for operators on Logger, and for a panic a
// crash report on disk. It is Main without the process-wide side effects.
func (p *Program) Run(ctx context.Context,
	fn func(context.Context) error) (code Code) {

	defer p.runCleanups() // runs last, after the report below
	defer func() {
		if v := recover(); v != nil {
			code = p.report(ctx, &PanicError{Value: v, Stack: debug.Stack()})
		}
	}()
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
	if se, ok := errors.AsType[*SignalError](cause); ok &&
		code != ExitInternal {
		code = signalCode(se.Signal)
	}

	r := report{ExitCode: int(code), Message: UserMessage(err)}
	if e, ok := errors.AsType[*Error](err); ok {
		r.ID, r.Hint, r.Docs, r.Details = e.ID, e.Hint, e.Docs, details(e.Err)
	}
	if pe, ok := errors.AsType[*PanicError](err); ok {
		p.crash(&r, pe)
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
	// Run recovers panics on this goroutine only. For panics elsewhere and
	// fatal runtime errors, keep a copy of the runtime's own crash output.
	fatal := p.fatalOutput()
	ctx, stop := notifyContext(context.Background(), p.stderr())
	code := p.Run(ctx, fn)
	stop()
	if fatal != "" {
		_ = os.Remove(fatal) // we are exiting normally: nothing to keep
	}
	p.exit(int(code))
}

// END main OMIT
// START fatal OMIT
// fatalOutput points runtime/debug.SetCrashOutput at a fresh file in
// CrashDir and returns its name, or "" if that is not possible.
func (p *Program) fatalOutput() string {
	f, err := os.CreateTemp(p.crashDir(), p.Name+"-fatal-*.txt")
	if err != nil {
		return ""
	}
	defer f.Close() // SetCrashOutput keeps its own duplicate descriptor
	if err := debug.SetCrashOutput(f, debug.CrashOptions{}); err != nil {
		_ = os.Remove(f.Name())
		return ""
	}
	return f.Name()
}

// END fatal OMIT
// START reportstruct OMIT
// report is what a person (text) or a program (JSON) sees on stderr.
type report struct {
	ExitCode  int      `json:"exit_code"`
	ID        string   `json:"id,omitempty"`
	Message   string   `json:"message"`
	Details   []string `json:"details,omitempty"`
	Hint      string   `json:"hint,omitempty"`
	Docs      string   `json:"docs,omitempty"`
	CrashFile string   `json:"crash_file,omitempty"`
	stack     []byte   // printed only when no crash file could be written
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
	if r.CrashFile != "" {
		fmt.Fprintf(&b, "  this is a bug in %s; a crash report was saved to\n"+
			"  %s\n", p.Name, r.CrashFile)
	}
	if r.Hint != "" {
		fmt.Fprintf(&b, "  hint: %s\n", r.Hint)
	}
	if r.Docs != "" {
		fmt.Fprintf(&b, "  docs: %s\n", r.Docs)
	}
	b.Write(r.stack)
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
	if r.CrashFile != "" {
		attrs = append(attrs, slog.String("crash_file", r.CrashFile))
	}
	p.logger().LogAttrs(ctx, slog.LevelError, "command failed", attrs...)
}

// END log OMIT
// START crash OMIT
// crash saves pe to a new file in CrashDir and points the report at it.
// os.CreateTemp picks an unguessable name and opens it with O_EXCL and mode
// 0600, so another user can't pre-create the path as a symlink.
func (p *Program) crash(r *report, pe *PanicError) {
	r.Message = fmt.Sprintf("internal error: %v", pe.Value)
	if p.BugURL != "" {
		r.Hint = "attach that file to an issue at " + p.BugURL
	}
	f, err := os.CreateTemp(p.crashDir(), p.Name+"-crash-*.txt")
	if err == nil {
		_, err = f.Write(p.crashReport(pe))
		err = errors.Join(err, f.Close())
	}
	if err != nil { // never lose the stack: print it as a last resort
		r.Hint = ""
		r.stack = fmt.Appendf(nil, "  could not save a crash report: %v\n%s",
			err, pe.Stack)
		return
	}
	r.CrashFile = f.Name()
}

// END crash OMIT
// START crashreport OMIT
// crashReport is everything a maintainer needs to reproduce a panic: what
// was built from which commit, with which toolchain, and the stack.
func (p *Program) crashReport(pe *PanicError) []byte {
	var b strings.Builder
	field := func(k string, v any) { fmt.Fprintf(&b, "%-14s%v\n", k+":", v) }
	fmt.Fprintf(&b, "%s crash report\n\n", p.Name)
	if p.Version != "" {
		field("version", p.Version)
	}
	if bi, ok := debug.ReadBuildInfo(); ok {
		field("module", bi.Main.Path+"@"+bi.Main.Version)
		field("go", bi.GoVersion)
		for _, s := range bi.Settings {
			switch s.Key {
			case "GOOS", "GOARCH", "vcs.revision", "vcs.time", "vcs.modified":
				field(s.Key, s.Value)
			}
		}
	}
	field("panic", pe.Value)
	fmt.Fprintf(&b, "\n%s", pe.Stack)
	return []byte(b.String())
}

// END crashreport OMIT
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
// START crashdir OMIT
func (p *Program) crashDir() string {
	if p.CrashDir != "" {
		return p.CrashDir
	}
	return os.TempDir()
}

// END crashdir OMIT
// START exit OMIT
func (p *Program) exit(code int) {
	if p.Exit != nil {
		p.Exit(code)
		return
	}
	os.Exit(code)
}

// END exit OMIT
