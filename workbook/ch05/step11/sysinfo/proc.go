// START imports OMIT

// Package sysinfo reads what the Linux kernel knows about processes and
// containers: process state from procfs, and memory, CPU and PID limits
// from the cgroup v2 file system.
//
// Every reader takes an fs.FS rooted at "/". Production code passes Host();
// tests pass a testing/fstest.MapFS, so the parsing is tested on any OS.
package sysinfo

import (
	"bytes"
	"cmp"
	"fmt"
	"io/fs"
	"os"
	"path"
	"slices"
	"strconv"
	"strings"
)

// Host returns the real file system, rooted at "/".
func Host() fs.FS { return os.DirFS("/") }

// END imports OMIT

// START stat OMIT
// Stat is the parsed /proc/<pid>/stat line: the kernel's record of a process.
type Stat struct {
	PID, PPID int
	PGID, SID int    // process group and session
	Comm      string // executable name (15 bytes max); may contain " " and ")"
	State     byte   // R running, S sleeping, D disk wait, Z zombie, T stopped
	Threads   int
	StartTime uint64 // clock ticks after boot; (PID, StartTime) is unique
	RSSPages  int64
}

func parseStat(b []byte) (Stat, error) {
	// comm sits in parentheses and can itself contain ") ", so the only safe
	// split point is the LAST ')' on the line.
	lp, rp := bytes.IndexByte(b, '('), bytes.LastIndexByte(b, ')')
	if lp < 0 || rp < lp {
		return Stat{}, fmt.Errorf("malformed stat line %q", b)
	}
	f := strings.Fields(string(b[rp+1:])) // f[0] is field 3 in proc(5)
	if len(f) < 22 {
		return Stat{}, fmt.Errorf("short stat line %q", b)
	}
	p := statParser{}
	s := Stat{
		PID:       p.int(strings.TrimSpace(string(b[:lp]))),
		Comm:      string(b[lp+1 : rp]),
		State:     f[0][0],
		PPID:      p.int(f[1]),
		PGID:      p.int(f[2]),
		SID:       p.int(f[3]),
		Threads:   p.int(f[17]),
		StartTime: uint64(p.int64(f[19])), //nolint:gosec // never negative
		RSSPages:  p.int64(f[21]),
	}
	return s, p.err
}

// END stat OMIT

// START readstat OMIT
// ReadStat parses /proc/<pid>/stat. Use pid "self" for the caller.
func ReadStat(fsys fs.FS, pid string) (Stat, error) {
	b, err := fs.ReadFile(fsys, path.Join("proc", pid, "stat"))
	if err != nil {
		return Stat{}, err
	}
	return parseStat(b)
}

// statParser parses integers and remembers the first error.
type statParser struct{ err error }

func (p *statParser) int64(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil && p.err == nil {
		p.err = fmt.Errorf("stat field %q: %w", s, err)
	}
	return n
}

func (p *statParser) int(s string) int { return int(p.int64(s)) }

// Processes returns the stat records of every process in /proc, ordered by
// PID. Processes that exit between the directory listing and the read are
// skipped, which is a race every ps implementation has to handle.
func Processes(fsys fs.FS) ([]Stat, error) {
	ents, err := fs.ReadDir(fsys, "proc")
	if err != nil {
		return nil, err
	}
	var out []Stat
	for _, e := range ents {
		if _, err := strconv.Atoi(e.Name()); err != nil || !e.IsDir() {
			continue // not a PID: "self", "meminfo", "sys", ...
		}
		st, err := ReadStat(fsys, e.Name())
		if err != nil {
			continue // gone already, or unreadable
		}
		out = append(out, st)
	}
	slices.SortFunc(out, func(a, b Stat) int { return cmp.Compare(a.PID, b.PID) })
	return out, nil
}

// END readstat OMIT
