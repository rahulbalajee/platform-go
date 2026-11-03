//go:build !linux && !darwin

package main

import "os"

// isTerminal is not implemented on this platform.
func isTerminal(*os.File) bool { return false }
