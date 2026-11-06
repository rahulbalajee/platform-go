// START helpers OMIT

//go:build unix

package procx_test

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"go.uber.org/goleak"

	"github.com/rahulbalajee/platform-go/pkg/procx"
)

// TestMain doubles as the child process for these tests (selected by
// PROCX_HELPER), so they need no shell, sleep or other external binaries.
func TestMain(m *testing.M) {
	if mode := os.Getenv("PROCX_HELPER"); mode != "" {
		helper(mode, os.Args[1:])
		os.Exit(0)
	}
	goleak.VerifyTestMain(m)
}

func helper(mode string, args []string) {
	switch mode {
	case "sleep":
		time.Sleep(time.Minute)
	case "tree", "tree-exit", "tree-pipe": // start a grandchild in our group
		gc := exec.Command(os.Args[0])
		gc.Env = append(os.Environ(), "PROCX_HELPER=sleep")
		if mode == "tree-pipe" {
			gc.Stdout = os.Stdout // the grandchild inherits our stdout pipe
		}
		if err := gc.Start(); err != nil {
			fmt.Println("error:", err)
			os.Exit(1)
		}
		fmt.Println(gc.Process.Pid)
		if mode == "tree" {
			time.Sleep(time.Minute)
		}
	case "stubborn": // ignores SIGTERM, like a process stuck in cleanup
		signal.Ignore(syscall.SIGTERM)
		fmt.Println("ready")
		time.Sleep(time.Minute)
	case "args":
		for _, a := range args {
			fmt.Printf("%q\n", a)
		}
	case "wait-usr1":
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGUSR1)
		fmt.Println("ready")
		select {
		case s := <-ch:
			fmt.Println("got", s)
		case <-time.After(10 * time.Second):
			fmt.Println("timeout")
		}
	}
}

// child returns a procx.Cmd that runs this test binary in helper mode.
func child(ctx context.Context, mode string, args ...string) *procx.Cmd {
	c := procx.Command(ctx, os.Args[0], args...)
	// GORACE: under -race, skip the 1s sleep the race runtime adds at exit.
	c.Env = append(os.Environ(), "PROCX_HELPER="+mode, "GORACE=atexit_sleep_ms=0")
	return c
}

// alive reports whether pid is a live (non-zombie) process.
func alive(pid int) bool {
	if syscall.Kill(pid, 0) != nil {
		return false
	}
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return true // no procfs (macOS): kill(pid, 0) is all we have
	}
	i := bytes.LastIndexByte(b, ')')
	return i < 0 || i+2 >= len(b) || b[i+2] != 'Z'
}

func waitGone(t *testing.T, pid int) {
	t.Helper()
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); {
		if !alive(pid) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = syscall.Kill(pid, syscall.SIGKILL)
	t.Fatalf("process %d is still running", pid)
}

// readLine reads one line from the child's stdout.
func readLine(t *testing.T, r io.Reader) string {
	t.Helper()
	line, err := bufio.NewReader(r).ReadString('\n')
	if err != nil {
		t.Fatalf("reading child output: %v", err)
	}
	return strings.TrimSpace(line)
}

// END helpers OMIT

// START test OMIT

func TestCancelKillsTheWholeGroup(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	cmd := child(ctx, "tree")
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	grandchild, _ := strconv.Atoi(readLine(t, out))

	cancel() // SIGTERM to the group: child and grandchild
	err = cmd.Wait()
	if got := procx.ExitCode(err); got != 128+int(syscall.SIGTERM) {
		t.Fatalf("exit code %d (%v), want 143", got, err)
	}
	waitGone(t, grandchild)
}

// END test OMIT

// START grace OMIT

func TestGraceEscalatesToSIGKILL(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	cmd := child(ctx, "stubborn")
	cmd.WaitDelay = 200 * time.Millisecond
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	readLine(t, out) // "ready": SIGTERM is now ignored

	start := time.Now()
	cancel()
	err = cmd.Wait()
	if got := procx.ExitCode(err); got != 128+int(syscall.SIGKILL) {
		t.Fatalf("exit code %d (%v), want 137", got, err)
	}
	took := time.Since(start)
	if took < 200*time.Millisecond || took > 3*time.Second {
		t.Fatalf("stopped after %v, want about the 200ms grace", took)
	}
}

func TestWaitKillsAbandonedDescendants(t *testing.T) {
	cmd := child(t.Context(), "tree-exit")
	out, err := cmd.Output() // exits 0 at once, leaving a sleeping grandchild
	if err != nil {
		t.Fatal(err)
	}
	grandchild, _ := strconv.Atoi(strings.TrimSpace(string(out)))
	waitGone(t, grandchild)
}

// TestWaitDoesNotHangOnInheritedPipes: with exec.Cmd alone, Output blocks
// until every process holding the stdout pipe exits, here for a minute.
func TestWaitDoesNotHangOnInheritedPipes(t *testing.T) {
	cmd := child(t.Context(), "tree-pipe")
	cmd.WaitDelay = 300 * time.Millisecond
	start := time.Now()
	out, err := cmd.Output()
	if !errors.Is(err, exec.ErrWaitDelay) {
		t.Fatalf("err = %v, want exec.ErrWaitDelay", err)
	}
	if took := time.Since(start); took > 3*time.Second {
		t.Fatalf("Output took %v", took)
	}
	grandchild, _ := strconv.Atoi(strings.TrimSpace(string(out)))
	waitGone(t, grandchild)
}

// END grace OMIT

// START misc OMIT

func TestArgumentsAreNotInterpretedByAShell(t *testing.T) {
	evil := `$(touch pwned); rm -rf "$HOME" #`
	out, err := child(t.Context(), "args", evil, "*").Output()
	if err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("%q\n%q\n", evil, "*")
	if string(out) != want {
		t.Fatalf("child saw %s, want %s", out, want)
	}
}

func TestForwardRelaysSignals(t *testing.T) {
	cmd := child(t.Context(), "wait-usr1")
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	r := bufio.NewReader(out)
	if line, _ := r.ReadString('\n'); line != "ready\n" {
		t.Fatalf("child said %q", line)
	}
	stop := cmd.Forward(syscall.SIGUSR1)
	defer stop()
	_ = syscall.Kill(os.Getpid(), syscall.SIGUSR1) // to us; Forward relays it
	line, _ := r.ReadString('\n')
	if err := cmd.Wait(); err != nil {
		t.Fatal(err)
	}
	if line != "got user defined signal 1\n" {
		t.Fatalf("child said %q", line)
	}
}

func TestExitCode(t *testing.T) {
	if got := procx.ExitCode(nil); got != 0 {
		t.Errorf("ExitCode(nil) = %d", got)
	}
	err := procx.Command(t.Context(), "/nonexistent/binary").Run()
	if got := procx.ExitCode(err); got != -1 {
		t.Errorf("ExitCode(start failure) = %d, want -1", got)
	}
	if !errors.Is(err, os.ErrNotExist) {
		t.Errorf("start failure %v should wrap os.ErrNotExist", err)
	}
}

// END misc OMIT
