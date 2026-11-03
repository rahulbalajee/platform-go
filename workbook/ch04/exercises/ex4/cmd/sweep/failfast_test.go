package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.uber.org/goleak"
)

// One target refuses connections; twenty more hang until their request is
// cancelled. With -fail-fast, the refused one ends the sweep at once.
func TestFailFastStopsAtFirstDownTarget(t *testing.T) {
	defer goleak.VerifyNone(t, goleak.IgnoreCurrent())

	hang := func(_ http.ResponseWriter, r *http.Request) { <-r.Context().Done() }
	slow := httptest.NewServer(http.HandlerFunc(hang))
	defer slow.Close()

	lines := []string{"tcp://" + closedPort(t)}
	for i := range 20 {
		lines = append(lines, fmt.Sprintf("%s/?n=%d", slow.URL, i))
	}
	inv := filepath.Join(t.TempDir(), "inventory.txt")
	data := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(inv, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	args := []string{"-fail-fast", "-c", "4", "-attempts", "1", "-timeout", "5s", inv}
	start := time.Now()
	code := run(context.Background(), args, nil, &stdout, &stderr)
	elapsed := time.Since(start)

	if code != exitDown {
		t.Errorf("exit code = %d, want %d", code, exitDown)
	}
	summary := stderr.String()
	if !strings.HasPrefix(summary, "checked 1/21 targets") ||
		!strings.Contains(summary, "(stopped at first failure)") {
		t.Errorf("stderr = %q, want \"checked 1/21 targets ... "+
			"(stopped at first failure)\"", summary)
	}
	// The three hanging checks that were in flight must have been cancelled,
	// not waited out: their timeout is 5s.
	if elapsed > 2*time.Second {
		t.Errorf("run took %v; in-flight checks were not cancelled", elapsed)
	}
}

func TestWithoutFailFastEveryTargetIsChecked(t *testing.T) {
	var stdout, stderr bytes.Buffer
	inv := "tcp://" + closedPort(t) + "\ntcp://" + closedPort(t) + "\n"
	args := []string{"-attempts", "1"}
	code := run(t.Context(), args, strings.NewReader(inv), &stdout, &stderr)
	if code != exitDown || !strings.HasPrefix(stderr.String(), "checked 2/2") {
		t.Errorf("code %d, stderr %q: want 1 and both targets checked",
			code, stderr.String())
	}
}
