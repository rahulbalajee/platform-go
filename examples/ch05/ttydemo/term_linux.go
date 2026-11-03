package main

import (
	"os"

	"golang.org/x/sys/unix"
)

// isTerminal asks the kernel for the terminal attributes of f. Only a
// terminal (or pseudo-terminal) has them; for a pipe, file or /dev/null
// the ioctl fails with ENOTTY.
func isTerminal(f *os.File) bool {
	fd := int(f.Fd()) //nolint:gosec // descriptors fit in an int
	_, err := unix.IoctlGetTermios(fd, unix.TCGETS)
	return err == nil
}
