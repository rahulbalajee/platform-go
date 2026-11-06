package commands

// START imports OMIT

import (
	"context"
	"fmt"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START envs OMIT

func newEnvsCmd(f *factory.Factory) *cobra.Command {
	cmd := cli.Group(&cobra.Command{
		Use:     "envs",
		Aliases: []string{"env", "environments"},
		Short:   "List deployment environments",
	})
	cmd.AddCommand(newEnvsListCmd(f, nil))
	return cmd
}

type envsListOptions struct {
	IO     *cli.IOStreams
	Client func() (*platformapi.Client, error)
}

func newEnvsListCmd(f *factory.Factory,
	runF func(context.Context, *envsListOptions) error,
) *cobra.Command {
	opts := &envsListOptions{IO: f.IO, Client: f.Client}
	return &cobra.Command{
		Use:     "list",
		Aliases: []string{"ls"},
		Short:   "List environments",
		Args:    cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runEnvsList(c.Context(), opts)
		},
	}
}

func runEnvsList(ctx context.Context, opts *envsListOptions) error {
	client, err := opts.Client()
	if err != nil {
		return err
	}
	tw := tabwriter.NewWriter(opts.IO.Out, 0, 0, 3, ' ', 0)
	fmt.Fprintln(tw, "NAME\tREGION\tPROTECTED")
	for e, err := range client.ListEnvironments(ctx) {
		if err != nil {
			return explain(err, "")
		}
		fmt.Fprintf(tw, "%s\t%s\t%t\n", e.Name, e.Region, e.Protected)
	}
	return tw.Flush()
}

// END envs OMIT
