package commands

// START imports OMIT

import (
	"context"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/output"
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
	Output string
}

func newEnvsListCmd(f *factory.Factory,
	runF func(context.Context, *envsListOptions) error,
) *cobra.Command {
	opts := &envsListOptions{IO: f.IO, Client: f.Client}
	cmd := &cobra.Command{
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
	output.AddFlag(cmd, &opts.Output)
	return cmd
}

func runEnvsList(ctx context.Context, opts *envsListOptions) error {
	p, err := output.New(opts.IO, opts.Output)
	if err != nil {
		return usage(err)
	}
	client, err := opts.Client()
	if err != nil {
		return err
	}
	list, err := platformapi.Collect(client.ListEnvironments(ctx))
	if err != nil {
		return explain(err, "")
	}
	if p.Machine() {
		return p.Data(nonNil(list))
	}
	t := p.Table(output.Column{Name: "name"}, output.Column{Name: "region"},
		output.Column{Name: "protected"},
		output.Column{Name: "created", Wide: true})
	for _, e := range list {
		t.Row(e.Name, e.Region, strconv.FormatBool(e.Protected),
			p.Time(e.CreatedAt))
	}
	return t.Flush()
}

// END envs OMIT
