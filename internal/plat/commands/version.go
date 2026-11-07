package commands

// START imports OMIT

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/buildinfo"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/output"
)

// END imports OMIT
// START version OMIT

type versionOptions struct {
	IO     *cli.IOStreams
	Info   buildinfo.Info
	Output string
}

func newVersionCmd(f *factory.Factory,
	runF func(context.Context, *versionOptions) error,
) *cobra.Command {
	opts := &versionOptions{IO: f.IO}
	cmd := &cobra.Command{
		Use:   "version",
		Short: "Print the version of plat",
		Args:  cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			opts.Info = buildinfo.Get()
			opts.Info.Name = "plat"
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runVersion(c.Context(), opts)
		},
	}
	output.AddFlag(cmd, &opts.Output)
	return cmd
}

// runVersion prints one line people can paste into a bug report, or the
// build information as data for an update check or an inventory script.
func runVersion(_ context.Context, opts *versionOptions) error {
	p, err := output.New(opts.IO, opts.Output)
	if err != nil {
		return usage(err)
	}
	if p.Machine() {
		return p.Data(opts.Info)
	}
	i := opts.Info
	rev := i.Revision
	if len(rev) > 12 {
		rev = rev[:12]
	}
	if i.Modified {
		rev += "+dirty"
	}
	_, err = fmt.Fprintf(opts.IO.Out, "%s %s (%s) %s %s\n",
		i.Name, i.Version, rev, i.GoVersion, i.Platform)
	return err
}

// END version OMIT
