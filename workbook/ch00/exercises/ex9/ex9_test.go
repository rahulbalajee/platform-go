package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRunTopByMinute(t *testing.T) {
	log := `2026-11-03T09:01:10Z INFO api a
2026-11-03T09:02:10Z ERROR api b
2026-11-03T09:02:20Z ERROR db c
2026-11-03T09:02:59Z WARN api d
2026-11-03T09:03:00Z INFO api e
2026-11-03T09:03:30Z INFO api f
`
	var stdout, stderr bytes.Buffer
	code := run([]string{"-top", "2", "-by", "minute"},
		strings.NewReader(log), &stdout, &stderr)
	if code != 0 {
		t.Fatalf("exit status = %d, want 0; stderr:\n%s", code, stderr.String())
	}
	want := "09:02    3\n09:03    2\n"
	if stdout.String() != want {
		t.Errorf("stdout:\n%s\nwant:\n%s", stdout.String(), want)
	}
}

func TestRunTopByUnknown(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"-top", "2", "-by", "colour"},
		strings.NewReader(testLog), &stdout, &stderr)
	if code != 2 {
		t.Errorf("exit status = %d, want 2", code)
	}
}
