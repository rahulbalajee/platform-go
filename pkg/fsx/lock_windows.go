//go:build windows

package fsx

import (
	"os"

	"golang.org/x/sys/windows"
)

// errWouldBlock is what LockFileEx returns with LOCKFILE_FAIL_IMMEDIATELY
// when another handle holds the range.
var errWouldBlock = windows.ERROR_LOCK_VIOLATION

// Windows byte-range locks are mandatory: while one handle holds the range,
// other handles cannot read or write those bytes. Locking one byte at
// offset 0 is enough for mutual exclusion; the lock is released when the
// handle is closed or the process exits.
func lockFile(f *os.File) error {
	ol := new(windows.Overlapped)
	return windows.LockFileEx(windows.Handle(f.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, ol)
}

func unlockFile(f *os.File) error {
	ol := new(windows.Overlapped)
	return windows.UnlockFileEx(windows.Handle(f.Fd()), 0, 1, 0, ol)
}
