// START head OMIT

package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"

	"sweep/internal/sweep/sweeptest"
)

// END head OMIT

// START update OMIT
var update = flag.Bool("update", false, "rewrite golden files in testdata/golden")

// END update OMIT

// START scrub OMIT
var (
	loopbackRE = regexp.MustCompile(`127\.0\.0\.1:\d+`)
	elapsedRE  = regexp.MustCompile(` in [0-9.]+(µs|ms|s|m[0-9.]+s): `)
)

// scrubText replaces what changes between runs (ports chosen by the
// kernel, wall-clock durations) with fixed placeholders.
func scrubText(s string) string {
	s = loopbackRE.ReplaceAllString(s, "127.0.0.1:PORT")
	return elapsedRE.ReplaceAllString(s, " in ELAPSED: ")
}

// scrubJSON normalises a -o json document structurally: decode, zero the
// timings, re-encode. Regexps over JSON break on the first escaped quote.
func scrubJSON(t *testing.T, doc []byte) []byte {
	t.Helper()
	var v struct {
		Summary map[string]any   `json:"summary"`
		Results []map[string]any `json:"results"`
	}
	if err := json.Unmarshal(doc, &v); err != nil {
		t.Fatalf("output is not JSON: %v\n%s", err, doc)
	}
	v.Summary["elapsed_ns"] = 0
	for _, r := range v.Results {
		r["latency_ns"] = 0
	}
	out, err := json.MarshalIndent(v, "", "  ") // map keys come out sorted
	if err != nil {
		t.Fatal(err)
	}
	return []byte(scrubText(string(out)) + "\n")
}

// END scrub OMIT

// START golden OMIT
// TestRunGolden runs the whole CLI against a fake fleet over real sockets
// and compares scrubbed stdout and stderr with golden files.
func TestRunGolden(t *testing.T) {
	srv, _ := sweeptest.NewServer(t)
	inv := strings.Join([]string{
		srv.URL + "/ok", srv.URL + "/flaky", srv.URL + "/down",
		srv.URL + "/missing", srv.URL + "/slow", "tcp://" + closedPort(t),
	}, "\n")
	t.Chdir(t.TempDir()) // relative paths, as a user would type them
	if err := os.WriteFile("fleet.txt", []byte(inv), 0o600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	args := []string{"-o", "json", "-timeout", "300ms", "fleet.txt"}
	if code := run(t.Context(), args, nil, &stdout, &stderr); code != exitDown {
		t.Fatalf("exit status %d, want %d\n%s", code, exitDown, stderr.String())
	}
	goldenFile(t, "run-json", scrubJSON(t, stdout.Bytes()))
	goldenFile(t, "run-stderr", []byte(scrubText(stderr.String())))
}

// END golden OMIT

// START goldenfile OMIT
func goldenFile(t *testing.T, name string, got []byte) {
	t.Helper()
	// Not a relative path: tests that call t.Chdir would look in the wrong place.
	path := filepath.Join(testDir, "testdata", "golden", name+".golden")
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

// testDir is the package directory, captured before any test calls Chdir.
var testDir = func() string {
	wd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	return wd
}()

// END goldenfile OMIT
