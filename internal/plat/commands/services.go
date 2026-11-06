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
}

func newServicesListCmd(f *factory.Factory,
	runF func(context.Context, *servicesListOptions) error,
) *cobra.Command {
	opts := &servicesListOptions{IO: f.IO, Client: f.Client}
	cmd := &cobra.Command{
		Use:     "list",
		Aliases: []string{"ls"},
		Short:   "List services",
		Example: "  plat services list --team payments",
		Args:    cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runServicesList(c.Context(), opts)
		},
	}
	cmd.Flags().StringVar(&opts.Team, "team", "", "only services owned by `TEAM`")
	return cmd
}

// runServicesList prints one row per service. The table is written as the
// pages arrive, so a long list starts printing at once.
func runServicesList(ctx context.Context, opts *servicesListOptions) error {
	client, err := opts.Client()
	if err != nil {
		return err
	}
	tw := tabwriter.NewWriter(opts.IO.Out, 0, 0, 3, ' ', 0)
	fmt.Fprintln(tw, "NAME\tTEAM\tREPLICAS\tREPO")
	f := platformapi.ServiceFilter{Team: opts.Team}
	for s, err := range client.ListServices(ctx, f) {
		if err != nil {
			return explain(err, "")
		}
		fmt.Fprintf(tw, "%s\t%s\t%d\t%s\n", s.Name, s.Team, s.Replicas, s.Repo)
	}
	return tw.Flush()
}

// END list OMIT
// START get OMIT

type servicesGetOptions struct {
	IO     *cli.IOStreams
	Client func() (*platformapi.Client, error)
	Name   string
}

func newServicesGetCmd(f *factory.Factory,
	runF func(context.Context, *servicesGetOptions) error,
) *cobra.Command {
	opts := &servicesGetOptions{IO: f.IO, Client: f.Client}
	return &cobra.Command{
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
}

func runServicesGet(ctx context.Context, opts *servicesGetOptions) error {
	client, err := opts.Client()
	if err != nil {
		return err
	}
	s, err := client.GetService(ctx, opts.Name)
	if err != nil {
		return explain(err, fmt.Sprintf("service %q", opts.Name))
	}
	tw := tabwriter.NewWriter(opts.IO.Out, 0, 0, 2, ' ', 0)
	fmt.Fprintf(tw, "Name:\t%s\nTeam:\t%s\nRepo:\t%s\nReplicas:\t%d\n",
		s.Name, s.Team, s.Repo, s.Replicas)
	return tw.Flush()
}

// END get OMIT
