//go:build !linux && !darwin

package main

// peakRSS is not implemented on this platform.
func peakRSS() int64 { return 0 }
