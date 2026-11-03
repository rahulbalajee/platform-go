// Command zombies is meant to run as PID 1 in a container. It starts a
// child that launches three short-lived grandchildren and exits at once.
// The grandchildren are re-parented to PID 1; when they exit, they stay in
// the process table as zombies until PID 1 calls wait for them, and a Go
// program never does that for processes it did not start.
//
//	docker run --rm oskit /zombies          # Go binary is PID 1
//	docker run --rm --init oskit /zombies   # docker-init (tini) is PID 1
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"time"

	"oskit/sysinfo"
)

func main() {
	role := flag.String("role", "", "internal: spawner or short")
	flag.Parse()
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	switch *role {
	case "spawner": // start three jobs and exit without waiting for them
		for range 3 {
			_ = exec.Command(self, "-role=short").Start() //nolint:gosec,noctx // demo
		}
		return
	case "short":
		time.Sleep(200 * time.Millisecond)
		return
	}

	fmt.Printf("zombies is PID %d\n", os.Getpid())
	// Run reaps the spawner itself: os/exec always waits for its own child.
	spawner := exec.Command(self, "-role=spawner") //nolint:gosec,noctx // demo
	if err := spawner.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	time.Sleep(time.Second) // the grandchildren finish meanwhile

	procs, _ := sysinfo.Processes(sysinfo.Host())
	zombies := 0
	fmt.Printf("%5s %5s %s  %s\n", "PID", "PPID", "S", "COMM")
	for _, p := range procs {
		fmt.Printf("%5d %5d %c  %s\n", p.PID, p.PPID, p.State, p.Comm)
		if p.State == 'Z' {
			zombies++
		}
	}
	fmt.Printf("%d zombie(s)\n", zombies)
}
