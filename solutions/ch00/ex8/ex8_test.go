package main

import (
	"bytes"
	"strings"
	"testing"
)

// logq must read its own -json output.
func TestRunReadsItsOwnJSON(t *testing.T) {
	var asJSON, stderr bytes.Buffer
	if code := run([]string{"-json"}, strings.NewReader(testLog),
		&asJSON, &stderr); code != 0 {
		t.Fatalf("logq -json: exit status %d", code)
	}

	var stdout bytes.Buffer
	code := run([]string{"-count", "-level", "error"}, &asJSON, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("logq -count: exit status %d; stderr:\n%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "ERROR  2") {
		t.Errorf("counts from JSON input are wrong:\n%s", stdout.String())
	}
}
