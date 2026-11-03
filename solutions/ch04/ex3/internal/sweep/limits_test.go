package sweep_test

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"sweep/internal/sweep"
)

// START inventory OMIT
// inventory lists n targets on each of hosts hosts. If grouped, each host's
// targets are listed together; otherwise the hosts take turns.
func inventory(t *testing.T, hosts, n int, grouped bool) []sweep.Target {
	t.Helper()
	var b strings.Builder
	for i := range hosts * n {
		h, k := i%hosts, i/hosts
		if grouped {
			h, k = i/n, i%n
		}
		fmt.Fprintf(&b, "tcp://host-%d.example:443?%d\n", h, k)
	}
	ts, err := sweep.ParseTargets(strings.NewReader(b.String()))
	if err != nil {
		t.Fatal(err)
	}
	return ts
}

// END inventory OMIT

// START sweeptime OMIT
// sweepTime sweeps ts against fake targets that answer after latency, and
// returns how long the sweep took in virtual time.
func sweepTime(t *testing.T, cfg sweep.Config, ts []sweep.Target,
	latency time.Duration) time.Duration {

	t.Helper()
	var took time.Duration
	synctest.Test(t, func(t *testing.T) {
		answer := func(context.Context, sweep.Target) (string, error) {
			time.Sleep(latency)
			return "ok", nil
		}
		cfg.Timeout = time.Minute
		cfg.Probers = map[sweep.Kind]sweep.Prober{
			sweep.KindTCP: sweep.ProberFunc(answer),
		}
		runner, err := sweep.NewRunner(cfg)
		if err != nil {
			t.Fatal(err)
		}
		start, n := time.Now(), 0
		for range runner.Run(t.Context(), ts) {
			n++
		}
		took = time.Since(start)
		if n != len(ts) {
			t.Errorf("got %d results, want %d", n, len(ts))
		}
	})
	return took
}

// END sweeptime OMIT

// START scenarios OMIT
func TestWhichLimitBinds(t *testing.T) {
	ms := time.Millisecond
	defaults := sweep.Config{Concurrency: 32, PerHost: 4, Rate: 50}
	noRate := sweep.Config{Concurrency: 32, PerHost: 4} // Rate 0: no limit
	three := inventory(t, 3, 100, false)                // the hosts take turns
	grouped := inventory(t, 3, 100, true)               // host 0's targets first
	spread := inventory(t, 300, 1, false)               // 300 hosts, one target each
	single := inventory(t, 1, 200, false)               // 200 targets on one host
	for _, c := range []struct {
		name    string
		cfg     sweep.Config
		ts      []sweep.Target
		latency time.Duration
		want    time.Duration
	}{
		{"a: 3 hosts", defaults, three, 100 * ms, 6000 * ms},
		{"b: 3 hosts, -rate 0", noRate, three, 100 * ms, 2500 * ms},
		{"b, grouped by host", noRate, grouped, 100 * ms, 6100 * ms},
		{"c: 300 hosts, -rate 0", noRate, spread, 100 * ms, time.Second},
		{"d: 1 host, instant", defaults, single, 0, 3900 * ms},
	} {
		got := sweepTime(t, c.cfg, c.ts, c.latency)
		t.Logf("%-22s %v", c.name, got)
		if got != c.want {
			t.Errorf("%s: took %v, want %v", c.name, got, c.want)
		}
	}
}

// END scenarios OMIT
