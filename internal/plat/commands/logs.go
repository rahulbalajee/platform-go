package commands

// START imports OMIT

import (
	"context"
	"fmt"
	"io"

	"github.com/spf13/cobra"
	"github.com/spf13/cobra/doc"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START logs OMIT

type logsOptions struct {
	IO     *cli.IOStreams
	Client func() (*platformapi.Client, error)
	ID     string
}

func newLogsCmd(f *factory.Factory,
	runF func(context.Context, *logsOptions) error,
) *cobra.Command {
	opts := &logsOptions{IO: f.IO, Client: f.Client}
	return &cobra.Command{
		Use:     "logs DEPLOYMENT",
		Short:   "Print the rollout log of a deployment",
		Example: "  plat logs d-9 | grep -i error",
		Args:    cli.ExactArgs("DEPLOYMENT"),
		RunE: func(c *cobra.Command, args []string) error {
			opts.ID = args[0]
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runLogs(c.Context(), opts)
		},
	}
}

// runLogs copies the log straight through: constant memory for a log of
// any size, and each line appears as soon as the server sends it.
func runLogs(ctx context.Context, opts *logsOptions) error {
	client, err := opts.Client()
	if err != nil {
		return err
	}
	body, err := client.DeploymentLogs(ctx, opts.ID)
	if err != nil {
		return explain(err, fmt.Sprintf("deployment %q", opts.ID))
	}
	defer body.Close()
	if _, err := io.Copy(opts.IO.Out, body); err != nil {
		return fmt.Errorf("reading the log of %s: %w", opts.ID, err)
	}
	return nil
}

// END logs OMIT
// START docs OMIT

// newDocsCmd generates reference documentation from the command tree, so
// the man pages and the website can never disagree with --help. It is
// hidden: packagers and the docs pipeline run it, users don't.
func newDocsCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:       "docs {man|markdown} DIR",
		Short:     "Generate reference documentation",
		Hidden:    true,
		Args:      cli.ExactArgs("FORMAT", "DIR"),
		ValidArgs: []cobra.Completion{"man", "markdown"},
		RunE: func(c *cobra.Command, args []string) error {
			root := c.Root()
			root.DisableAutoGenTag = true // keep the output reproducible
			switch args[0] {
			case "man":
				h := &doc.GenManHeader{Title: "PLAT", Section: "1"}
				return doc.GenManTree(root, h, args[1])
			case "markdown":
				return doc.GenMarkdownTree(root, args[1])
			}
			return cli.UsageError(c,
				fmt.Errorf("unknown format %q: want man or markdown", args[0]))
		},
	}
	return cmd
}

// END docs OMIT
