package commands

// START imports OMIT

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/buildinfo"
	"github.com/rahulbalajee/platform-go/pkg/cli"
)

// END imports OMIT
// START version OMIT

type versionOptions struct {
	IO   *cli.IOStreams
	Info buildinfo.Info
}

func newVersionCmd(f *factory.Factory,
	runF func(context.Context, *versionOptions) error,
) *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the version of plat",
		Args:  cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			opts := &versionOptions{IO: f.IO, Info: buildinfo.Get()}
			opts.Info.Name = "plat"
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runVersion(c.Context(), opts)
		},
	}
}

// runVersion prints one line people can paste into a bug report.
func runVersion(_ context.Context, opts *versionOptions) error {
	i := opts.Info
	rev := i.Revision
	if len(rev) > 12 {
		rev = rev[:12]
	}
	if i.Modified {
		rev += "+dirty"
	}
	_, err := fmt.Fprintf(opts.IO.Out, "%s %s (%s) %s %s\n",
		i.Name, i.Version, rev, i.GoVersion, i.Platform)
	return err
}

// END version OMIT
