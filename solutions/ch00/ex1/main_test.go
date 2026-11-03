package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// START test OMIT

// testLog is what the tests feed to run as standard input.
const testLog = `2026-11-03T09:00:01Z INFO api listening on :8080
2026-11-03T09:02:40Z ERROR api GET /orders 500 timeout
not a log line
2026-11-03T09:04:02Z ERROR worker job 1190 failed: timeout
`

func TestRun(t *testing.T) {
	const (
		orders = "2026-11-03T09:02:40Z ERROR api GET /orders 500 timeout\n"
		job    = "2026-11-03T09:04:02Z ERROR worker job 1190 failed: timeout\n"
	)
	tests := []struct {
		name     string
		args     []string
		wantOut  string
		wantCode int
	}{
		{name: "errors", args: []string{"-level", "error"}, wantOut: orders + job},
		{name: "regexp", args: []string{"-regexp", `job \d+ failed`}, wantOut: job},
		{name: "no match", args: []string{"-grep", "disk full"}, wantCode: 1},
		{
			name: "json",
			args: []string{"-json", "-grep", "job"},
			wantOut: `{"time":"2026-11-03T09:04:02Z","level":"ERROR",` +
				`"service":"worker","message":"job 1190 failed: timeout"}` +
				"\n",
		},
		{name: "top", args: []string{"-top", "1"}, wantOut: "api      2\n"},
		{name: "bad level", args: []string{"-level", "loud"}, wantCode: 2},
		{name: "bad regexp", args: []string{"-regexp", "("}, wantCode: 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			stdin := strings.NewReader(testLog)
			code := run(tt.args, stdin, &stdout, &stderr)
			if code != tt.wantCode {
				t.Errorf("exit status = %d, want %d; stderr:\n%s",
					code, tt.wantCode, stderr.String())
			}
			if got := stdout.String(); got != tt.wantOut {
				t.Errorf("stdout:\n%s\nwant:\n%s", got, tt.wantOut)
			}
		})
	}
}

// END test OMIT

func TestRunCount(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"-count", "-grep", "timeout"},
		strings.NewReader(testLog), &stdout, &stderr)
	if code != 0 {
		t.Fatalf("exit status = %d, want 0", code)
	}
	if want := `stdin:3: bad time "not"` + "\n"; stderr.String() != want {
		t.Errorf("stderr = %q, want %q", stderr.String(), want)
	}
	out := stdout.String()
	for _, want := range []string{
		`query: level>=DEBUG and message contains "timeout"`,
		"ERROR  2",
		"bad    1",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("stdout does not contain %q:\n%s", want, out)
		}
	}
}

// START strict OMIT
func TestRunStrict(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"-strict"}, strings.NewReader(testLog), &stdout, &stderr)
	if code != 2 {
		t.Errorf("exit status = %d, want 2", code)
	}
	want := `logq: stdin:3: bad time "not"` + "\n" +
		"logq: hint: times look like 2026-11-03T09:00:01Z (RFC 3339)\n"
	if stderr.String() != want {
		t.Errorf("stderr:\n%s\nwant:\n%s", stderr.String(), want)
	}
}

func TestRunMissingFile(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"no-such.log"}, strings.NewReader(""), &stdout, &stderr)
	if code != 2 {
		t.Errorf("exit status = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "hint: check the path") {
		t.Errorf("stderr has no hint:\n%s", stderr.String())
	}
}

// END strict OMIT

// START many OMIT
func TestRunManyFiles(t *testing.T) {
	dir := t.TempDir()
	var args, want []string
	for i := range 20 {
		name := filepath.Join(dir, fmt.Sprintf("app%02d.log", i))
		line := fmt.Sprintf("2026-11-03T09:%02d:00Z ERROR api failure %d", i, i)
		if err := os.WriteFile(name, []byte(line+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		args = append(args, name)
		want = append(want, name+":"+line)
	}

	var stdout, stderr bytes.Buffer
	code := run(append([]string{"-j", "3"}, args...), nil, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("exit status = %d, want 0; stderr:\n%s", code, stderr.String())
	}
	if got := strings.Join(want, "\n") + "\n"; stdout.String() != got {
		t.Errorf("stdout is not in command-line order:\n%s", stdout.String())
	}
}

// END many OMIT
