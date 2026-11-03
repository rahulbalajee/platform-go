package sweep_test

import (
	"testing"

	"go.uber.org/goleak"
)

// TestMain fails the package if any test leaves a goroutine behind.
func TestMain(m *testing.M) { goleak.VerifyTestMain(m) }
