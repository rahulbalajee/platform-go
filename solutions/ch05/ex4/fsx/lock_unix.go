//go:build darwin || dragonfly || freebsd || linux || netbsd || openbsd

package fsx

import (
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

// errWouldBlock is what flock returns with LOCK_NB when the lock is held.
var errWouldBlock = unix.EWOULDBLOCK

// START flock OMIT
func lockFile(f *os.File) error   { return flock(f, unix.LOCK_EX|unix.LOCK_NB) }
func unlockFile(f *os.File) error { return flock(f, unix.LOCK_UN) }

// flock locks the open file description behind f. Go opens files with
// O_CLOEXEC, so child processes do not inherit the descriptor (and the
// lock) unless it is passed to them explicitly via exec.Cmd.ExtraFiles.
func flock(f *os.File, how int) error {
	rc, err := f.SyscallConn()
	if err != nil {
		return err
	}
	var ferr error
	err = rc.Control(func(fd uintptr) {
		for {
			ferr = unix.Flock(int(fd), how) //nolint:gosec // fds fit in an int
			if !errors.Is(ferr, unix.EINTR) {
				return
			}
		}
	})
	return errors.Join(err, ferr)
}

// END flock OMIT
