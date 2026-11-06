package commands

// START imports OMIT

import (
	"context"
	"errors"
	"fmt"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START group OMIT

func newDeploymentsCmd(f *factory.Factory) *cobra.Command {
	cmd := cli.Group(&cobra.Command{
		Use:     "deployments",
		Aliases: []string{"deployment", "deploys", "dep"},
		Short:   "List, inspect and cancel deployments",
	})
	cmd.AddCommand(
		newDeploymentsListCmd(f, nil),
		newDeploymentsGetCmd(f, nil),
		newDeploymentsCancelCmd(f, nil),
	)
	return cmd
}

// END group OMIT
// START list OMIT

type deploymentsListOptions struct {
	IO     *cli.IOStreams
	Client func() (*platformapi.Client, error)
	Filter platformapi.DeploymentFilter
	Limit  int
}

func newDeploymentsListCmd(f *factory.Factory,
	runF func(context.Context, *deploymentsListOptions) error,
) *cobra.Command {
	opts := &deploymentsListOptions{IO: f.IO, Client: f.Client}
	var state string
	cmd := &cobra.Command{
		Use:     "list",
		Aliases: []string{"ls"},
		Short:   "List deployments, newest first",
		Args:    cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			opts.Filter.State = platformapi.DeploymentState(state)
			if opts.Limit < 1 {
				return cli.UsageError(c,
					fmt.Errorf("--limit must be at least 1, not %d", opts.Limit))
			}
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runDeploymentsList(c.Context(), opts)
		},
	}
	fl := cmd.Flags()
	fl.StringVar(&opts.Filter.Service, "service", "", "only this `SERVICE`")
	fl.StringVarP(&opts.Filter.Environment, "env", "e", "",
		"only this `ENVIRONMENT`")
	fl.StringVar(&state, "state", "",
		"only this `STATE` (pending, in_progress, succeeded, failed, cancelled)")
	fl.IntVarP(&opts.Limit, "limit", "L", 20, "show at most `N` deployments")
	_ = cmd.RegisterFlagCompletionFunc("service", completeServices(f))
	_ = cmd.RegisterFlagCompletionFunc("env", completeEnvironments(f))
	return cmd
}

// runDeploymentsList stops reading after Limit rows: breaking out of the
// range loop stops the iterator, so no further pages are fetched.
func runDeploymentsList(ctx context.Context, opts *deploymentsListOptions) error {
	client, err := opts.Client()
	if err != nil {
		return err
	}
	tw := tabwriter.NewWriter(opts.IO.Out, 0, 0, 3, ' ', 0)
	fmt.Fprintln(tw, "ID\tSERVICE\tENV\tVERSION\tSTATE\tCREATED")
	n := 0
	for d, err := range client.ListDeployments(ctx, opts.Filter) {
		if err != nil {
			return explain(err, "")
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\n", d.ID, d.Service,
			d.Environment, d.Version, d.State, d.CreatedAt.Format(time.DateTime))
		if n++; n == opts.Limit {
			break
		}
	}
	return tw.Flush()
}

// END list OMIT
// START get OMIT

type deploymentOptions struct {
	IO     *cli.IOStreams
	Client func() (*platformapi.Client, error)
	ID     string
}

func newDeploymentsGetCmd(f *factory.Factory,
	runF func(context.Context, *deploymentOptions) error,
) *cobra.Command {
	opts := &deploymentOptions{IO: f.IO, Client: f.Client}
	return &cobra.Command{
		Use:   "get DEPLOYMENT",
		Short: "Show one deployment",
		Args:  cli.ExactArgs("DEPLOYMENT"),
		RunE: func(c *cobra.Command, args []string) error {
			opts.ID = args[0]
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runDeploymentsGet(c.Context(), opts)
		},
	}
}

func runDeploymentsGet(ctx context.Context, opts *deploymentOptions) error {
	client, err := opts.Client()
	if err != nil {
		return err
	}
	d, err := client.GetDeployment(ctx, opts.ID)
	if err != nil {
		return explain(err, fmt.Sprintf("deployment %q", opts.ID))
	}
	return printDeployment(opts.IO, d)
}

func printDeployment(ios *cli.IOStreams, d *platformapi.Deployment) error {
	tw := tabwriter.NewWriter(ios.Out, 0, 0, 2, ' ', 0)
	fmt.Fprintf(tw, "ID:\t%s\nService:\t%s\nEnvironment:\t%s\nVersion:\t%s\n",
		d.ID, d.Service, d.Environment, d.Version)
	fmt.Fprintf(tw, "State:\t%s\nReplicas:\t%d/%d updated\nCreated:\t%s\n",
		d.State, d.UpdatedReplicas, d.Replicas, d.CreatedAt.Format(time.RFC3339))
	if d.Reason != "" {
		fmt.Fprintf(tw, "Reason:\t%s\n", d.Reason)
	}
	return tw.Flush()
}

// END get OMIT
// START cancel OMIT

func newDeploymentsCancelCmd(f *factory.Factory,
	runF func(context.Context, *deploymentOptions) error,
) *cobra.Command {
	opts := &deploymentOptions{IO: f.IO, Client: f.Client}
	return &cobra.Command{
		Use:   "cancel DEPLOYMENT",
		Short: "Stop a rollout that is still in progress",
		Args:  cli.ExactArgs("DEPLOYMENT"),
		RunE: func(c *cobra.Command, args []string) error {
			opts.ID = args[0]
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runDeploymentsCancel(c.Context(), opts)
		},
	}
}

// runDeploymentsCancel is safe to repeat: cancelling a cancelled
// deployment succeeds, so a script can retry it after a timeout.
func runDeploymentsCancel(ctx context.Context, opts *deploymentOptions) error {
	client, err := opts.Client()
	if err != nil {
		return err
	}
	d, err := client.CancelDeployment(ctx, opts.ID)
	if errors.Is(err, platformapi.ErrConflict) {
		return &clierr.Error{Code: clierr.ExitFailure,
			Message: fmt.Sprintf("deployment %s has already finished", opts.ID),
			Err:     err}
	}
	if err != nil {
		return explain(err, fmt.Sprintf("deployment %q", opts.ID))
	}
	_, err = fmt.Fprintf(opts.IO.ErrOut, "Cancelled %s (%s %s to %s)\n",
		d.ID, d.Service, d.Version, d.Environment)
	return err
}

// END cancel OMIT
