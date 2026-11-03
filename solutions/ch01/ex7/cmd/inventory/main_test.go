package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
)

// fleet builds a directory of binaries the way a release pipeline leaves
// them: stamp for this machine, stamp for linux/amd64, the buildinfo test
// binary (which links github.com/google/go-cmp v0.7.0), and a file that is
// not a Go binary at all.
func fleet(t *testing.T) string {
	t.Helper()
	if testing.Short() {
		t.Skip("builds binaries")
	}
	dir := t.TempDir()
	build := func(env []string, args ...string) {
		t.Helper()
		cmd := exec.CommandContext(t.Context(), "go", args...)
		cmd.Env = append(os.Environ(), env...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("go %v: %v\n%s", args, err, out)
		}
	}
	build(nil, "build", "-buildvcs=false",
		"-o", filepath.Join(dir, "stamp"), "../stamp")
	build([]string{"GOOS=linux", "GOARCH=amd64", "CGO_ENABLED=0"},
		"build", "-buildvcs=false",
		"-o", filepath.Join(dir, "linux", "stamp"), "../stamp")
	build(nil, "test", "-c", "-buildvcs=false",
		"-o", filepath.Join(dir, "buildinfo.test"), "../../buildinfo")
	notes := filepath.Join(dir, "notes.txt")
	if err := os.WriteFile(notes, []byte("hi\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

// rows runs inventory and returns the fields of each output line after
// the header, which it checks.
func rows(t *testing.T, args ...string) [][]string {
	t.Helper()
	var out, errb bytes.Buffer
	if code := run(args, &out, &errb); code != 0 {
		t.Fatalf("inventory %v: exit %d\n%s", args, code, errb.String())
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	header := strings.Fields(lines[0])
	want := []string{"BINARY", "VERSION", "GO", "PLATFORM", "MODIFIED"}
	if !slices.Equal(header[:min(len(header), 5)], want) {
		t.Fatalf("header = %q, want it to start with %q", lines[0], want)
	}
	var rs [][]string
	for _, l := range lines[1:] {
		rs = append(rs, strings.Fields(l))
	}
	return rs
}

func TestInventory(t *testing.T) {
	dir := fleet(t)
	native := runtime.GOOS + "/" + runtime.GOARCH
	got := rows(t, dir)
	want := [][]string{
		{"buildinfo.test", "(devel)", runtime.Version(), native, "-"},
		{"linux/stamp", "(devel)", runtime.Version(), "linux/amd64", "-"},
		{"stamp", "(devel)", runtime.Version(), native, "-"},
	}
	if !slices.EqualFunc(got, want, slices.Equal) {
		t.Errorf("inventory %s:\n got %q\nwant %q", dir, got, want)
	}
}

func TestInventoryModuleFilter(t *testing.T) {
	dir := fleet(t)
	got := rows(t, "-module", "github.com/google/go-cmp", dir)
	var cmp []string
	for _, r := range got {
		cmp = append(cmp, r[0]+"="+r[len(r)-1])
	}
	want := []string{"buildinfo.test=v0.7.0", "linux/stamp=-", "stamp=-"}
	if !slices.Equal(cmp, want) {
		t.Errorf("-module column: got %q, want %q", cmp, want)
	}

	got = rows(t, "-module", "github.com/google/go-cmp", "-older", "v0.8.0", dir)
	if len(got) != 1 || got[0][0] != "buildinfo.test" {
		t.Errorf("-older v0.8.0: got %q, want only buildinfo.test", got)
	}
	got = rows(t, "-module", "github.com/google/go-cmp", "-older", "v0.7.0", dir)
	if len(got) != 0 {
		t.Errorf("-older v0.7.0: got %q, want no rows (equal is not older)", got)
	}
}

func TestInventoryUsage(t *testing.T) {
	for _, args := range [][]string{
		{},                                     // no directory
		{"-older", "v1.0.0", "."},              // -older needs -module
		{"-module", "m", "-older", "1.0", "."}, // not a semantic version
	} {
		var out, errb bytes.Buffer
		if code := run(args, &out, &errb); code != 2 {
			t.Errorf("inventory %q: exit %d, want 2", args, code)
		}
	}
}
