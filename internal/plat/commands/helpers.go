package commands

// START imports OMIT

import (
	"fmt"
	"strings"

	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/output"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START helpers OMIT

// usage reports a bad flag value, such as an unknown -o format, as a usage
// error. Commands check -o before calling the API: a typo should cost
// nothing and say so at once.
func usage(err error) error {
	return &clierr.Error{Code: clierr.ExitUsage, Message: err.Error(),
		Hint: "Run the command with --help for the formats.", Err: err}
}

// nonNil turns a nil slice into an empty one, so an empty list prints as
// [] in JSON, not null: a script doing `jq length` must get 0.
func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// fields prints label/value pairs, one per line, labels aligned.
func fields(ios *cli.IOStreams, pairs ...string) error {
	width := 0
	for i := 0; i < len(pairs); i += 2 {
		width = max(width, len(pairs[i]))
	}
	var b strings.Builder
	for i := 0; i+1 < len(pairs); i += 2 {
		fmt.Fprintf(&b, "%-*s  %s\n", width+1, pairs[i]+":", pairs[i+1])
	}
	_, err := fmt.Fprint(ios.Out, b.String())
	return err
}

// state colours a deployment state for people: done well, failed, still
// going, or stopped.
func state(p *output.Printer, s platformapi.DeploymentState) string {
	switch s {
	case platformapi.StateSucceeded:
		return p.Paint(output.Green, string(s))
	case platformapi.StateFailed:
		return p.Paint(output.Red, string(s))
	case platformapi.StatePending, platformapi.StateInProgress:
		return p.Paint(output.Yellow, string(s))
	}
	return p.Paint(output.Dim, string(s))
}

// END helpers OMIT
