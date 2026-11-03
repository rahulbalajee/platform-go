// START imports OMIT

package sysinfo_test

import (
	"testing"
	"testing/fstest"

	"oskit/sysinfo"
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
