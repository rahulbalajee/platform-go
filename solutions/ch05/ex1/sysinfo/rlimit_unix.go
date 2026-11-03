//go:build linux || darwin

package sysinfo

import "syscall"

// NoFile returns the soft and hard RLIMIT_NOFILE of the calling process.
func NoFile() (soft, hard uint64, err error) {
	var r syscall.Rlimit
	err = syscall.Getrlimit(syscall.RLIMIT_NOFILE, &r)
	return r.Cur, r.Max, err
}
