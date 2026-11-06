// Command plat works with the Acme developer platform: it deploys services,
// lists environments and follows rollouts. Run `plat --help` for the
// commands, and see Part II of Platform Go for how it is built.
package main

// START main OMIT

import (
	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/commands"
	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/buildinfo"
	"github.com/rahulbalajee/platform-go/pkg/cli"
)

func main() {
	cli.Main("plat", func(ios *cli.IOStreams) *cobra.Command {
		return commands.NewRoot(factory.New(ios, buildinfo.Get().Version))
	})
}

// END main OMIT
