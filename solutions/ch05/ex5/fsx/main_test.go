package fsx_test

import (
	"os"
	"testing"

	"go.uber.org/goleak"
)

// TestMain doubles as a helper process for the cross-process lock test and
// fails the package if any test leaks a goroutine.
func TestMain(m *testing.M) {
	if path := os.Getenv("FSX_HOLD_LOCK"); path != "" {
		holdLock(path) // never returns
	}
	goleak.VerifyTestMain(m)
}
