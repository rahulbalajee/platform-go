package main

import (
	"bytes"
	"encoding/json"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/rahulbalajee/platform-go/pkg/buildinfo"
)

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

func TestRunVersionJSON(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run([]string{"-version", "-json"}, &out, &errb); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errb.String())
	}
	var info buildinfo.Info
	if err := json.Unmarshal(out.Bytes(), &info); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, out.String())
	}
	if info.Version != buildinfo.Devel {
		t.Errorf("version = %q, want %q", info.Version, buildinfo.Devel)
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

// START ldflags OMIT
// TestLinkerOverrides builds the real binary the way a release pipeline
// does and checks that -X values reach the output. It is the only test that
// proves the variable names in the -ldflags string are spelled right.
func TestLinkerOverrides(t *testing.T) {
	if testing.Short() {
		t.Skip("builds a binary")
	}
	const pkg = "github.com/rahulbalajee/platform-go/pkg/buildinfo"
	bin := filepath.Join(t.TempDir(), "stamp")
	ldflags := "-s -w" +
		" -X " + pkg + ".version=v9.8.7" +
		" -X " + pkg + ".revision=0123456789abcdef0123" +
		" -X " + pkg + ".buildTime=2026-11-02T14:07:31Z"
	build := exec.CommandContext(t.Context(), "go", "build",
		"-trimpath", "-buildvcs=false", "-ldflags", ldflags, "-o", bin, ".")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}

	out, err := exec.CommandContext(t.Context(), bin, "-version").Output()
	if err != nil {
		t.Fatalf("stamp -version: %v", err)
	}
	want := "stamp v9.8.7 (0123456789ab, 2026-11-02T14:07:31Z) go1."
	if !strings.HasPrefix(string(out), want) {
		t.Errorf("got  %q\nwant prefix %q", out, want)
	}
}

// END ldflags OMIT
