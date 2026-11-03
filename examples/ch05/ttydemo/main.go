// Command ttydemo runs the same child program twice, first with its stdout
// connected to a pipe and then to a pseudo-terminal, and prints exactly the
// bytes the parent received each time.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/creack/pty"
)

func main() {
	child := flag.Bool("child", false, "act as the child program")
	flag.Parse()
	if *child {
		runChild()
		return
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "ttydemo:", err)
		os.Exit(1)
	}
}

// START child OMIT
// runChild behaves like many CLIs: colour and a redrawn progress line when
// a person is watching, plain lines otherwise.
func runChild() {
	if !isTerminal(os.Stdout) {
		fmt.Println("stdout is not a terminal")
		fmt.Println("deployed 3/3")
		return
	}
	rows, cols, _ := pty.Getsize(os.Stdout)
	fmt.Printf("stdout is a terminal, %dx%d, TERM=%s\n",
		cols, rows, os.Getenv("TERM"))
	for i := 1; i <= 3; i++ {
		fmt.Printf("\rdeploying %d/3", i) // \r: redraw the same line
		time.Sleep(50 * time.Millisecond)
	}
	fmt.Print("\r\x1b[32mdeployed 3/3\x1b[0m\n") // green
}

// END child OMIT

// START run OMIT
func run() error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	// Both runs start this same binary, so gosec's G204 does not apply.
	out, err := exec.Command(self, "-child").Output() //nolint:gosec,noctx
	if err != nil {
		return err
	}
	show("pipe", out)

	cmd := exec.Command(self, "-child") //nolint:gosec,noctx
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 40, Cols: 120})
	if err != nil {
		return err
	}
	defer ptmx.Close()
	out, err = io.ReadAll(ptmx)
	// Linux reports EIO, not EOF, once the child side of the pty is closed.
	if err != nil && !errors.Is(err, syscall.EIO) {
		return err
	}
	show("pty", out)
	return cmd.Wait()
}

// END run OMIT

func show(via string, out []byte) {
	fmt.Printf("via %s:\n", via)
	for line := range strings.Lines(string(out)) {
		fmt.Printf("  %q\n", line)
	}
}
