// START imports OMIT

//go:build linux

package sysinfo_test

import (
	"errors"
	"os"
	"strconv"
	"testing"

	"github.com/rahulbalajee/platform-go/pkg/sysinfo"
)

// END imports OMIT

// START proc OMIT
// These tests read the real /proc and /sys/fs/cgroup of the test process.
// They only compile on Linux; run them in CI, or in a container.

func TestRealProcSelf(t *testing.T) {
	st, err := sysinfo.ReadStat(sysinfo.Host(), "self")
	if err != nil {
		t.Fatal(err)
	}
	if st.PID != os.Getpid() || st.PPID != os.Getppid() {
		t.Fatalf("stat = %+v, want pid %d ppid %d",
			st, os.Getpid(), os.Getppid())
	}
	// State is the main thread's, and it is usually asleep while another
	// thread runs this test, so accept S as well as R.
	if st.State != 'R' && st.State != 'S' {
		t.Errorf("State = %q, want R or S", st.State)
	}
	if st.Threads < 2 {
		t.Errorf("Threads = %d; the Go runtime always runs several", st.Threads)
	}
}

func TestRealProcesses(t *testing.T) {
	ps, err := sysinfo.Processes(sysinfo.Host())
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range ps {
		if p.PID == os.Getpid() {
			return
		}
	}
	t.Fatalf("own PID %d not among %d processes", os.Getpid(), len(ps))
}

// END proc OMIT

// START cgroup OMIT
func TestRealStatusAndFDs(t *testing.T) {
	status, err := sysinfo.ReadStatus(sysinfo.Host(), strconv.Itoa(os.Getpid()))
	if err != nil || status.Bytes("VmRSS") <= 0 {
		t.Fatalf("VmRSS = %d, %v", status.Bytes("VmRSS"), err)
	}
	n, err := sysinfo.CountFDs(sysinfo.Host(), "self")
	if err != nil || n < 3 {
		t.Fatalf("CountFDs = %d, %v; want at least stdin, stdout, stderr", n, err)
	}
}

func TestRealCgroup(t *testing.T) {
	cg, err := sysinfo.ReadCgroup(sysinfo.Host())
	if errors.Is(err, sysinfo.ErrNoCgroupV2) {
		t.Skip("host has no cgroup v2:", err)
	}
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("%+v", cg)
	if cg.MemoryCurrent <= 0 && cg.Path != "/" {
		t.Errorf("memory.current = %d", cg.MemoryCurrent)
	}
	if cg.MemoryMax != sysinfo.Unlimited && cg.MemoryMax < cg.MemoryCurrent {
		t.Errorf("memory.max %d below memory.current %d",
			cg.MemoryMax, cg.MemoryCurrent)
	}
}

// END cgroup OMIT
