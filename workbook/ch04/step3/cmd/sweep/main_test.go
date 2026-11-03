package main

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRunEndToEnd drives the real entry point against real sockets: one
// healthy HTTP server and one that answers 503.
func TestRunEndToEnd(t *testing.T) {
	ok := func(http.ResponseWriter, *http.Request) {}
	unavailable := func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	healthy := httptest.NewServer(http.HandlerFunc(ok))
	defer healthy.Close()
	broken := httptest.NewServer(http.HandlerFunc(unavailable))
	defer broken.Close()

	inv := filepath.Join(t.TempDir(), "targets.txt")
	content := strings.Join([]string{
		"# staging fleet",
		healthy.URL + "/healthz",
		broken.URL + "/healthz",
	}, "\n")
	if err := os.WriteFile(inv, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	args := []string{"-timeout", "2s", inv}
	code := run(t.Context(), args, strings.NewReader(""), &stdout, &stderr)
	if code != exitDown {
		t.Fatalf("exit code = %d, want %d; stderr:\n%s",
			code, exitDown, stderr.String())
	}
	out := stdout.String()
	if strings.Count(out, "UP ") != 1 || !strings.Contains(out, "503 Service") {
		t.Errorf("stdout:\n%s\nwant one target up and one 503", out)
	}
	if !strings.Contains(stderr.String(), "checked 2/2 targets") {
		t.Errorf("stderr summary missing: %q", stderr.String())
	}
}

// START usage OMIT
func TestRunUsageErrors(t *testing.T) {
	const inv = "https://example.com\n"
	for name, tc := range map[string]struct {
		args  []string
		stdin string
		want  string
	}{
		"bad flag":   {[]string{"-nope"}, "", "flag provided but not defined"},
		"bad target": {nil, "gopher://example.com\n", "unsupported scheme"},
		"bad limits": {[]string{"-c", "0"}, inv, "concurrency must be >= 1"},
	} {
		t.Run(name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			code := run(t.Context(), tc.args, strings.NewReader(tc.stdin),
				&stdout, &stderr)
			if code != exitUsage || !strings.Contains(stderr.String(), tc.want) {
				t.Errorf("code=%d stderr=%q; want %d and %q",
					code, stderr.String(), exitUsage, tc.want)
			}
		})
	}
}

// END usage OMIT

func TestRunInterruptedExitsWith130(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel() // as if Ctrl-C came before the first check finished

	var stdout, stderr bytes.Buffer
	stdin := strings.NewReader("https://example.invalid\n")
	code := run(ctx, nil, stdin, &stdout, &stderr)
	if code != exitInterrupted {
		t.Fatalf("exit code = %d, want 130", code)
	}
	if !strings.Contains(stderr.String(), "interrupted") {
		t.Errorf("stderr = %q, want an interrupted summary", stderr.String())
	}
}
