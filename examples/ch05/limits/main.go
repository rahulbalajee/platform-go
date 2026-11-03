// Command limits prints the resource limits this process really runs under:
// cgroup v2 memory, CPU and PID limits, what the Go runtime derived from
// them, and the process's file-descriptor limit.
//
// Run it inside a container to see the container's limits:
//
//	docker run --rm --cpus=1.5 --memory=256m pgo-ch05 /limits
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"runtime"
	"runtime/debug"
	"syscall"
	"text/tabwriter"

	"github.com/rahulbalajee/platform-go/pkg/sysinfo"
)

func main() {
	setMem := flag.Bool("set-memlimit", false,
		"if GOMEMLIMIT is unset, set the Go memory limit to 90% of memory.max")
	exhaust := flag.Bool("exhaust-fds", false,
		"open files until the descriptor limit is hit, then report")
	flag.Parse()
	if *exhaust {
		exhaustFDs()
		return
	}
	if err := run(os.Stdout, *setMem); err != nil {
		fmt.Fprintln(os.Stderr, "limits:", err)
		os.Exit(1)
	}
}

func run(stdout io.Writer, setMem bool) error {
	w := tabwriter.NewWriter(stdout, 0, 0, 2, ' ', 0)
	defer w.Flush()

	cg, err := sysinfo.ReadCgroup(sysinfo.Host())
	switch {
	case errors.Is(err, sysinfo.ErrNoCgroupV2):
		fmt.Fprintf(w, "cgroup v2\tnot available on %s\n", runtime.GOOS)
	case err != nil:
		return err
	default:
		fmt.Fprintf(w, "cgroup v2 path\t%s\n", cg.Path)
		fmt.Fprintf(w, "memory.max\t%s\n", size(cg.MemoryMax))
		fmt.Fprintf(w, "memory.high\t%s\n", size(cg.MemoryHigh))
		fmt.Fprintf(w, "memory.current\t%s (peak %s)\n",
			size(cg.MemoryCurrent), size(cg.MemoryPeak))
		fmt.Fprintf(w, "cpu.max\t%s\n", cpus(cg.CPUs))
		fmt.Fprintf(w, "pids.max\t%s (current %d)\n", count(cg.PidsMax), cg.PidsCurrent)
	}

	fmt.Fprintf(w, "GOMAXPROCS\t%d (runtime.NumCPU %d)\n",
		runtime.GOMAXPROCS(0), runtime.NumCPU())
	if setMem && err == nil {
		if limit, ok := memLimitFor(cg); ok {
			debug.SetMemoryLimit(limit)
		}
	}
	fmt.Fprintf(w, "GOMEMLIMIT\t%s\n", size(debug.SetMemoryLimit(-1)))

	soft, hard, err := sysinfo.NoFile()
	if err != nil {
		return err
	}
	fmt.Fprintf(w, "RLIMIT_NOFILE\t%d soft, %d hard\n", soft, hard)

	if st, err := sysinfo.ReadStatus(sysinfo.Host(), "self"); err == nil {
		fds, _ := sysinfo.CountFDs(sysinfo.Host(), "self")
		fmt.Fprintf(w, "this process\t%d threads, %d open fds, VmRSS %s\n",
			atoi(st["Threads"]), fds, size(st.Bytes("VmRSS")))
	}
	return nil
}

// START memlimit OMIT
// memLimitFor returns a Go soft memory limit for the cgroup: 90% of
// memory.max, leaving headroom for memory the Go runtime does not manage
// (cgo, the binary's own text, kernel buffers charged to the cgroup).
// An explicit GOMEMLIMIT always wins.
func memLimitFor(cg sysinfo.Cgroup) (int64, bool) {
	if os.Getenv("GOMEMLIMIT") != "" || cg.MemoryMax == sysinfo.Unlimited {
		return 0, false
	}
	return cg.MemoryMax / 10 * 9, true
}

// END memlimit OMIT

// START exhaust OMIT
// exhaustFDs leaks descriptors the way a missing Close does, one per
// "request", until open fails.
func exhaustFDs() {
	soft, _, _ := sysinfo.NoFile()
	var leaked []*os.File
	for {
		f, err := os.Open("/proc/self/status")
		if err != nil {
			fmt.Printf("RLIMIT_NOFILE %d: opened %d files, then: %v\n",
				soft, len(leaked), err)
			fmt.Printf("errors.Is(err, syscall.EMFILE) = %v\n",
				errors.Is(err, syscall.EMFILE))
			return
		}
		leaked = append(leaked, f) // never closed
	}
}

// END exhaust OMIT

func size(b int64) string {
	switch b {
	case sysinfo.Unlimited, math.MaxInt64:
		return "unlimited"
	case 0:
		return "0"
	}
	return fmt.Sprintf("%.1f MiB", float64(b)/(1<<20))
}

func count(n int64) string {
	if n == sysinfo.Unlimited {
		return "unlimited"
	}
	return fmt.Sprint(n)
}

func cpus(c float64) string {
	if c == 0 {
		return "unlimited"
	}
	return fmt.Sprintf("%.2f CPUs", c)
}

func atoi(s string) int {
	var n int
	_, _ = fmt.Sscan(s, &n)
	return n
}
