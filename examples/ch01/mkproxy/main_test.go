package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"
)

func TestSplitModuleFile(t *testing.T) {
	tests := []struct {
		name    string
		mv      modVersion
		rel     string
		wantMod bool
	}{
		{"example.com/codec@v1.4.0/go.mod", modVersion{"example.com/codec", "v1.4.0"}, "go.mod", true},
		{"example.com/codec/v2@v2.0.0/x/y.go", modVersion{"example.com/codec/v2", "v2.0.0"}, "x/y.go", true},
		{"app/go.mod", modVersion{}, "", false},
		{"example.com/codec@latest/go.mod", modVersion{}, "", false},
		{"example.com/codec@v1.4.0", modVersion{}, "", false},
	}
	for _, tt := range tests {
		mv, rel, ok := splitModuleFile(tt.name)
		if ok != tt.wantMod || mv != tt.mv || rel != tt.rel {
			t.Errorf("splitModuleFile(%q) = %v, %q, %v", tt.name, mv, rel, ok)
		}
	}
}

func TestParseTxtar(t *testing.T) {
	got := parseTxtar([]byte("comment\n-- a.txt --\nhello\n-- dir/b.txt --\n-- c --\nx\ny\n"))
	want := []file{
		{"a.txt", []byte("hello\n")},
		{"dir/b.txt", nil},
		{"c", []byte("x\ny\n")},
	}
	if diff := cmp.Diff(want, got, cmp.AllowUnexported(file{})); diff != "" {
		t.Errorf("parseTxtar (-want +got):\n%s", diff)
	}
}

func TestBuildRejectsBadArchives(t *testing.T) {
	for name, files := range map[string][]file{
		"escape":     {{"../evil", []byte("x")}},
		"no go.mod":  {{"example.com/m@v1.0.0/m.go", []byte("package m\n")}},
		"upper case": {{"example.com/Big@v1.0.0/go.mod", []byte("module example.com/Big\n")}},
	} {
		if err := build(t.TempDir(), files); err == nil {
			t.Errorf("%s: build succeeded, want error", name)
		}
	}
}

func TestRunUsage(t *testing.T) {
	var stderr bytes.Buffer
	if code := run(nil, &stderr); code != 2 {
		t.Errorf("run() = %d, want 2", code)
	}
}

// TestUniverseResolves serves the chapter's universe through the go command
// itself, so the demo in the book cannot drift from what the toolchain does.
func TestUniverseResolves(t *testing.T) {
	if testing.Short() {
		t.Skip("runs the go command")
	}
	dir := t.TempDir()
	var stderr bytes.Buffer
	if code := run([]string{"-o", dir, "universe.txtar"}, &stderr); code != 0 {
		t.Fatalf("mkproxy: exit %d: %s", code, stderr.String())
	}
	list, err := os.ReadFile(filepath.Join(dir, "proxy/example.com/codec/@v/list"))
	if err != nil {
		t.Fatal(err)
	}
	if got := string(list); got != "v1.3.0\nv1.4.0\nv1.5.0\nv1.5.1\n" {
		t.Errorf("codec @v/list = %q", got)
	}

	cmd := exec.CommandContext(t.Context(), "go", "list", "-m", "all")
	cmd.Dir = filepath.Join(dir, "app")
	cmd.Env = append(os.Environ(),
		"GOPROXY=file://"+filepath.ToSlash(filepath.Join(dir, "proxy")),
		"GONOSUMDB=example.com",
		"GOMODCACHE="+filepath.Join(dir, "modcache"),
		"GOFLAGS=-modcacherw -mod=mod",
		"GOTOOLCHAIN=local",
		"GOWORK=off",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go list: %v\n%s", err, out)
	}
	want := "example.com/app\n" +
		"example.com/codec v1.4.0\n" + // the maximum of the minimums
		"example.com/codec/v2 v2.0.0\n" + // a different module path
		"example.com/log v1.2.0\n" +
		"example.com/metrics v1.2.0\n"
	if !strings.HasSuffix(string(out), want) {
		t.Errorf("go list -m all:\n%s\nwant suffix:\n%s", out, want)
	}
}
