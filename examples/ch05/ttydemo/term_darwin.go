package main

import (
	"os"

	"golang.org/x/sys/unix"
)

// isTerminal asks the kernel for the terminal attributes of f. Only a
// terminal (or pseudo-terminal) has them; for a pipe, file or /dev/null
// the ioctl fails with ENOTTY.
func isTerminal(f *os.File) bool {
	_, err := unix.IoctlGetTermios(int(f.Fd()), unix.TIOCGETA) //nolint:gosec // fd fits in int
	return err == nil
}
