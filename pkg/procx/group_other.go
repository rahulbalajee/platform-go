//go:build !unix

package procx

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
)

// setGroup does nothing outside Unix. On Windows the equivalent of a
// process group that can be killed as a unit is a Job object.
func setGroup(*exec.Cmd) {}

// signalGroup signals only the process itself outside Unix. Windows has no
// SIGTERM: anything other than SIGKILL is reported as unsupported.
func signalGroup(p *os.Process, sig syscall.Signal) error {
	var err error
	if sig == syscall.SIGKILL {
		err = p.Kill()
	} else {
		err = p.Signal(sig)
	}
	if errors.Is(err, os.ErrProcessDone) {
		return os.ErrProcessDone
	}
	return err
}
