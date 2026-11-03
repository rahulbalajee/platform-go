package fsx_test

import (
	"testing"

	"go.uber.org/goleak"
)

// TestMain fails the package if any test leaks a goroutine.
func TestMain(m *testing.M) {
	goleak.VerifyTestMain(m)
}
