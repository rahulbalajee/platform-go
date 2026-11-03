// Command orphans shows what happens to a grandchild when a tool cancels
// the subprocess it started. Run it in a Linux container with an init
// process, so that orphans are re-parented to a PID 1 that reaps them:
//
//	docker run --rm --init pgo-ch05 /orphans -kill exec    # child only
//	docker run --rm --init pgo-ch05 /orphans -kill group   # procx: whole group
package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/procx"
	"github.com/rahulbalajee/platform-go/pkg/sysinfo"
)

func main() {
	role := flag.String("role", "", "internal: worker or sleeper")
	kill := flag.String("kill", "exec", "exec (exec.CommandContext) or group (procx)")
	flag.Parse()
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	switch *role {
	case "worker": // like a shell script: start a long job and wait for it
		_ = exec.Command(self, "-role=sleeper").Run() //nolint:gosec,noctx // demo
		return
	case "sleeper":
		time.Sleep(time.Hour)
		return
	}
	if err := run(self, *kill); err != nil {
		fmt.Fprintln(os.Stderr, "orphans:", err)
		os.Exit(1)
	}
}

// START run OMIT
func run(self, mode string) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var cmd interface {
		Start() error
		Wait() error
	}
	if mode == "group" {
		cmd = procx.Command(ctx, self, "-role=worker")
	} else {
		cmd = exec.CommandContext(ctx, self, "-role=worker") // Cancel: Kill()
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	time.Sleep(300 * time.Millisecond) // let the worker start its sleeper
	ps("before cancel")
	cancel()
	fmt.Println("Wait:", cmd.Wait())
	time.Sleep(200 * time.Millisecond)
	ps("after Wait returned")
	return nil
}

// END run OMIT

// ps prints the container's processes from /proc, like `ps -o
// pid,ppid,pgid,stat,args`, but without needing ps in the image.
func ps(title string) {
	procs, err := sysinfo.Processes(sysinfo.Host())
	if err != nil {
		fmt.Println(err)
		return
	}
	fmt.Printf("-- %s\n%5s %5s %5s %s  %s\n", title, "PID", "PPID", "PGID", "S", "COMMAND")
	for _, p := range procs {
		fmt.Printf("%5d %5d %5d %c  %s\n", p.PID, p.PPID, p.PGID, p.State, cmdline(p.PID))
	}
}

func cmdline(pid int) string {
	b, err := os.ReadFile(path.Join("/proc", strconv.Itoa(pid), "cmdline"))
	if err != nil || len(b) == 0 {
		return "?"
	}
	return strings.Join(strings.Split(string(bytes.TrimRight(b, "\x00")), "\x00"), " ")
}
