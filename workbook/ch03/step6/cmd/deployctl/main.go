// START head OMIT
// Command deployctl rolls a service version out to a set of targets through
// a deployment API. It exists to show every way a platform CLI can fail,
// and how to report each one. Run "deployctl -h" for commands and flags.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"time"

	"deployctl/pkg/clierr"
)

// END head OMIT
// START docs OMIT
const docs = "https://github.com/rahulbalajee/platform-go/tree/main/examples/ch03"

// END docs OMIT
// START main OMIT
func main() {
	p := &clierr.Program{Name: "deployctl"}
	p.Main(func(ctx context.Context) error {
		return run(ctx, p, os.Args[1:], os.Getenv, os.Stdout)
	})
}

// END main OMIT
// START globals OMIT
// globals are the flags every command accepts.
type globals struct {
	config  string
	output  string
	logFile string
}

// END globals OMIT
// START run OMIT
// run is the program. It returns an error and never exits, so tests can
// drive it, and it tells p how to report once it knows the output format.
func run(ctx context.Context, p *clierr.Program, args []string,
	getenv func(string) string, stdout io.Writer) error {

	var g globals
	fs := flag.NewFlagSet("deployctl", flag.ContinueOnError)
	fs.StringVar(&g.config, "config", "deployctl.json", "config `file`")
	fs.StringVar(&g.output, "o", "text", "output format: text or json")
	fs.StringVar(&g.logFile, "log", "", "append a JSON debug log to `file`")
	if err := parse(fs, args, stdout, usage); err != nil {
		return err
	}
	switch g.output {
	case "text":
	case "json":
		p.JSON = true
	default:
		return usageError(fmt.Errorf("unknown output format %q", g.output), "")
	}
	logger, closeLog, err := openLog(g.logFile)
	if err != nil {
		return err
	}
	p.Logger = logger
	p.Cleanup(closeLog) // not defer: Run logs the failure after we return

	cmd, rest := fs.Arg(0), fs.Args()[min(1, fs.NArg()):]
	switch cmd {
	case "init":
		return initConfig(g.config, stdout)
	case "deploy":
		return deploy(ctx, g, rest, getenv, logger, stdout)
	case "":
		return usageError(errors.New("no command given"), "")
	}
	return usageError(fmt.Errorf("unknown command %q", cmd), "")
}

// END run OMIT
// START usage OMIT
const usage = `usage: deployctl [-config FILE] [-o text|json] [-log FILE] COMMAND

commands:
  init             write a starter deployctl.json
  deploy VERSION   roll VERSION out to every target
`

// END usage OMIT
// START parse OMIT
// parse parses flags without letting the flag package print anything:
// on a bad flag it would print the error and the whole usage text, and
// then the report would show the same error again. Help goes to stdout,
// because the user asked for it.
func parse(fs *flag.FlagSet, args []string, stdout io.Writer,
	usage string) error {

	fs.SetOutput(io.Discard)
	err := fs.Parse(args)
	if errors.Is(err, flag.ErrHelp) {
		fmt.Fprint(stdout, usage+"\nflags:\n")
		fs.SetOutput(stdout)
		fs.PrintDefaults()
		return err // CodeOf(flag.ErrHelp) is ExitOK and prints nothing
	}
	if err != nil {
		return usageError(err, fs.Name())
	}
	return nil
}

// usageError is a mistake in the command line: exit 2 and point at -h.
func usageError(err error, cmd string) error {
	if cmd == "" {
		cmd = "deployctl"
	} else if cmd != "deployctl" {
		cmd = "deployctl " + cmd
	}
	return &clierr.Error{
		Code:    clierr.ExitUsage,
		Message: err.Error(),
		Hint:    fmt.Sprintf("run %q for usage", cmd+" -h"),
		Err:     err,
	}
}

// END parse OMIT
// START openlog OMIT
// openLog returns the operator log: JSON lines appended to path, or a
// logger that discards everything when path is empty.
func openLog(path string) (*slog.Logger, func(), error) {
	if path == "" {
		return slog.New(slog.DiscardHandler), func() {}, nil
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, nil, &clierr.Error{
			Message: fmt.Sprintf("cannot open log file %s", path),
			Hint:    "pick a writable path for -log, or leave it out",
			Err:     err,
		}
	}
	h := slog.NewJSONHandler(f, &slog.HandlerOptions{Level: slog.LevelDebug})
	return slog.New(h), func() { _ = f.Close() }, nil
}

// END openlog OMIT
// START splitlist OMIT
// splitList parses a comma-separated flag value.
func splitList(s string) []string {
	var out []string
	for f := range strings.SplitSeq(s, ",") {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}

// END splitlist OMIT
// START elapsed OMIT
// elapsed rounds a duration for people.
func elapsed(start time.Time) time.Duration {
	return time.Since(start).Round(10 * time.Millisecond)
}

// END elapsed OMIT
