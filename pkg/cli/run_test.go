package cli_test

// START imports OMIT

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
)

// END imports OMIT
// START tree OMIT

// newTree is a small command tree shaped like plat's: a group with a
// leaf that takes named arguments and a required flag.
func newTree(ios *cli.IOStreams, run func(env string) error) *cobra.Command {
	root := cli.Group(&cobra.Command{Use: "plat"})
	var env string
	deploy := &cobra.Command{
		Use:  "deploy SERVICE VERSION",
		Args: cli.ExactArgs("SERVICE", "VERSION"),
		RunE: func(_ *cobra.Command, _ []string) error { return run(env) },
	}
	deploy.Flags().StringVar(&env, "env", "", "target environment")
	_ = deploy.MarkFlagRequired("env")
	services := cli.Group(&cobra.Command{Use: "services"})
	services.AddCommand(&cobra.Command{
		Use:  "list",
		RunE: func(*cobra.Command, []string) error { return nil },
	})
	root.AddCommand(deploy, services)
	root.SetOut(ios.Out)
	root.SetErr(ios.ErrOut)
	return root
}

// END tree OMIT
// START usage OMIT

func TestUsageErrors(t *testing.T) {
	ok := func(string) error { return nil }
	for _, tc := range []struct {
		name, args, msg, hint string
	}{
		{"unknown command", "deplyo", `unknown command "deplyo" for "plat"`,
			"Did you mean 'plat deploy'? Run 'plat --help' for usage."},
		{"unknown subcommand", "services lsit",
			`unknown command "lsit" for "plat services"`,
			"Did you mean 'plat services list'? " +
				"Run 'plat services --help' for usage."},
		{"no suggestion", "frobnicate", `unknown command "frobnicate" for "plat"`,
			"Run 'plat --help' for usage."},
		{"missing argument", "deploy api --env prod", "missing VERSION",
			"Run 'plat deploy --help' for usage."},
		{"extra argument", "deploy api v1 v2 --env prod",
			`unexpected argument "v2"`, "Run 'plat deploy --help' for usage."},
		{"unknown flag", "deploy api v1 --envv prod", "unknown flag: --envv",
			"Run 'plat deploy --help' for usage."},
		// cobra checks required flags after the PreRun hooks: this case is
		// why Execute tags hook errors instead of noting that a hook ran.
		{"missing required flag", "deploy api v1",
			`required flag(s) "env" not set`,
			"Run 'plat deploy --help' for usage."},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ios, _, _, _ := cli.Test()
			err := cli.Execute(context.Background(), newTree(ios, ok),
				strings.Fields(tc.args))
			if got := clierr.CodeOf(err); got != clierr.ExitUsage {
				t.Fatalf("code = %v (%v), want usage", got, err)
			}
			e, _ := errors.AsType[*clierr.Error](err)
			if e.Message != tc.msg || e.Hint != tc.hint {
				t.Errorf("message, hint = %q, %q\nwant            %q, %q",
					e.Message, e.Hint, tc.msg, tc.hint)
			}
		})
	}
}

// END usage OMIT
// START commanderr OMIT

func TestCommandErrorsKeepTheirCode(t *testing.T) {
	ios, _, _, _ := cli.Test()
	denied := &clierr.Error{Code: clierr.ExitNoPerm, Message: "not logged in"}
	err := cli.Execute(context.Background(),
		newTree(ios, func(string) error { return denied }),
		[]string{"deploy", "api", "v1", "--env", "prod"})
	if !errors.Is(err, denied) || clierr.CodeOf(err) != clierr.ExitNoPerm {
		t.Fatalf("err = %v (code %v), want the command's own error",
			err, clierr.CodeOf(err))
	}
}

func TestPreRunErrorIsNotUsage(t *testing.T) {
	ios, _, _, _ := cli.Test()
	root := newTree(ios, func(string) error { return nil })
	broken := errors.New("config: bad YAML on line 3")
	root.PersistentPreRunE = func(*cobra.Command, []string) error { return broken }
	err := cli.Execute(context.Background(), root,
		[]string{"deploy", "api", "v1", "--env", "prod"})
	if !errors.Is(err, broken) || clierr.CodeOf(err) != clierr.ExitFailure {
		t.Fatalf("err = %v (code %v), want the hook's error, exit 1",
			err, clierr.CodeOf(err))
	}
}

// END commanderr OMIT
// START group OMIT

func TestGroupWithoutSubcommandPrintsHelp(t *testing.T) {
	ios, _, out, _ := cli.Test()
	err := cli.Execute(context.Background(),
		newTree(ios, func(string) error { return nil }), []string{"services"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "Available Commands:") {
		t.Errorf("stdout = %q, want the group's help", out)
	}
}

// END group OMIT
