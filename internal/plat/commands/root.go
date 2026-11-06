// START head OMIT

// Package commands holds plat's cobra command tree. Each command is two
// pieces: a constructor that turns flags and arguments into an options
// struct, and a run function that does the work with those options. Tests
// call the run functions directly; cobra is only the parser.
package commands

// END head OMIT
// START imports OMIT

import (
	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
)

// END imports OMIT
// START root OMIT

// NewRoot returns plat's root command, with every subcommand attached.
func NewRoot(f *factory.Factory) *cobra.Command {
	root := cli.Group(&cobra.Command{
		Use:   "plat <command>",
		Short: "Work with the Acme developer platform",
		Long: `plat deploys services and inspects environments on the Acme
developer platform.

Data goes to stdout and everything else to stderr, so output can be piped.
Exit status: 0 success, 1 failure (a deploy failed), 2 usage error,
75 temporary failure (retry later), 77 not authorised, 130 interrupted.`,
		Version: f.Version,
	})
	root.PersistentFlags().StringVar(&f.Server, "server", "",
		"platform API URL (default $PLAT_SERVER)")

	root.AddCommand(
		newVersionCmd(f, nil),
		newServicesCmd(f),
		newEnvsCmd(f),
		newDeployCmd(f, nil),
		newDeploymentsCmd(f),
		newLogsCmd(f, nil),
		newDocsCmd(),
	)
	root.SetIn(f.IO.In)
	root.SetOut(f.IO.Out)
	root.SetErr(f.IO.ErrOut)
	return root
}

// END root OMIT
