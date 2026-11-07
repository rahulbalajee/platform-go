package cli

// START imports OMIT

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/pkg/clierr"
)

// END imports OMIT
// START main OMIT

// Main is the whole main function of a tool: it builds the command tree for
// the process's real streams, runs it with the command-line arguments, and
// exits with the code clierr assigns to the outcome. SIGINT and SIGTERM
// cancel the context passed to every command (a second signal kills).
func Main(name string, newRoot func(*IOStreams) *cobra.Command,
	opts ...Option,
) {
	var o options
	for _, opt := range opts {
		opt(&o)
	}
	ios := System()
	p := &clierr.Program{Name: name, Stderr: ios.ErrOut}
	p.Main(func(ctx context.Context) error {
		root := newRoot(ios)
		if o.plugins {
			if pl, rest, ok := findPlugin(name, root, os.Args[1:]); ok {
				return runPlugin(name, pl, rest)
			}
		}
		err := Execute(ctx, root, os.Args[1:])
		// Program reads JSON after this function returns, so a command
		// that chose -o json gets its error reported as JSON as well.
		p.JSON = ios.JSONErrors()
		return err
	})
}

// END main OMIT
// START execute OMIT

// Execute runs the command tree rooted at root with args and returns the
// error for clierr to report; it prints nothing itself. Errors cobra raises
// on its own (unknown commands, wrong argument counts, bad or missing
// flags) come back as usage errors, exit code 2, with a hint that names the
// right --help. Errors the commands return come back unchanged.
func Execute(ctx context.Context, root *cobra.Command, args []string) error {
	root.SetArgs(args)
	root.SilenceErrors = true // clierr reports, exactly once
	root.SilenceUsage = true  // a failed deploy is not a reason for a usage dump
	tagHooks(root)

	cmd, err := root.ExecuteContextC(ctx)
	if err == nil {
		return nil
	}
	if ce, ok := errors.AsType[commandError](err); ok {
		return ce.err
	}
	return UsageError(cmd, err)
}

// END execute OMIT
// START taghooks OMIT

// commandError marks an error that a command's own code returned, as
// opposed to one cobra raised while parsing. Cobra uses plain errors for
// both, and matching on their text would break on upgrade.
type commandError struct{ err error }

func (e commandError) Error() string { return e.err.Error() }

// Unwrap keeps the command's own error visible to errors.Is and As, so a
// *clierr.Error inside still decides the exit code.
func (e commandError) Unwrap() error { return e.err }

// tagHooks wraps every hook in the tree so that the errors they return are
// commandErrors. A flag tracking "a hook ran" would not do: cobra checks
// required flags after PersistentPreRunE and PreRunE, before RunE.
func tagHooks(c *cobra.Command) {
	tag := func(f func(*cobra.Command, []string) error) func(
		*cobra.Command, []string) error {
		if f == nil {
			return nil
		}
		return func(c *cobra.Command, args []string) error {
			if err := f(c, args); err != nil {
				return commandError{err}
			}
			return nil
		}
	}
	c.PersistentPreRunE = tag(c.PersistentPreRunE)
	c.PreRunE = tag(c.PreRunE)
	c.RunE = tag(c.RunE)
	c.PostRunE = tag(c.PostRunE)
	c.PersistentPostRunE = tag(c.PersistentPostRunE)
	for _, sub := range c.Commands() {
		tagHooks(sub)
	}
}

// END taghooks OMIT
// START usage OMIT

// UsageError reports that cmd was invoked wrongly. Commands return it for
// mistakes cobra cannot see, such as two flags that exclude each other.
func UsageError(cmd *cobra.Command, err error) error {
	hint := fmt.Sprintf("Run '%s --help' for usage.", cmd.CommandPath())
	if u, ok := errors.AsType[*unknownCommandError](err); ok && u.suggest != "" {
		hint = fmt.Sprintf("Did you mean '%s %s'? %s",
			cmd.CommandPath(), u.suggest, hint)
	}
	return &clierr.Error{
		Code:    clierr.ExitUsage,
		Message: err.Error(),
		Hint:    hint,
		Err:     err,
	}
}

// END usage OMIT
// START group OMIT

// Group makes cmd a command that only holds subcommands; use it for the
// root too. Run bare, it prints its help. With an unknown subcommand it
// fails with a usage error that suggests the closest match. Cobra's default
// for a group is to print help and exit 0, which hides a typo in a script:
// "plat servics list" would succeed.
func Group(cmd *cobra.Command) *cobra.Command {
	cmd.Args = func(c *cobra.Command, args []string) error {
		if len(args) == 0 {
			return nil
		}
		err := &unknownCommandError{name: args[0], parent: c.CommandPath()}
		// SuggestionsFor compares against this distance, which cobra
		// only defaults (to 2) on its own error path.
		if c.SuggestionsMinimumDistance <= 0 {
			c.SuggestionsMinimumDistance = 2
		}
		if s := c.SuggestionsFor(args[0]); len(s) > 0 {
			err.suggest = s[0]
		}
		return err
	}
	cmd.RunE = func(c *cobra.Command, _ []string) error { return c.Help() }
	return cmd
}

// unknownCommandError is the error Group returns for an unknown
// subcommand. Cobra's own version appends a "Did you mean this?" block to
// the message; this one keeps the suggestion separate, for the hint.
type unknownCommandError struct {
	name, parent, suggest string
}

func (e *unknownCommandError) Error() string {
	return fmt.Sprintf("unknown command %q for %q", e.name, e.parent)
}

// END group OMIT
// START exactargs OMIT

// ExactArgs is cobra.ExactArgs with an error that names the arguments, so
// "plat deploy api" fails with "missing VERSION" rather than "accepts 2
// arg(s), received 1".
func ExactArgs(names ...string) cobra.PositionalArgs {
	return func(_ *cobra.Command, args []string) error {
		switch {
		case len(args) < len(names):
			return fmt.Errorf("missing %s", names[len(args)])
		case len(args) > len(names):
			return fmt.Errorf("unexpected argument %q", args[len(names)])
		}
		return nil
	}
}

// END exactargs OMIT
