package commands

// START imports OMIT

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/internal/plat/policy"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/output"
)

// END imports OMIT
// START group OMIT

func newPolicyCmd(f *factory.Factory) *cobra.Command {
	cmd := cli.Group(&cobra.Command{
		Use:     "policy",
		Aliases: []string{"policies"},
		Short:   "Show and run the pre-deploy checks",
		Long: `Before every deploy, plat runs the pre-deploy checks it finds in two
directories: policies/ in plat's configuration directory, for the checks a
platform team installs, and .plat/policies/ in the current directory, for a
repository's own. A check is a CEL policy file (*.yaml) or a WebAssembly
module (*.wasm). If any check refuses, nothing is deployed.`,
	})
	cmd.AddCommand(newPolicyListCmd(f), newPolicyCheckCmd(f))
	return cmd
}

// END group OMIT
// START list OMIT

func newPolicyListCmd(f *factory.Factory) *cobra.Command {
	var format string
	cmd := &cobra.Command{
		Use:   "list",
		Short: "List the pre-deploy checks and where they come from",
		Args:  cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			p, err := output.New(f.IO, format)
			if err != nil {
				return usage(err)
			}
			ch, err := loadChecks(c.Context(), f)
			if err != nil {
				return err
			}
			defer ch.close(c.Context())
			if p.Machine() {
				return p.Data(nonNil(ch.names()))
			}
			if ch.len() == 0 {
				dirs, _ := policyDirs(f)
				fmt.Fprintf(f.IO.ErrOut, "No pre-deploy checks in %s or %s\n",
					dirs[0], dirs[1])
				return nil
			}
			t := p.Table(output.Column{Name: "name"}, output.Column{Name: "kind"},
				output.Column{Name: "source"})
			for _, r := range ch.names() {
				t.Row(r.Name, r.Kind, r.Source)
			}
			return t.Flush()
		},
	}
	output.AddFlag(cmd, &format)
	return cmd
}

// END list OMIT
// START check OMIT

type policyCheckOptions struct {
	Request policy.Request
	Output  string
}

func newPolicyCheckCmd(f *factory.Factory) *cobra.Command {
	opts := &policyCheckOptions{}
	cmd := &cobra.Command{
		Use:   "check SERVICE VERSION --env ENV",
		Short: "Run the pre-deploy checks for a deployment, without deploying",
		Example: `  plat policy check checkout v1.5.0 -e prod --reason "INC-412 fix"
  plat policy check checkout v1.5.0 -e prod -o json`,
		Args:              cli.ExactArgs("SERVICE", "VERSION"),
		ValidArgsFunction: completeServices(f),
		RunE: func(c *cobra.Command, args []string) error {
			opts.Request.Service, opts.Request.Version = args[0], args[1]
			return runPolicyCheck(c.Context(), f, opts)
		},
	}
	cmd.Flags().StringVarP(&opts.Request.Environment, "env", "e", "",
		"target `ENVIRONMENT` (required)")
	cmd.Flags().StringVar(&opts.Request.Reason, "reason", "", "the deploy's reason")
	output.AddFlag(cmd, &opts.Output)
	_ = cmd.MarkFlagRequired("env")
	_ = cmd.RegisterFlagCompletionFunc("env", completeEnvironments(f))
	return cmd
}

// runPolicyCheck prints every check's verdict and exits 1 if any would
// refuse the deployment, so CI can run it on a pull request.
func runPolicyCheck(ctx context.Context, f *factory.Factory,
	opts *policyCheckOptions,
) error {
	p, err := output.New(f.IO, opts.Output)
	if err != nil {
		return usage(err)
	}
	ch, err := loadChecks(ctx, f)
	if err != nil {
		return err
	}
	defer ch.close(ctx)
	client, err := f.Client()
	if err != nil {
		return err
	}
	opts.Request.User = currentUser(ctx, f)
	in, err := checkInput(ctx, client, opts.Request, f)
	if err != nil {
		return err
	}
	results := ch.run(ctx, in)
	if p.Machine() {
		err = p.Data(nonNil(results))
	} else {
		err = printResults(p, results)
	}
	if err != nil {
		return err
	}
	if blocking := policy.Blocking(results); len(blocking) > 0 {
		return refused(blocking)
	}
	return nil
}

func printResults(p *output.Printer, results []policy.Result) error {
	t := p.Table(output.Column{Name: "check"}, output.Column{Name: "kind"},
		output.Column{Name: "result"}, output.Column{Name: "message"},
		output.Column{Name: "source", Wide: true})
	colour := map[policy.Status]output.Colour{policy.Pass: output.Green,
		policy.Fail: output.Red, policy.Error: output.Red, policy.Skip: output.Dim}
	for _, r := range results {
		t.Row(r.Name, r.Kind, p.Paint(colour[r.Status], string(r.Status)),
			r.Message, r.Source)
	}
	return t.Flush()
}

// END check OMIT
