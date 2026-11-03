// Package sysinfo reads facts about the current process and its container
// from Linux procfs and the cgroup v2 filesystem: effective memory, CPU and
// PID limits, current usage, and per-process state.
//
// Every reader takes an fs.FS rooted at "/". Production code passes Host();
// tests pass a testing/fstest.MapFS, so the parsing is tested on any OS.
package sysinfo

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"strconv"
	"strings"
)

// Host returns the real filesystem, rooted at "/".
func Host() fs.FS { return os.DirFS("/") }

// Unlimited is reported for a limit that is set to "max".
const Unlimited = -1

// ErrNoCgroupV2 means the process is not in a cgroup v2 hierarchy: the OS
// is not Linux, or the host still uses cgroup v1.
var ErrNoCgroupV2 = errors.New("no cgroup v2 hierarchy")

// cgroupRoot is where the unified hierarchy is mounted on every mainstream
// distribution and container runtime. (Fully general code would find it in
// /proc/self/mountinfo.)
const cgroupRoot = "sys/fs/cgroup"

// Cgroup describes the cgroup v2 group of the calling process. Limits are
// effective limits: the tightest value on the group or any ancestor the
// process can see.
type Cgroup struct {
	Path          string  // from /proc/self/cgroup; "/" in a container's namespace
	MemoryMax     int64   // bytes, or Unlimited
	MemoryHigh    int64   // throttling threshold in bytes, or Unlimited
	MemoryCurrent int64   // bytes charged to the group now
	MemoryPeak    int64   // high-water mark (Linux 5.19+), 0 if unknown
	CPUs          float64 // cpu.max quota/period; 0 means no limit
	PidsMax       int64   // or Unlimited
	PidsCurrent   int64
}

// START cgroup OMIT
// ReadCgroup reads the limits and usage of the calling process's cgroup.
func ReadCgroup(fsys fs.FS) (Cgroup, error) {
	rel, err := selfCgroup(fsys)
	if err != nil {
		return Cgroup{}, err
	}
	cg := Cgroup{
		Path: rel, MemoryMax: Unlimited, MemoryHigh: Unlimited, PidsMax: Unlimited,
	}
	dir := path.Join(cgroupRoot, rel)
	cg.MemoryCurrent, _ = readValue(fsys, dir, "memory.current")
	cg.MemoryPeak, _ = readValue(fsys, dir, "memory.peak")
	cg.PidsCurrent, _ = readValue(fsys, dir, "pids.current")

	// A limit on any ancestor applies to us too, so walk up to the root.
	for d := dir; ; d = path.Dir(d) {
		tighten(&cg.MemoryMax, fsys, d, "memory.max")
		tighten(&cg.MemoryHigh, fsys, d, "memory.high")
		tighten(&cg.PidsMax, fsys, d, "pids.max")
		if cpus, err := readCPUMax(fsys, d); err == nil && cpus > 0 {
			if cg.CPUs == 0 || cpus < cg.CPUs {
				cg.CPUs = cpus
			}
		}
		if d == cgroupRoot {
			return cg, nil
		}
	}
}

// END cgroup OMIT

// selfCgroup returns the v2 path from /proc/self/cgroup ("0::/some/path").
func selfCgroup(fsys fs.FS) (string, error) {
	b, err := fs.ReadFile(fsys, "proc/self/cgroup")
	if err != nil {
		return "", fmt.Errorf("%w: %w", ErrNoCgroupV2, err)
	}
	for line := range strings.Lines(string(b)) {
		if p, ok := strings.CutPrefix(strings.TrimSpace(line), "0::"); ok {
			if _, err := fs.Stat(fsys, path.Join(cgroupRoot, p)); err != nil {
				return "", fmt.Errorf("%w: %w", ErrNoCgroupV2, err)
			}
			return p, nil
		}
	}
	return "", ErrNoCgroupV2
}

// readValue parses a single-value cgroup file: a number or "max".
func readValue(fsys fs.FS, dir, file string) (int64, error) {
	b, err := fs.ReadFile(fsys, path.Join(dir, file))
	if err != nil {
		return 0, err
	}
	s := strings.TrimSpace(string(b))
	if s == "max" {
		return Unlimited, nil
	}
	return strconv.ParseInt(s, 10, 64)
}

// tighten lowers *limit to the value in dir/file if that is smaller.
func tighten(limit *int64, fsys fs.FS, dir, file string) {
	v, err := readValue(fsys, dir, file)
	if err != nil || v == Unlimited {
		return
	}
	if *limit == Unlimited || v < *limit {
		*limit = v
	}
}

// readCPUMax parses cpu.max ("$QUOTA $PERIOD", microseconds) into CPUs.
func readCPUMax(fsys fs.FS, dir string) (float64, error) {
	b, err := fs.ReadFile(fsys, path.Join(dir, "cpu.max"))
	if err != nil {
		return 0, err
	}
	quota, period, ok := strings.Cut(strings.TrimSpace(string(b)), " ")
	if !ok {
		return 0, fmt.Errorf("malformed cpu.max %q", b)
	}
	if quota == "max" {
		return 0, nil
	}
	q, err1 := strconv.ParseFloat(quota, 64)
	p, err2 := strconv.ParseFloat(period, 64)
	if err := errors.Join(err1, err2); err != nil || p == 0 {
		return 0, fmt.Errorf("malformed cpu.max %q: %w", b, err)
	}
	return q / p, nil
}
