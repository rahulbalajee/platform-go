package cli

// START imports OMIT

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/pkg/cli/plugin"
)

// END imports OMIT
// START options OMIT

// Option changes how Main runs a tool.
type Option func(*options)

type options struct{ plugins bool }

// WithPlugins makes Main run executable plugins: for `tool NAME ARGS...`
// where the tool has no NAME command, the first tool-NAME on PATH (see
// package plugin). Built-in commands always win, so installing a plugin
// can't change what an existing command does.
func WithPlugins() Option { return func(o *options) { o.plugins = true } }

// END options OMIT
// START find OMIT

// findPlugin returns the plugin that args name, if the first argument is
// not a flag and not one of root's commands.
func findPlugin(name string, root *cobra.Command,
	args []string,
) (plugin.Plugin, []string, bool) {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") || isBuiltin(root, args) {
		return plugin.Plugin{}, nil, false
	}
	return plugin.Lookup(plugin.Find(name, os.Getenv("PATH")), args)
}

// isBuiltin reports whether args start with one of root's commands. Cobra
// adds `help`, `completion` and the hidden `__complete` only when it runs,
// so Find can't see them yet: they are added here first, or a plugin
// called tool-help could replace the help command.
func isBuiltin(root *cobra.Command, args []string) bool {
	if strings.HasPrefix(args[0], "__") { // __complete and friends
		return true
	}
	root.InitDefaultHelpCmd()
	root.InitDefaultCompletionCmd()
	cmd, _, err := root.Find(args)
	return err == nil && cmd != root
}

// IsBuiltin reports whether name is one of root's commands, for listings
// that warn about plugins a built-in command hides.
func IsBuiltin(root *cobra.Command, name string) bool {
	return isBuiltin(root, []string{name})
}

// runPlugin returns only if the plugin could not be started: on success,
// the process is the plugin's (or, on Windows, exits with its status).
func runPlugin(name string, p plugin.Plugin, args []string) error {
	env, err := plugin.Env(name)
	if err != nil {
		return err
	}
	return fmt.Errorf("running plugin %s: %w", p.Path, plugin.Run(p, args, env))
}

// END find OMIT
