package sysinfo

import (
	"fmt"
	"os"
)

// START memlimit OMIT
// GoMemLimit suggests a Go soft memory limit (for debug.SetMemoryLimit) for
// a process in cgroup cg: ratio times the cgroup's memory limit, where the
// limit is memory.max, or memory.high when that is lower, because the
// kernel starts throttling and reclaiming at memory.high. It returns 0 when
// the runtime should be left alone, and always says why.
func GoMemLimit(cg Cgroup, ratio float64) (limit int64, reason string) {
	if v := os.Getenv("GOMEMLIMIT"); v != "" {
		return 0, "GOMEMLIMIT=" + v + " is set explicitly"
	}
	if ratio <= 0 || ratio > 1 {
		return 0, fmt.Sprintf("ratio %v is outside (0, 1]", ratio)
	}
	base, source := cg.MemoryMax, "memory.max"
	if cg.MemoryHigh != Unlimited && (base == Unlimited || cg.MemoryHigh < base) {
		base, source = cg.MemoryHigh, "memory.high"
	}
	if base == Unlimited {
		return 0, "no memory limit in the cgroup"
	}
	limit = int64(float64(base) * ratio)
	return limit, fmt.Sprintf("%.0f%% of %s (%d bytes)", ratio*100, source, base)
}

// END memlimit OMIT
