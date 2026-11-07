//go:build !windows

package main_test

// START imports OMIT

import (
	"bytes"
	"io"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/creack/pty"

	"github.com/rahulbalajee/platform-go/internal/platformd"
)

// END imports OMIT
// START main OMIT

// plat is the binary under test, built once for all tests.
var plat string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "plat-test")
	if err != nil {
		panic(err)
	}
	plat = filepath.Join(dir, "plat")
	build := exec.Command("go", "build", "-o", plat, ".")
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		panic(err)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// server starts a development platform without authentication and returns
// the environment a plat process needs to use it, and nothing of the
// developer's own configuration.
func server(t *testing.T) []string {
	t.Helper()
	h := &lateHandler{}
	hs := httptest.NewServer(h)
	t.Cleanup(hs.Close)
	srv, err := platformd.New(platformd.Options{Issuer: hs.URL, Auth: "none"})
	if err != nil {
		t.Fatal(err)
	}
	h.srv.Store(srv)
	return []string{"PLAT_SERVER=" + hs.URL, "PLAT_CONFIG_DIR=" + t.TempDir(),
		"HOME=" + t.TempDir(), "TERM=xterm-256color", "PATH=" + os.Getenv("PATH")}
}

// END main OMIT
// START tty OMIT

// On a real terminal plat colours states and shows relative times; through
// a pipe the same command prints timestamps and no escape codes. This runs
// the binary under a pseudo-terminal, so the detection itself is tested,
// not a flag a test set.
func TestTerminalAndPipeOutput(t *testing.T) {
	env := server(t)

	cmd := exec.Command(plat, "deployments", "list", "-L", "2")
	cmd.Env = env
	tty, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 24, Cols: 100})
	if err != nil {
		t.Fatal(err)
	}
	onTTY, _ := io.ReadAll(tty) // ends with EIO when the child exits
	_ = cmd.Wait()
	if !bytes.Contains(onTTY, []byte("\x1b[32msucceeded\x1b[0m")) ||
		!bytes.Contains(onTTY, []byte(" ago")) {
		t.Errorf("on a terminal: want colour and relative times:\n%q", onTTY)
	}

	cmd = exec.Command(plat, "deployments", "list", "-L", "2")
	cmd.Env = env
	piped, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(piped, []byte("\x1b[")) ||
		!bytes.Contains(piped, []byte("2026-09-04T10:00:00Z")) {
		t.Errorf("in a pipe: want timestamps and no escapes:\n%q", piped)
	}
}

// END tty OMIT
// START watch OMIT

// The full-screen watch starts on a terminal, draws the list, and quits on
// q with exit status 0, restoring the screen.
func TestWatchOnATerminal(t *testing.T) {
	env := server(t)
	cmd := exec.Command(plat, "deployments", "watch", "--interval", "200ms")
	cmd.Env = env
	tty, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 24, Cols: 100})
	if err != nil {
		t.Fatal(err)
	}
	defer tty.Close()
	screen := &syncBuffer{}
	go func() { _, _ = io.Copy(screen, tty) }()

	waitFor(t, screen, "d-8")
	if _, err := tty.Write([]byte("q")); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("watch exited with %v after q", err)
		}
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("watch did not exit after q")
	}
	// 1049 is the alternate screen: entered on start, left on exit.
	if s := screen.String(); !strings.Contains(s, "\x1b[?1049h") ||
		!strings.Contains(s, "\x1b[?1049l") {
		t.Errorf("alternate screen not entered and left:\n%q", s)
	}
}

// END watch OMIT

func waitFor(t *testing.T, b *syncBuffer, s string) {
	t.Helper()
	for range 100 {
		if strings.Contains(b.String(), s) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("%q never appeared:\n%q", s, b.String())
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}
