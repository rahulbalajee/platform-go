//go:build unix

package procx

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
)

// START group OMIT

func setGroup(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true // Pgid 0: the group ID is the child's PID
}

// signalGroup sends sig to the process group led by p. A negative PID in
// kill(2) addresses the whole group.
func signalGroup(p *os.Process, sig syscall.Signal) error {
	err := syscall.Kill(-p.Pid, sig)
	if errors.Is(err, syscall.ESRCH) {
		return os.ErrProcessDone
	}
	return err
}

// END group OMIT
