package sysinfo_test

import (
	"strings"
	"testing"

	"oskit/sysinfo"
)

const mib = 1 << 20

func TestGoMemLimitUsesMemoryMax(t *testing.T) {
	t.Setenv("GOMEMLIMIT", "")
	cg := sysinfo.Cgroup{MemoryMax: 256 * mib, MemoryHigh: sysinfo.Unlimited}
	limit, why := sysinfo.GoMemLimit(cg, 0.9)
	if limit != 241591910 || !strings.Contains(why, "memory.max") {
		t.Fatalf("GoMemLimit = %d, %q; want 241591910 and a reason naming memory.max",
			limit, why)
	}
}

func TestGoMemLimitPrefersALowerMemoryHigh(t *testing.T) {
	t.Setenv("GOMEMLIMIT", "")
	cg := sysinfo.Cgroup{MemoryMax: 256 * mib, MemoryHigh: 200 * mib}
	limit, why := sysinfo.GoMemLimit(cg, 0.5)
	if limit != 100*mib || !strings.Contains(why, "memory.high") {
		t.Fatalf("GoMemLimit = %d, %q; want %d and a reason naming memory.high",
			limit, why, 100*mib)
	}
	cg.MemoryHigh = 512 * mib // above memory.max: memory.max still decides
	if limit, _ := sysinfo.GoMemLimit(cg, 0.5); limit != 128*mib {
		t.Fatalf("memory.high above memory.max: limit = %d, want %d", limit, 128*mib)
	}
}

func TestGoMemLimitLeavesTheRuntimeAlone(t *testing.T) {
	const unlimited = sysinfo.Unlimited
	limited := sysinfo.Cgroup{MemoryMax: 256 * mib, MemoryHigh: unlimited}
	none := sysinfo.Cgroup{MemoryMax: unlimited, MemoryHigh: unlimited}
	tests := []struct {
		name, env, want string
		cg              sysinfo.Cgroup
		ratio           float64
	}{
		{"no limit", "", "no memory limit", none, 0.9},
		{"explicit GOMEMLIMIT", "100MiB", "GOMEMLIMIT", limited, 0.9},
		{"ratio zero", "", "ratio", limited, 0},
		{"ratio above one", "", "ratio", limited, 1.5},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("GOMEMLIMIT", tc.env)
			limit, why := sysinfo.GoMemLimit(tc.cg, tc.ratio)
			if limit != 0 || !strings.Contains(why, tc.want) {
				t.Fatalf("GoMemLimit = %d, %q; want 0 and a reason mentioning %q",
					limit, why, tc.want)
			}
		})
	}
}
