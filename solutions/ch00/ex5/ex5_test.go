package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRunInvert(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"-v", "-level", "error"},
		strings.NewReader(testLog), &stdout, &stderr)
	if code != 0 {
		t.Fatalf("exit status = %d, want 0; stderr:\n%s", code, stderr.String())
	}
	want := "2026-11-03T09:00:01Z INFO api listening on :8080\n"
	if stdout.String() != want {
		t.Errorf("stdout:\n%s\nwant:\n%s", stdout.String(), want)
	}
}

func TestRunInvertCount(t *testing.T) {
	var stdout, stderr bytes.Buffer
	run([]string{"-v", "-count", "-grep", "timeout"},
		strings.NewReader(testLog), &stdout, &stderr)
	want := `query: not (level>=DEBUG and message contains "timeout")` + "\n"
	if !strings.HasPrefix(stdout.String(), want) {
		t.Errorf("stdout does not start with %q:\n%s", want, stdout.String())
	}
}
