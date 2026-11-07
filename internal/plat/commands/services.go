package commands

// START imports OMIT

import (
	"context"
	"fmt"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/output"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START group OMIT

func newServicesCmd(f *factory.Factory) *cobra.Command {
	cmd := cli.Group(&cobra.Command{
		Use:     "services",
		Aliases: []string{"service", "svc"},
		Short:   "List and inspect services",
	})
	cmd.AddCommand(newServicesListCmd(f, nil), newServicesGetCmd(f, nil))
	return cmd
}

// END group OMIT
// START list OMIT

type servicesListOptions struct {
	IO     *cli.IOStreams
	Client func() (*platformapi.Client, error)
	Team   string
	Output string
}

func newServicesListCmd(f *factory.Factory,
	runF func(context.Context, *servicesListOptions) error,
) *cobra.Command {
	opts := &servicesListOptions{IO: f.IO, Client: f.Client}
	cmd := &cobra.Command{
		Use:     "list",
		Aliases: []string{"ls"},
		Short:   "List services",
		Example: `  plat services list --team payments
  plat services list -o jsonpath='{[*].name}'`,
		Args: cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runServicesList(c.Context(), opts)
		},
	}
	cmd.Flags().StringVar(&opts.Team, "team", "", "only services owned by `TEAM`")
	output.AddFlag(cmd, &opts.Output)
	return cmd
}

// runServicesList prints one row per service, or the services themselves
// in a machine format. The format is checked before any request is made.
func runServicesList(ctx context.Context, opts *servicesListOptions) error {
	p, err := output.New(opts.IO, opts.Output)
	if err != nil {
		return usage(err)
	}
	client, err := opts.Client()
	if err != nil {
		return err
	}
	list, err := platformapi.Collect(client.ListServices(ctx,
		platformapi.ServiceFilter{Team: opts.Team}))
	if err != nil {
		return explain(err, "")
	}
	if p.Machine() {
		return p.Data(nonNil(list))
	}
	t := p.Table(output.Column{Name: "name"}, output.Column{Name: "team"},
		output.Column{Name: "replicas"}, output.Column{Name: "repo", Wide: true})
	for _, s := range list {
		t.Row(s.Name, s.Team, strconv.Itoa(s.Replicas), s.Repo)
	}
	return t.Flush()
}

// END list OMIT
// START get OMIT

type servicesGetOptions struct {
	IO     *cli.IOStreams
	Client func() (*platformapi.Client, error)
	Name   string
	Output string
}

func newServicesGetCmd(f *factory.Factory,
	runF func(context.Context, *servicesGetOptions) error,
) *cobra.Command {
	opts := &servicesGetOptions{IO: f.IO, Client: f.Client}
	cmd := &cobra.Command{
		Use:               "get SERVICE",
		Short:             "Show one service",
		Args:              cli.ExactArgs("SERVICE"),
		ValidArgsFunction: completeServices(f),
		RunE: func(c *cobra.Command, args []string) error {
			opts.Name = args[0]
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runServicesGet(c.Context(), opts)
		},
	}
	output.AddFlag(cmd, &opts.Output)
	return cmd
}

func runServicesGet(ctx context.Context, opts *servicesGetOptions) error {
	p, err := output.New(opts.IO, opts.Output)
	if err != nil {
		return usage(err)
	}
	client, err := opts.Client()
	if err != nil {
		return err
	}
	s, err := client.GetService(ctx, opts.Name)
	if err != nil {
		return explain(err, fmt.Sprintf("service %q", opts.Name))
	}
	if p.Machine() {
		return p.Data(s)
	}
	return fields(opts.IO, "Name", s.Name, "Team", s.Team, "Repo", s.Repo,
		"Replicas", strconv.Itoa(s.Replicas))
}

// END get OMIT
