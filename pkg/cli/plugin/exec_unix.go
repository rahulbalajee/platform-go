//go:build !windows

package plugin

// START run OMIT

import "syscall"

// Run replaces the running process with the plugin, as kubectl does on
// Unix: the plugin inherits the process ID, the terminal, the signals and
// the exit status, with no parent left in between to forward them. It
// returns only if the exec fails.
func Run(p Plugin, args, env []string) error {
	// The path comes from a PATH search the user controls: running it is
	// the point, so gosec's warning about "tainted" commands doesn't apply.
	return syscall.Exec(p.Path, append([]string{p.Path}, args...), env) //nolint:gosec
}

// END run OMIT
