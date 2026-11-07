package commands

// START imports OMIT

import (
	"context"
	"strings"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/output"
	"github.com/rahulbalajee/platform-go/pkg/cli/plugin"
)

// END imports OMIT
// START list OMIT

func newPluginCmd(f *factory.Factory) *cobra.Command {
	cmd := cli.Group(&cobra.Command{
		Use:   "plugin",
		Short: "Manage plat plugins",
		Long: `A plugin is any executable on your PATH named plat-NAME:
'plat NAME ARGS' runs it with ARGS. Dashes in the name are words, so
plat-db-backup runs as 'plat db backup'. Built-in commands take precedence,
and the first plugin of a name on PATH wins. Plugins get plat's environment
plus PLAT_BIN, the path of plat itself.`,
	})
	cmd.AddCommand(newPluginListCmd(f))
	return cmd
}

type pluginListOptions struct {
	IO     *cli.IOStreams
	Path   string
	Root   *cobra.Command
	Output string
}

func newPluginListCmd(f *factory.Factory) *cobra.Command {
	opts := &pluginListOptions{IO: f.IO}
	cmd := &cobra.Command{
		Use:   "list",
		Short: "List the plugins on PATH, and the ones that will never run",
		Args:  cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			opts.Path, opts.Root = f.Getenv("PATH"), c.Root()
			return runPluginList(c.Context(), opts)
		},
	}
	output.AddFlag(cmd, &opts.Output)
	return cmd
}

// runPluginList shows every plugin with the reason it may not run: hidden
// by a built-in command, or by another plugin earlier on PATH.
func runPluginList(_ context.Context, opts *pluginListOptions) error {
	p, err := output.New(opts.IO, opts.Output)
	if err != nil {
		return usage(err)
	}
	plugins := plugin.Find("plat", opts.Path)
	if p.Machine() {
		return p.Data(nonNil(plugins))
	}
	if len(plugins) == 0 {
		_, err := opts.IO.ErrOut.Write([]byte(
			"No plugins: no plat-* executables in the PATH directories.\n"))
		return err
	}
	t := p.Table(output.Column{Name: "name"}, output.Column{Name: "path"},
		output.Column{Name: "note"})
	for _, pl := range plugins {
		var notes []string
		word, _, _ := strings.Cut(pl.Name, "-")
		if cli.IsBuiltin(opts.Root, word) {
			notes = append(notes, p.Paint(output.Red,
				"never runs: 'plat "+word+"' is a built-in command"))
		}
		for _, s := range pl.Shadows {
			notes = append(notes, "hides "+s)
		}
		t.Row(pl.Name, pl.Path, strings.Join(notes, "; "))
	}
	return t.Flush()
}

// END list OMIT
