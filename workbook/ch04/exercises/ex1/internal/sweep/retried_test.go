package sweep_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"sweep/internal/sweep"
)

// A target counts as retried if it needed more than one attempt, whether
// it came up in the end or not.
func TestSummaryCountsRetriedTargets(t *testing.T) {
	sum := sweep.Summary{Total: 3, Elapsed: 2 * time.Second}
	for _, r := range []sweep.Result{
		{Status: sweep.StatusUp, Attempts: 1},
		{Status: sweep.StatusUp, Attempts: 3},   // flaky: up on the third try
		{Status: sweep.StatusDown, Attempts: 3}, // retried, still down
	} {
		sum.Tally(r)
	}
	if sum.Retried != 2 {
		t.Errorf("Retried = %d, want 2", sum.Retried)
	}
	want := "checked 3/3 targets in 2s: 2 up, 1 down, 2 retried"
	if got := sum.String(); got != want {
		t.Errorf("String() = %q, want %q", got, want)
	}
	b, err := json.Marshal(sum)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"retried":2`) {
		t.Errorf("JSON = %s, want a \"retried\" field", b)
	}
}

func TestSummaryLeavesOutZeroRetried(t *testing.T) {
	sum := sweep.Summary{Total: 2}
	sum.Tally(sweep.Result{Status: sweep.StatusUp, Attempts: 1})
	sum.Tally(sweep.Result{Status: sweep.StatusCancelled})
	want := "checked 2/2 targets in 0s: 1 up, 0 down, 1 cancelled"
	if got := sum.String(); got != want {
		t.Errorf("String() = %q, want %q", got, want)
	}
}
