// START top OMIT
// START head OMIT

package sweep_test

import (
	"bytes"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"

	"sweep/internal/sweep"
)

// END head OMIT

// START golden OMIT
var update = flag.Bool("update", false, "rewrite golden files in testdata/golden")

// golden compares got with testdata/golden/<name>.golden. With -update it
// rewrites the file instead, and the diff shows up in code review.
func golden(t *testing.T, name string, got []byte) {
	t.Helper()
	path := filepath.Join("testdata", "golden", name+".golden")
	if *update {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run 'go test -update' to create it)", err)
	}
	// Diff line by line: cmp.Diff on two long strings reports byte ranges.
	lines := func(b []byte) []string { return strings.Split(string(b), "\n") }
	if diff := cmp.Diff(lines(want), lines(got)); diff != "" {
		t.Errorf("%s mismatch (-want +got):\n%s", path, diff)
	}
}

// END golden OMIT
// END top OMIT

// START fixture OMIT
// sampleRun is a fixed, fully deterministic sweep: every field a reporter
// prints is pinned, including latencies and the elapsed time. Results are
// listed in completion order, which differs from input order on purpose.
func sampleRun() ([]sweep.Result, sweep.Summary) {
	results := []sweep.Result{
		{Index: 2, Target: "tcp://db.test:5432", Kind: sweep.KindTCP,
			Status: sweep.StatusUp, Attempts: 1, Latency: 3 * time.Millisecond,
			Detail: "connected to 10.0.3.7:5432"},
		{Index: 0, Target: "https://api.test/healthz", Kind: sweep.KindHTTP,
			Status: sweep.StatusUp, Attempts: 1, Latency: 42 * time.Millisecond,
			Detail: "200 OK"},
		{Index: 4, Target: "dns://gone.test", Kind: sweep.KindDNS,
			Status: sweep.StatusDown, Attempts: 1, Latency: 12 * time.Millisecond,
			Error: "lookup gone.test: no such host"},
		{Index: 1, Target: "https://web.test/healthz", Kind: sweep.KindHTTP,
			Status: sweep.StatusDown, Attempts: 3, Latency: 2 * time.Second,
			Detail: "503 Service Unavailable",
			Error:  "unhealthy status 503 Service Unavailable (after 3 attempts)"},
		{Index: 3, Target: "tls://legacy.test:443", Kind: sweep.KindTLS,
			Status: sweep.StatusDown, Attempts: 1, Latency: 81 * time.Millisecond,
			Detail: `cert "legacy.test" expires in 6d`,
			Error:  "certificate expires in 6d (minimum 14d)"},
	}
	sum := sweep.Summary{Total: 5, Elapsed: 2*time.Second + 140*time.Millisecond}
	for _, r := range results {
		sum.Tally(r)
	}
	return results, sum
}

// END fixture OMIT

// START test OMIT
func TestReportersGolden(t *testing.T) {
	for _, format := range []string{"table", "wide", "json", "jsonl"} {
		t.Run(format, func(t *testing.T) {
			var buf bytes.Buffer
			rep, err := sweep.NewReporter(format, &buf)
			if err != nil {
				t.Fatal(err)
			}
			results, sum := sampleRun()
			for _, r := range results {
				if err := rep.Add(r); err != nil {
					t.Fatal(err)
				}
			}
			if err := rep.Close(sum); err != nil {
				t.Fatal(err)
			}
			golden(t, "report-"+format, buf.Bytes())
		})
	}
}

// END test OMIT
