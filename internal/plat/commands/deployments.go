package commands

// START imports OMIT

import (
	"context"
	"errors"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/output"
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
		newDeploymentsWatchCmd(f),
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
	Output string
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
		Example: `  plat deployments list --service checkout --state failed
  plat deployments list -o jsonpath='{[0].id}'   # the newest deployment's ID`,
		Args: cli.ExactArgs(),
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
	output.AddFlag(cmd, &opts.Output)
	_ = cmd.RegisterFlagCompletionFunc("service", completeServices(f))
	_ = cmd.RegisterFlagCompletionFunc("env", completeEnvironments(f))
	return cmd
}

// runDeploymentsList stops reading after Limit rows: breaking out of the
// range loop stops the iterator, so no further pages are fetched, and the
// page size asks for no more than that in the first place.
func runDeploymentsList(ctx context.Context, opts *deploymentsListOptions) error {
	p, err := output.New(opts.IO, opts.Output)
	if err != nil {
		return usage(err)
	}
	client, err := opts.Client()
	if err != nil {
		return err
	}
	list := []platformapi.Deployment{}
	for d, err := range client.ListDeployments(ctx, opts.Filter,
		platformapi.PageSize(min(opts.Limit, 100))) {
		if err != nil {
			return explain(err, "")
		}
		if list = append(list, d); len(list) == opts.Limit {
			break
		}
	}
	if p.Machine() {
		return p.Data(list)
	}
	t := p.Table(output.Column{Name: "id"}, output.Column{Name: "service"},
		output.Column{Name: "env"}, output.Column{Name: "version"},
		output.Column{Name: "state"}, output.Column{Name: "created"},
		output.Column{Name: "replicas", Wide: true},
		output.Column{Name: "reason", Wide: true})
	for _, d := range list {
		t.Row(d.ID, d.Service, d.Environment, d.Version, state(p, d.State),
			p.Time(d.CreatedAt),
			fmt.Sprintf("%d/%d", d.UpdatedReplicas, d.Replicas), d.Reason)
	}
	return t.Flush()
}

// END list OMIT
// START get OMIT

type deploymentOptions struct {
	IO     *cli.IOStreams
	Client func() (*platformapi.Client, error)
	ID     string
	Output string
}

func newDeploymentsGetCmd(f *factory.Factory,
	runF func(context.Context, *deploymentOptions) error,
) *cobra.Command {
	opts := &deploymentOptions{IO: f.IO, Client: f.Client}
	cmd := &cobra.Command{
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
	output.AddFlag(cmd, &opts.Output)
	return cmd
}

func runDeploymentsGet(ctx context.Context, opts *deploymentOptions) error {
	p, err := output.New(opts.IO, opts.Output)
	if err != nil {
		return usage(err)
	}
	client, err := opts.Client()
	if err != nil {
		return err
	}
	d, err := client.GetDeployment(ctx, opts.ID)
	if err != nil {
		return explain(err, fmt.Sprintf("deployment %q", opts.ID))
	}
	return printDeployment(p, d)
}

// printDeployment shows one deployment: the object itself for programs,
// labelled fields for people.
func printDeployment(p *output.Printer, d *platformapi.Deployment) error {
	if p.Machine() {
		return p.Data(d)
	}
	pairs := []string{"ID", d.ID, "Service", d.Service,
		"Environment", d.Environment, "Version", d.Version,
		"State", state(p, d.State),
		"Replicas", fmt.Sprintf("%d/%d updated", d.UpdatedReplicas, d.Replicas),
		"Created", p.Time(d.CreatedAt)}
	if d.Reason != "" {
		pairs = append(pairs, "Reason", d.Reason)
	}
	return fields(p.IO, pairs...)
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
