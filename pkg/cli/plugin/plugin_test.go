//go:build !windows

package plugin_test

// START imports OMIT

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/rahulbalajee/platform-go/pkg/cli/plugin"
)

// END imports OMIT
// START find OMIT

// write creates an executable (or, with mode 0o644, a plain file) in dir.
func write(t *testing.T, dir, name string, mode os.FileMode) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"), mode); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestFind(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	hello := write(t, a, "plat-hello", 0o755)
	shadowed := write(t, b, "plat-hello", 0o755)
	backup := write(t, b, "plat-db-backup", 0o755)
	write(t, a, "plat-notes.txt", 0o644) // not executable
	write(t, a, "kubectl-hello", 0o755)  // another tool's plugin
	if err := os.Mkdir(filepath.Join(a, "plat-dir"), 0o755); err != nil {
		t.Fatal(err)
	}
	cwd := t.TempDir()
	write(t, cwd, "plat-evil", 0o755)
	t.Chdir(cwd)

	path := strings.Join([]string{a, "", ".", b, "/does/not/exist"},
		string(os.PathListSeparator))
	got := plugin.Find("plat", path)
	want := []plugin.Plugin{
		{Name: "hello", Path: hello, Shadows: []string{shadowed}},
		{Name: "db-backup", Path: backup},
	}
	if !slices.EqualFunc(got, want, func(x, y plugin.Plugin) bool {
		return x.Name == y.Name && x.Path == y.Path &&
			slices.Equal(x.Shadows, y.Shadows)
	}) {
		t.Errorf("Find:\n got %+v\nwant %+v", got, want)
	}
}

// END find OMIT
// START lookup OMIT

func TestLookupPrefersTheLongestName(t *testing.T) {
	plugins := []plugin.Plugin{{Name: "db"}, {Name: "db-backup"}}
	for _, tc := range []struct {
		args       []string
		name, rest string
		ok         bool
	}{
		{[]string{"db", "backup", "now"}, "db-backup", "now", true},
		{[]string{"db", "restore"}, "db", "restore", true},
		{[]string{"db", "--backup"}, "db", "--backup", true},
		// After a flag, words are arguments, never part of the name.
		{[]string{"db", "-v", "backup"}, "db", "-v backup", true},
		{[]string{"nope"}, "", "", false},
	} {
		p, rest, ok := plugin.Lookup(plugins, tc.args)
		if ok != tc.ok || p.Name != tc.name || strings.Join(rest, " ") != tc.rest {
			t.Errorf("Lookup(%q) = %q %q %v, want %q %q %v", tc.args,
				p.Name, rest, ok, tc.name, tc.rest, tc.ok)
		}
	}
}

// END lookup OMIT
