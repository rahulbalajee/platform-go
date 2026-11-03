// START imports OMIT
package main

import (
	"bytes"
	"strings"
	"testing"
)

// END imports OMIT

// START settings OMIT

// TestRunPrintsSettings checks the raw build settings of the test binary.
// go test builds it from this package, so its path ends in ".test".
func TestRunPrintsSettings(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run(nil, &out, &errb); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errb.String())
	}
	for _, want := range []string{".test\n", "\nGOOS ", "\nGOARCH "} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("output lacks %q:\n%s", want, out.String())
		}
	}
}

func TestRunUsageError(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run([]string{"-bogus"}, &out, &errb); code != 2 {
		t.Errorf("exit %d, want 2", code)
	}
	if !strings.Contains(errb.String(), "flag provided but not defined") {
		t.Errorf("stderr = %q", errb.String())
	}
}

// END settings OMIT

// START version OMIT
func TestRunVersion(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run([]string{"-version"}, &out, &errb); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errb.String())
	}
	// go test builds without VCS stamping, so the version is "devel".
	if got := out.String(); !strings.HasPrefix(got, "stamp.test devel go1.") {
		t.Errorf("stdout = %q", got)
	}
}

// END version OMIT
