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
	"os"
	"time"
)

// END head OMIT
// START main OMIT
func main() {
	err := run(context.Background(), os.Args[1:], os.Getenv, os.Stdout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "deployctl: %v\n", err) // report once, here
		os.Exit(1)
	}
}

// END main OMIT
// START globals OMIT
// globals are the flags every command accepts.
type globals struct {
	config string
}

// END globals OMIT
// START run OMIT
// run is the program. It returns an error and never exits, so tests can
// call it, and the caller decides what the user sees.
func run(ctx context.Context, args []string, getenv func(string) string,
	stdout io.Writer) error {

	var g globals
	fs := flag.NewFlagSet("deployctl", flag.ContinueOnError)
	fs.StringVar(&g.config, "config", "deployctl.json", "config `file`")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cmd, rest := fs.Arg(0), fs.Args()[min(1, fs.NArg()):]
	switch cmd {
	case "deploy":
		return deploy(ctx, g, rest, getenv, stdout)
	case "":
		return errors.New("no command given")
	}
	return fmt.Errorf("unknown command %q", cmd)
}

// END run OMIT
// START elapsed OMIT
// elapsed rounds a duration for people.
func elapsed(start time.Time) time.Duration {
	return time.Since(start).Round(10 * time.Millisecond)
}

// END elapsed OMIT
