//go:build !race

package sweep_test

import (
	"io"
	"testing"

	"sweep/internal/sweep"
)

// TestTableReporterAllocations bounds the allocations the table reporter
// makes per row. The race detector changes allocation counts, so the file
// is left out of -race builds.
func TestTableReporterAllocations(t *testing.T) {
	rs := results(1000) // from bench_test.go
	allocs := testing.AllocsPerRun(20, func() {
		rep, err := sweep.NewReporter("table", io.Discard)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range rs {
			_ = rep.Add(r)
		}
		_ = rep.Close(sweep.Summary{Total: len(rs)})
	})
	if perRow := allocs / float64(len(rs)); perRow > 2 {
		t.Errorf("table reporter: %.2f allocations per row, want at most 2", perRow)
	}
}
