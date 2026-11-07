//go:build !windows

package main_test

// START imports OMIT

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// END imports OMIT
// START plugin OMIT

// installPlugin writes a shell-script plugin into a fresh PATH directory
// and returns the environment that puts it first on PATH.
func installPlugin(t *testing.T, name, script string) []string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "plat-"+name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
	return []string{"PATH=" + dir + string(os.PathListSeparator) + os.Getenv("PATH"),
		"HOME=" + t.TempDir(), "PLAT_CONFIG_DIR=" + t.TempDir()}
}

// The plugin gets its arguments, the environment and PLAT_BIN, and its
// exit status is plat's: on Unix, plat has become the plugin.
func TestPluginRuns(t *testing.T) {
	env := installPlugin(t, "db-backup", `echo "args: $*"
echo "bin: $PLAT_BIN"
exit 3
`)
	cmd := exec.Command(plat, "db", "backup", "--to", "s3://backups")
	cmd.Env = env
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	ee, ok := errors.AsType[*exec.ExitError](err)
	if !ok || ee.ExitCode() != 3 {
		t.Fatalf("exit: %v, want status 3", err)
	}
	want := "args: --to s3://backups\nbin: " + plat + "\n"
	if out.String() != want {
		t.Errorf("stdout:\n%s\nwant:\n%s", out.String(), want)
	}
}

// A plugin can't replace a built-in command, help included.
func TestBuiltinsWin(t *testing.T) {
	for _, name := range []string{"version", "help"} {
		env := installPlugin(t, name, "echo hijacked\n")
		cmd := exec.Command(plat, name)
		cmd.Env = env
		out, err := cmd.CombinedOutput()
		if err != nil || strings.Contains(string(out), "hijacked") {
			t.Errorf("plat %s ran the plugin (err %v):\n%s", name, err, out)
		}
	}
	env := installPlugin(t, "version", "echo hijacked\n")
	cmd := exec.Command(plat, "plugin", "list")
	cmd.Env = env
	out, _ := cmd.Output()
	if !strings.Contains(string(out), "never runs: 'plat version' is a built-in") {
		t.Errorf("plugin list does not warn about plat-version:\n%s", out)
	}
}

// END plugin OMIT
