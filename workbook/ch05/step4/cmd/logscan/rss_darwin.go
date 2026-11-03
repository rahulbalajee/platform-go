package main

import "syscall"

// peakRSS returns the process's maximum resident set size in bytes.
// macOS reports ru_maxrss in bytes.
func peakRSS() int64 {
	var ru syscall.Rusage
	if syscall.Getrusage(syscall.RUSAGE_SELF, &ru) != nil {
		return 0
	}
	return ru.Maxrss
}
