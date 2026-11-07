package commands

// START imports OMIT

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/output"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START options OMIT

type deployOptions struct {
	IO     *cli.IOStreams
	Client func() (*platformapi.Client, error)

	Service, Version, Env, Reason string
	Wait                          bool
	Timeout                       time.Duration
	Output                        string
}

// END options OMIT
// START cmd OMIT

func newDeployCmd(f *factory.Factory,
	runF func(context.Context, *deployOptions) error,
) *cobra.Command {
	opts := &deployOptions{IO: f.IO, Client: f.Client}
	var noWait bool
	cmd := &cobra.Command{
		Use:   "deploy SERVICE VERSION --env ENV",
		Short: "Roll out a version of a service to an environment",
		Long: `Roll out VERSION of SERVICE to the environment given by --env, and wait
until the rollout finishes. The deployment ID is printed to stdout, so
scripts can capture it; progress goes to stderr.

Interrupting the wait (Ctrl-C, or --timeout) does not stop the rollout,
which continues on the platform. Stop it with 'plat deployments cancel'.`,
		Example: `  plat deploy checkout v1.5.0 --env staging
  id=$(plat deploy checkout v1.5.0 --env prod --reason "INC-412 fix" --no-wait)
  plat deploy checkout v1.5.0 -e staging -o jsonpath='{.state}'`,
		Args:              cli.ExactArgs("SERVICE", "VERSION"),
		ValidArgsFunction: completeServices(f),
		RunE: func(c *cobra.Command, args []string) error {
			opts.Service, opts.Version = args[0], args[1]
			opts.Wait = !noWait
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runDeploy(c.Context(), opts)
		},
	}
	fl := cmd.Flags()
	fl.StringVarP(&opts.Env, "env", "e", "", "target `ENVIRONMENT` (required)")
	fl.StringVar(&opts.Reason, "reason", "", "why, for the audit log")
	fl.BoolVar(&noWait, "no-wait", false, "print the deployment ID and return")
	fl.DurationVar(&opts.Timeout, "timeout", 10*time.Minute,
		"stop waiting after this long")
	output.AddFlag(cmd, &opts.Output)
	_ = cmd.MarkFlagRequired("env")
	_ = cmd.RegisterFlagCompletionFunc("env", completeEnvironments(f))
	return cmd
}

// END cmd OMIT
// START run OMIT

// runDeploy starts the rollout and, unless told not to, follows it until it
// finishes. The exit code tells a pipeline what happened: 0 rolled out,
// 1 the rollout failed, 75 still running when the wait timed out. Stdout
// gets the deployment ID, or with -o the deployment itself.
func runDeploy(ctx context.Context, opts *deployOptions) error {
	p, err := output.New(opts.IO, opts.Output)
	if err != nil {
		return usage(err)
	}
	client, err := opts.Client()
	if err != nil {
		return err
	}
	op, err := client.CreateDeployment(ctx, platformapi.CreateDeploymentRequest{
		Service:     opts.Service,
		Environment: opts.Env,
		Version:     opts.Version,
		Reason:      opts.Reason,
	})
	if err != nil {
		return explainCreate(err, opts)
	}
	d := op.Result
	fmt.Fprintf(opts.IO.ErrOut, "Deploying %s %s to %s as %s\n",
		opts.Service, opts.Version, opts.Env, d.ID)
	if opts.Wait {
		if d, err = follow(ctx, client, op, opts, p); err != nil {
			return err
		}
	}
	if p.Machine() {
		return p.Data(d)
	}
	_, err = fmt.Fprintln(opts.IO.Out, d.ID)
	return err
}

// END run OMIT
// START follow OMIT

// follow reports progress until the rollout is done and returns the final
// deployment. A stopped wait says so, and how to pick the rollout up again,
// because the person may well believe Ctrl-C stopped the deployment.
func follow(ctx context.Context, client *platformapi.Client,
	op *platformapi.Operation[platformapi.Deployment], opts *deployOptions,
	p *output.Printer,
) (*platformapi.Deployment, error) {
	ctx, cancel := context.WithTimeout(ctx, opts.Timeout)
	defer cancel()
	id, last := op.Result.ID, op.Result
	progress := output.NewProgress(opts.IO)
	for snap, err := range client.Poll(ctx, op) {
		if err != nil {
			progress.Done(fmt.Sprintf("stopped waiting at %d/%d replicas",
				last.UpdatedReplicas, last.Replicas))
			return nil, &clierr.Error{
				Message: fmt.Sprintf("stopped waiting for %s", id),
				Hint: fmt.Sprintf("The rollout continues. Check it with "+
					"'plat deployments get %s'.", id),
				Err: explain(err, "deployment "+id),
			}
		}
		if snap.Result != nil {
			last = snap.Result
		}
		progress.Update(last.UpdatedReplicas, last.Replicas, snap.Message)
		if snap.Error != nil {
			progress.Done(p.Paint(output.Red, "rollout failed"))
			return last, &clierr.Error{
				Code: clierr.ExitFailure,
				Message: fmt.Sprintf("deployment %s failed: %s",
					id, snap.Error.Message),
				Hint: fmt.Sprintf("See the rollout log: plat logs %s", id),
				Err:  snap.Error,
			}
		}
	}
	progress.Done(p.Paint(output.Green, fmt.Sprintf("rolled out: %d/%d replicas",
		last.UpdatedReplicas, last.Replicas)))
	return last, nil
}

// END follow OMIT
// START explaincreate OMIT

// explainCreate adds what only a create call can mean: a conflict is a
// rollout of the same service already under way in that environment.
func explainCreate(err error, opts *deployOptions) error {
	if errors.Is(err, platformapi.ErrConflict) {
		return &clierr.Error{
			Code: clierr.ExitFailure,
			Message: fmt.Sprintf("%s is already being deployed to %s",
				opts.Service, opts.Env),
			Hint: fmt.Sprintf("See it with 'plat deployments list "+
				"--service %s --env %s'.", opts.Service, opts.Env),
			Err: err,
		}
	}
	return explain(err, fmt.Sprintf("service %q or environment %q",
		opts.Service, opts.Env))
}

// END explaincreate OMIT
