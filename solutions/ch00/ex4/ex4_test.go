package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRunService(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"-service", "worker"},
		strings.NewReader(testLog), &stdout, &stderr)
	if code != 0 {
		t.Fatalf("exit status = %d, want 0; stderr:\n%s", code, stderr.String())
	}
	want := "2026-11-03T09:04:02Z ERROR worker job 1190 failed: timeout\n"
	if stdout.String() != want {
		t.Errorf("stdout:\n%s\nwant:\n%s", stdout.String(), want)
	}
}

func TestRunServiceCount(t *testing.T) {
	var stdout, stderr bytes.Buffer
	run([]string{"-count", "-service", "api", "-level", "error"},
		strings.NewReader(testLog), &stdout, &stderr)
	want := "query: level>=ERROR and service=api\n"
	if !strings.HasPrefix(stdout.String(), want) {
		t.Errorf("stdout does not start with %q:\n%s", want, stdout.String())
	}
}
