// START head OMIT

package sweep_test

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/rahulbalajee/platform-go/internal/sweep"
)

// END head OMIT

// START summary OMIT

func TestSummary(t *testing.T) {
	sum := sweep.Summary{Total: 4, Elapsed: 1500 * time.Millisecond}
	statuses := []sweep.Status{sweep.StatusUp, sweep.StatusDown, sweep.StatusUp}
	for _, s := range statuses {
		sum.Tally(sweep.Result{Status: s})
	}
	if sum.Healthy() {
		t.Error("Healthy() = true with one target down and one unchecked")
	}
	want := "checked 3/4 targets in 1.5s: 2 up, 1 down"
	if got := sum.String(); got != want {
		t.Errorf("String() = %q, want %q", got, want)
	}
}

// END summary OMIT

// START jsonl OMIT

func TestJSONLWritesEachResultImmediately(t *testing.T) {
	var buf bytes.Buffer
	rep, err := sweep.NewReporter("jsonl", &buf)
	if err != nil {
		t.Fatal(err)
	}
	r := sweep.Result{Index: 1, Target: "tcp://db:5432", Kind: sweep.KindTCP,
		Status: sweep.StatusUp, Attempts: 1, Latency: 3 * time.Millisecond}
	if err := rep.Add(r); err != nil {
		t.Fatal(err)
	}
	// Before Close: a consumer such as jq sees the line straight away.
	want := `{"index":1,"target":"tcp://db:5432","kind":"tcp","status":"up",` +
		`"attempts":1,"latency_ns":3000000}` + "\n"
	if got := buf.String(); got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
}

// END jsonl OMIT

// START table OMIT

func TestTableIsInInputOrder(t *testing.T) {
	var buf bytes.Buffer
	rep, err := sweep.NewReporter("table", &buf)
	if err != nil {
		t.Fatal(err)
	}
	for _, i := range []int{2, 0, 1} { // completion order
		target := "dns://host-" + string(rune('a'+i))
		_ = rep.Add(sweep.Result{Index: i, Target: target, Status: sweep.StatusUp})
	}
	if err := rep.Close(sweep.Summary{}); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 4 || !strings.HasPrefix(lines[0], "STATUS") {
		t.Fatalf("want a header and 3 rows, got:\n%s", buf.String())
	}
	for i, host := range []string{"host-a", "host-b", "host-c"} {
		if !strings.Contains(lines[i+1], host) {
			t.Errorf("row %d = %q, want %s (input order)", i, lines[i+1], host)
		}
	}
}

// END table OMIT
