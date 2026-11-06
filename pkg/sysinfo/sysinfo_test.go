// START imports OMIT

package sysinfo_test

import (
	"errors"
	"testing"
	"testing/fstest"

	"github.com/rahulbalajee/platform-go/pkg/sysinfo"
)

// END imports OMIT

// START stat OMIT

func file(s string) *fstest.MapFile { return &fstest.MapFile{Data: []byte(s)} }

func TestReadStatHostileComm(t *testing.T) {
	// A process can name itself anything (prctl PR_SET_NAME), including
	// text that looks like the end of the comm field.
	line := "4242 (evil) S 1 2 3) R 1 4242 4242 0 -1 4194560 120 0 0 0 " +
		"3 1 0 0 20 0 7 0 98765 1234567 512 18446744073709551615\n"
	fsys := fstest.MapFS{"proc/4242/stat": file(line)}
	st, err := sysinfo.ReadStat(fsys, "4242")
	if err != nil {
		t.Fatal(err)
	}
	want := sysinfo.Stat{
		PID: 4242, PPID: 1, PGID: 4242, SID: 4242, Comm: "evil) S 1 2 3",
		State: 'R', Threads: 7, StartTime: 98765, RSSPages: 512,
	}
	if st != want {
		t.Fatalf("got  %+v\nwant %+v", st, want)
	}
}

func TestProcessesSkipsNonPIDs(t *testing.T) {
	stat := func(pid, comm string) *fstest.MapFile {
		const rest = ") S 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5 0 0"
		return file(pid + " (" + comm + rest)
	}
	fsys := fstest.MapFS{
		"proc/1/stat":    stat("1", "init"),
		"proc/77/stat":   stat("77", "worker"),
		"proc/self/stat": stat("77", "worker"),
		"proc/meminfo":   file("MemTotal: 1 kB\n"),
	}
	ps, err := sysinfo.Processes(fsys)
	if err != nil {
		t.Fatal(err)
	}
	if len(ps) != 2 || ps[0].Comm != "init" || ps[1].PID != 77 {
		t.Fatalf("got %+v", ps)
	}
}

// END stat OMIT

// START status OMIT

func TestStatusBytes(t *testing.T) {
	fsys := fstest.MapFS{"proc/self/status": file(
		"Name:\tlimits\nVmHWM:\t    5120 kB\nVmRSS:\t    4096 kB\nThreads:\t5\n")}
	st, err := sysinfo.ReadStatus(fsys, "self")
	if err != nil {
		t.Fatal(err)
	}
	if st.Bytes("VmRSS") != 4096*1024 || st["Threads"] != "5" {
		t.Fatalf("got %v", st)
	}
}

// END status OMIT

// START fstest OMIT

// A container started with --memory=256m --cpus=1.5 --pids-limit=100, as
// its own cgroup namespace shows it: the group is the root of the tree.
func containerFS() fstest.MapFS {
	return fstest.MapFS{
		"proc/self/cgroup":                 file("0::/\n"),
		"sys/fs/cgroup/memory.max":         file("268435456\n"),
		"sys/fs/cgroup/memory.high":        file("max\n"),
		"sys/fs/cgroup/memory.current":     file("4415488\n"),
		"sys/fs/cgroup/memory.peak":        file("5005312\n"),
		"sys/fs/cgroup/cpu.max":            file("150000 100000\n"),
		"sys/fs/cgroup/pids.max":           file("100\n"),
		"sys/fs/cgroup/pids.current":       file("3\n"),
		"sys/fs/cgroup/cgroup.controllers": file("cpu memory pids\n"),
	}
}

func TestReadCgroupInContainer(t *testing.T) {
	cg, err := sysinfo.ReadCgroup(containerFS())
	if err != nil {
		t.Fatal(err)
	}
	want := sysinfo.Cgroup{
		Path: "/", MemoryMax: 256 << 20, MemoryHigh: sysinfo.Unlimited,
		MemoryCurrent: 4415488, MemoryPeak: 5005312, CPUs: 1.5,
		PidsMax: 100, PidsCurrent: 3,
	}
	if cg != want {
		t.Fatalf("got  %+v\nwant %+v", cg, want)
	}
}

// END fstest OMIT

// START ancestor OMIT

// TestReadCgroupTakesTightestAncestor: a systemd service in a slice. The
// slice caps memory at 1 GiB and the service sets 2 GiB, so 1 GiB wins;
// CPU is limited only on the service.
func TestReadCgroupTakesTightestAncestor(t *testing.T) {
	const svc = "sys/fs/cgroup/batch.slice/job.service/"
	fsys := fstest.MapFS{
		"proc/self/cgroup":                     file("0::/batch.slice/job.service\n"),
		"sys/fs/cgroup/cgroup.controllers":     file("cpu memory\n"),
		"sys/fs/cgroup/batch.slice/memory.max": file("1073741824\n"),
		"sys/fs/cgroup/batch.slice/cpu.max":    file("max 100000\n"),
		svc + "memory.max":                     file("2147483648\n"),
		svc + "cpu.max":                        file("50000 100000\n"),
		svc + "memory.current":                 file("1048576\n"),
	}
	cg, err := sysinfo.ReadCgroup(fsys)
	if err != nil {
		t.Fatal(err)
	}
	if cg.MemoryMax != 1<<30 || cg.CPUs != 0.5 || cg.PidsMax != sysinfo.Unlimited {
		t.Fatalf("got %+v", cg)
	}
}

func TestReadCgroupV1Host(t *testing.T) {
	fsys := fstest.MapFS{
		"proc/self/cgroup": file("12:memory:/docker/abc\n" +
			"11:cpu,cpuacct:/docker/abc\n"),
	}
	if _, err := sysinfo.ReadCgroup(fsys); !errors.Is(err, sysinfo.ErrNoCgroupV2) {
		t.Fatalf("err = %v, want ErrNoCgroupV2", err)
	}
	_, err := sysinfo.ReadCgroup(fstest.MapFS{})
	if !errors.Is(err, sysinfo.ErrNoCgroupV2) {
		t.Fatalf("empty fs: err = %v, want ErrNoCgroupV2", err)
	}
}

// END ancestor OMIT
