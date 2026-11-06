package main

// START imports OMIT

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/rahulbalajee/platform-go/pkg/lifecycle"
)

// END imports OMIT

// START e2e OMIT

// TestRunEndToEnd drives the real entry point against real sockets: one
// healthy HTTP server, one that answers 503, and a TCP port nobody listens on.
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
		"tcp://" + closedPort(t),
	}, "\n")
	if err := os.WriteFile(inv, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	args := []string{"-o", "json", "-attempts", "2", "-timeout", "2s", inv}
	code := run(t.Context(), args, strings.NewReader(""), &stdout, &stderr)
	if code != exitDown {
		t.Fatalf("exit code = %d, want %d; stderr:\n%s",
			code, exitDown, stderr.String())
	}
	var doc struct {
		Summary struct{ Total, Up, Down int }
		Results []struct {
			Target, Status string
			Attempts       int
		}
	}
	if err := json.Unmarshal(stdout.Bytes(), &doc); err != nil {
		t.Fatalf("output is not JSON: %v\n%s", err, stdout.String())
	}
	if doc.Summary.Total != 3 || doc.Summary.Up != 1 || doc.Summary.Down != 2 {
		t.Errorf("summary = %+v, want 3 total, 1 up, 2 down", doc.Summary)
	}
	if r := doc.Results[1]; r.Status != "down" || r.Attempts != 2 {
		t.Errorf("503 target = %+v, want down after 2 attempts", r)
	}
	if !strings.Contains(stderr.String(), "checked 3/3 targets") {
		t.Errorf("stderr summary missing: %q", stderr.String())
	}
}

// END e2e OMIT

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
		"bad format": {[]string{"-o", "xml"}, inv, "unknown output format"},
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

// START interrupted OMIT

func TestRunInterruptedExitsWith130(t *testing.T) {
	ctx, cancel := context.WithCancelCause(t.Context())
	cancel(&lifecycle.SignalError{Signal: syscall.SIGINT}) // as if Ctrl-C came first

	var stdout, stderr bytes.Buffer
	stdin := strings.NewReader("https://example.invalid\n")
	code := run(ctx, nil, stdin, &stdout, &stderr)
	if code != lifecycle.ExitInterrupted {
		t.Fatalf("exit code = %d, want 130", code)
	}
	if !strings.Contains(stderr.String(), "interrupted") {
		t.Errorf("stderr = %q, want an interrupted summary", stderr.String())
	}
}

// END interrupted OMIT

// START closedport OMIT

// closedPort returns an address that refuses connections.
func closedPort(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()
	return addr
}

// END closedport OMIT
