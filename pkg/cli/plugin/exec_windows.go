package plugin

import (
	"errors"
	"os"
	"os/exec"
)

// Run runs the plugin and exits with its status. Windows has no exec that
// replaces a process, so plat stays as the parent and waits. Like the Unix
// Run, it returns only if the plugin could not be started.
func Run(p Plugin, args, env []string) error {
	// No context: Ctrl-C reaches the plugin from the console, and it decides
	// when to stop. A context would kill it instead.
	cmd := exec.Command(p.Path, args...) //nolint:gosec,noctx // the user's plugin
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = env
	err := cmd.Run()
	if ee, ok := errors.AsType[*exec.ExitError](err); ok {
		os.Exit(ee.ExitCode())
	}
	if err == nil {
		os.Exit(0)
	}
	return err
}
