//go:build unix

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"deployctl/internal/fakeapi"
)

var update = flag.Bool("update", false, "rewrite testdata/*.golden")

// START testmain OMIT
// binary is the deployctl executable built once for the whole package.
var binary string

// TestMain builds the real binary, so the tests below see exactly what a
// shell or a CI runner sees: bytes on stderr and an exit status.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "deployctl-test-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binary = filepath.Join(dir, "deployctl")
	build := exec.Command("go", "build", "-o", binary, ".")
	build.Stderr = os.Stderr
	code := 1
	if err := build.Run(); err == nil {
		code = m.Run()
	}
	_ = os.RemoveAll(dir)
	os.Exit(code)
}

// END testmain OMIT

// env is a working directory with a config pointing at a fake API.
type env struct {
	dir string
	api string
}

func newEnv(t *testing.T, opts fakeapi.Options) env {
	t.Helper()
	srv := httptest.NewServer(fakeapi.New(opts))
	t.Cleanup(srv.Close)
	e := env{dir: t.TempDir(), api: srv.URL}
	e.config(t, "prod.json", "us-east-1", "us-west-2", "eu-west-1", "sa-east-1")
	e.config(t, "staging.json", "us-east-1", "ap-south-1")
	return e
}

func (e env) config(t *testing.T, name string, targets ...string) {
	t.Helper()
	data, _ := json.Marshal(Config{API: e.api, Service: "checkout", Targets: targets})
	if err := os.WriteFile(filepath.Join(e.dir, name), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

// command returns deployctl with args, run in the env's directory with a
// valid token and crash reports going to a temporary directory.
func (e env) command(t *testing.T, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(t.Context(), binary, args...)
	cmd.Dir = e.dir
	cmd.Env = append(os.Environ(), "DEPLOYCTL_TOKEN="+fakeapi.Token,
		"TMPDIR="+e.dir)
	return cmd
}

// START exitcode OMIT
// exitCode runs cmd and returns its exit status and stderr. A process
// killed by a signal reports -1 from ExitCode; that is a test failure.
func exitCode(t *testing.T, cmd *exec.Cmd) (int, string) {
	t.Helper()
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	if exitErr, ok := errors.AsType[*exec.ExitError](err); ok {
		return exitErr.ExitCode(), stderr.String()
	}
	if err != nil {
		t.Fatalf("running %v: %v", cmd.Args, err) // could not even start it
	}
	return 0, stderr.String()
}

// END exitcode OMIT

// START table OMIT
func TestExitCodes(t *testing.T) {
	e := newEnv(t, fakeapi.Options{Slow: 5 * time.Second})
	tests := []struct {
		name   string
		args   []string
		env    []string
		code   int
		golden string // compare stderr with testdata/<golden>.golden
		want   string // or just require this substring
	}{
		{"help", []string{"-h"}, nil, 0, "", ""},
		{"bad flag", []string{"-config", "prod.json", "deploy", "-parallel=many",
			"v1"}, nil, 2, "badflag", ""},
		{"unknown command", []string{"deplyo"}, nil, 2, "",
			`unknown command "deplyo"`},
		{"missing config", []string{"deploy", "v1"}, nil, 2, "noconfig", ""},
		{"no token", []string{"-config", "prod.json", "deploy", "v1"},
			[]string{"DEPLOYCTL_TOKEN="}, 77, "", "DEPLOYCTL_TOKEN is not set"},
		{"bad token", []string{"-config", "prod.json", "deploy", "v1"},
			[]string{"DEPLOYCTL_TOKEN=expired"}, 77, "", "rejected your token"},
		{"partial", []string{"-config", "prod.json", "deploy", "-parallel", "1",
			"v1.4.2"}, nil, 1, "partial", ""},
		{"timeout", []string{"-config", "staging.json", "deploy", "-timeout",
			"300ms", "v1.4.2"}, nil, 75, "timeout", ""},
		{"ok", []string{"-config", "prod.json", "deploy", "-only", "us-east-1",
			"v1.4.2"}, nil, 0, "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cmd := e.command(t, tt.args...)
			cmd.Env = append(cmd.Env, tt.env...)
			code, stderr := exitCode(t, cmd)
			if code != tt.code {
				t.Errorf("exit code = %d, want %d; stderr:\n%s",
					code, tt.code, stderr)
			}
			if tt.golden != "" {
				checkGolden(t, tt.golden, stderr)
			}
			if !strings.Contains(stderr, tt.want) {
				t.Errorf("stderr lacks %q:\n%s", tt.want, stderr)
			}
		})
	}
}

// END table OMIT

func checkGolden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("testdata", name+".golden")
	if *update {
		if err := os.WriteFile(path, []byte(got), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != string(want) {
		t.Errorf("stderr differs from %s (-update to accept):\ngot:\n%s\nwant:\n%s",
			path, got, want)
	}
}

// START crash OMIT
func TestPanicWritesCrashReportNotStack(t *testing.T) {
	e := newEnv(t, fakeapi.Options{})
	code, stderr := exitCode(t, e.command(t, "-config", "staging.json", "status"))
	if code != 70 {
		t.Fatalf("exit code = %d, want 70; stderr:\n%s", code, stderr)
	}
	if strings.Contains(stderr, "goroutine ") {
		t.Errorf("stack trace dumped on the user:\n%s", stderr)
	}
	crashes, _ := filepath.Glob(filepath.Join(e.dir, "deployctl-crash-*.txt"))
	fatal, _ := filepath.Glob(filepath.Join(e.dir, "deployctl-fatal-*.txt"))
	if len(crashes) != 1 || len(fatal) != 0 {
		t.Fatalf("crash reports = %v, fatal files = %v; want 1 and 0", crashes, fatal)
	}
	report, _ := os.ReadFile(crashes[0])
	if !bytes.Contains(report, []byte("main.status")) {
		t.Errorf("crash report lacks the panicking function:\n%s", report)
	}
}

// END crash OMIT

// START interrupt OMIT
func TestInterruptExits130(t *testing.T) {
	e := newEnv(t, fakeapi.Options{Slow: 10 * time.Second})
	cmd := e.command(t, "-config", "staging.json", "deploy", "v1.4.2")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	// Wait until us-east-1 is done and ap-south-1 is in flight, then Ctrl-C.
	lines := bufio.NewScanner(stdout)
	for lines.Scan() && !strings.Contains(lines.Text(), "us-east-1") {
	}
	_ = cmd.Process.Signal(syscall.SIGINT)
	_, _ = io.Copy(io.Discard, stdout)

	err = cmd.Wait()
	exitErr, ok := errors.AsType[*exec.ExitError](err)
	if !ok || exitErr.ExitCode() != 130 {
		t.Fatalf("wait = %v, want exit status 130; stderr:\n%s", err, &stderr)
	}
	if !strings.Contains(stderr.String(), "1 of 2 targets not updated") {
		t.Errorf("stderr should say what was left undone:\n%s", &stderr)
	}
}

// END interrupt OMIT

func TestUnreadableConfigIsPermissionDenied(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read anything")
	}
	e := newEnv(t, fakeapi.Options{})
	if err := os.Chmod(filepath.Join(e.dir, "prod.json"), 0o000); err != nil {
		t.Fatal(err)
	}
	code, stderr := exitCode(t, e.command(t, "-config", "prod.json", "deploy", "v1"))
	if code != 77 || !strings.Contains(stderr, "cannot read config file") {
		t.Errorf("exit code = %d, want 77; stderr:\n%s", code, stderr)
	}
}

func TestJSONErrorsAreMachineReadable(t *testing.T) {
	e := newEnv(t, fakeapi.Options{})
	code, stderr := exitCode(t, e.command(t, "-o", "json", "deploy", "v1"))
	var doc struct {
		Error struct {
			ExitCode int    `json:"exit_code"`
			ID       string `json:"id"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(stderr), &doc); err != nil {
		t.Fatalf("stderr is not one JSON document: %v\n%s", err, stderr)
	}
	if code != 2 || doc.Error.ExitCode != 2 || doc.Error.ID != "DPL-CONFIG" {
		t.Errorf("code = %d, doc = %+v", code, doc)
	}
}
