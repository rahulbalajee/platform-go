// START head OMIT

// Package procx runs subprocesses the way production tools need to: no
// shell, in their own process group, with a SIGTERM-then-SIGKILL shutdown
// that reaches grandchildren too, and nothing left running after Wait.
package procx

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

// DefaultGrace is how long a cancelled command gets between SIGTERM and
// SIGKILL.
const DefaultGrace = 5 * time.Second

// Cmd is an exec.Cmd that runs in its own process group. Configure it
// through the embedded exec.Cmd (Dir, Env, Stdin, Stdout, WaitDelay, ...),
// but run and wait for it with the methods on Cmd: exec.Cmd's own Run,
// Output and CombinedOutput would bypass the group cleanup in Wait.
type Cmd struct {
	*exec.Cmd
}

// END head OMIT

// START command OMIT

// Command returns a Cmd that runs name with args, without a shell, in a new
// process group. When ctx is done the whole group gets SIGTERM. If the
// command has not exited WaitDelay (DefaultGrace) later, it gets SIGKILL,
// and Wait then kills whatever is left in the group.
func Command(ctx context.Context, name string, args ...string) *Cmd {
	c := &Cmd{Cmd: exec.CommandContext(ctx, name, args...)}
	setGroup(c.Cmd) // Setpgid: the child leads a new process group

	// The default Cancel kills only the leader. Ask the whole group to stop.
	c.Cancel = func() error {
		return signalGroup(c.Process, syscall.SIGTERM)
	}
	// After this long, exec kills the leader and closes our pipe ends.
	c.WaitDelay = DefaultGrace
	return c
}

// END command OMIT

// START wait OMIT

// Wait waits for the command to exit, then kills anything still running in
// its process group: descendants that the command started and abandoned.
func (c *Cmd) Wait() error {
	err := c.Cmd.Wait()
	if c.Process != nil {
		_ = signalGroup(c.Process, syscall.SIGKILL) // usually: no such process
	}
	return err
}

// END wait OMIT

// START run OMIT

// Run starts the command and waits for it.
func (c *Cmd) Run() error {
	if err := c.Start(); err != nil {
		return err
	}
	return c.Wait()
}

// Output runs the command and returns its standard output.
func (c *Cmd) Output() ([]byte, error) {
	if c.Stdout != nil {
		return nil, errors.New("procx: Stdout already set")
	}
	var out bytes.Buffer
	c.Stdout = &out
	err := c.Run()
	return out.Bytes(), err
}

// CombinedOutput runs the command and returns stdout and stderr interleaved.
func (c *Cmd) CombinedOutput() ([]byte, error) {
	if c.Stdout != nil || c.Stderr != nil {
		return nil, errors.New("procx: Stdout or Stderr already set")
	}
	var out bytes.Buffer
	c.Stdout, c.Stderr = &out, &out
	err := c.Run()
	return out.Bytes(), err
}

// Signal sends sig to every process in the command's group.
func (c *Cmd) Signal(sig syscall.Signal) error {
	if c.Process == nil {
		return errors.New("procx: not started")
	}
	return signalGroup(c.Process, sig)
}

// END run OMIT

// START forward OMIT

// Forward relays the given signals, when this process receives them, to
// the command's process group until stop is called. Call it after Start.
// A child in its own group no longer gets terminal-generated signals
// (Ctrl-C, window resizes), so a supervisor must pass on the ones the
// child cares about.
func (c *Cmd) Forward(sigs ...os.Signal) (stop func()) {
	ch := make(chan os.Signal, 4)
	signal.Notify(ch, sigs...)
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Go(func() {
		for {
			select {
			case s := <-ch:
				if sig, ok := s.(syscall.Signal); ok && c.Process != nil {
					_ = signalGroup(c.Process, sig)
				}
			case <-done:
				return
			}
		}
	})
	var once sync.Once
	return func() {
		once.Do(func() { signal.Stop(ch); close(done); wg.Wait() })
	}
}

// END forward OMIT

// START exitcode OMIT

// ExitCode maps an error from Run or Wait to a shell-style exit status: 0
// for success, the child's own status if it exited, 128+n if it was killed
// by signal n, and -1 if it never ran.
func ExitCode(err error) int {
	if err == nil {
		return 0
	}
	ee, ok := errors.AsType[*exec.ExitError](err)
	if !ok {
		return -1
	}
	if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return ee.ExitCode()
}

// END exitcode OMIT
