package sweep_test

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/rahulbalajee/platform-go/internal/sweep"
	"github.com/rahulbalajee/platform-go/pkg/retry"
)

// START fake OMIT
// step is one scripted outcome of a probe attempt.
type step struct {
	detail string
	err    error
	took   time.Duration // simulated latency, spent in (virtual) time
}

// scriptedProber is a hand-written fake Prober. Each target follows its own
// script of outcomes, one per attempt, and the fake records when every
// attempt started so tests can assert on behaviour over time.
type scriptedProber struct {
	mu      sync.Mutex
	scripts map[string][]step
	starts  map[string][]time.Time
}

func newScriptedProber(scripts map[string][]step) *scriptedProber {
	return &scriptedProber{scripts: scripts, starts: map[string][]time.Time{}}
}

func (p *scriptedProber) Probe(ctx context.Context, t sweep.Target) (string, error) {
	p.mu.Lock()
	p.starts[t.Raw] = append(p.starts[t.Raw], time.Now())
	n, script := len(p.starts[t.Raw]), p.scripts[t.Raw]
	p.mu.Unlock()
	if n > len(script) {
		return "", retry.Permanent(fmt.Errorf("fake: no step %d for %s", n, t.Raw))
	}
	s := script[n-1]
	select {
	case <-time.After(s.took):
		return s.detail, s.err
	case <-ctx.Done():
		return "", context.Cause(ctx)
	}
}

// END fake OMIT

// Starts returns the start time of every attempt against target.
func (p *scriptedProber) Starts(target string) []time.Time {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]time.Time(nil), p.starts[target]...)
}

func runOnce(t *testing.T, cfg sweep.Config, inventory string) map[string]sweep.Result {
	t.Helper()
	runner, err := sweep.NewRunner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	targets, err := sweep.ParseTargets(strings.NewReader(inventory))
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]sweep.Result{}
	for r := range runner.Run(t.Context(), targets) {
		got[r.Target] = r
	}
	return got
}

// START retryafter OMIT
func TestRunnerHonoursRetryAfter(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		const target = "https://api.example.com/healthz"
		throttled := &sweep.StatusError{Code: 429}
		fake := newScriptedProber(map[string][]step{target: {
			{detail: "429", err: retry.After(3*time.Second, throttled)},
			{detail: "200 OK", took: 40 * time.Millisecond},
		}})
		got := runOnce(t, sweep.Config{
			Concurrency: 1, PerHost: 1, Timeout: time.Second,
			Retry:   retry.Policy{MaxAttempts: 3, MaxDelay: 10 * time.Second},
			Probers: map[sweep.Kind]sweep.Prober{sweep.KindHTTP: fake},
		}, target)

		if r := got[target]; r.Status != sweep.StatusUp || r.Attempts != 2 {
			t.Fatalf("got %s after %d attempts, want up after 2",
				r.Status, r.Attempts)
		}
		starts := fake.Starts(target)
		if gap := starts[1].Sub(starts[0]); gap != 3*time.Second {
			t.Errorf("retried after %v, want the 3s the server asked for", gap)
		}
	})
}

// END retryafter OMIT

// START ratelimit OMIT
func TestRunnerRateLimitSpacesAttempts(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		scripts := map[string][]step{}
		var inv strings.Builder
		for i := range 10 {
			target := fmt.Sprintf("tcp://host-%d.example.com:5432", i)
			scripts[target] = []step{{detail: "connected"}}
			inv.WriteString(target + "\n")
		}
		fake := newScriptedProber(scripts)
		start := time.Now()
		got := runOnce(t, sweep.Config{
			Concurrency: 10, PerHost: 1, Timeout: time.Second,
			Rate:    5, // attempts per second; burst = max(1, 5/10) = 1
			Probers: map[sweep.Kind]sweep.Prober{sweep.KindTCP: fake},
		}, inv.String())

		if len(got) != 10 {
			t.Fatalf("got %d results, want 10", len(got))
		}
		// One token up front, then one every 200ms: the tenth attempt
		// starts 1.8s in, however many checks are allowed to run at once.
		if el := time.Since(start); el != 1800*time.Millisecond {
			t.Errorf("10 attempts at 5/s took %v, want 1.8s", el)
		}
	})
}

// END ratelimit OMIT

func TestRunnerReportsUnknownKind(t *testing.T) {
	got := runOnce(t, sweep.Config{
		Concurrency: 1, PerHost: 1, Timeout: time.Second,
		Probers: map[sweep.Kind]sweep.Prober{},
	}, "dns://example.com")
	r := got["dns://example.com"]
	if r.Status != sweep.StatusDown || !strings.Contains(r.Error, `no prober for kind "dns"`) {
		t.Errorf("got %+v, want down with a missing-prober error", r)
	}
}

func TestScriptedProberRunsOutOfSteps(t *testing.T) {
	fake := newScriptedProber(map[string][]step{})
	_, err := fake.Probe(t.Context(), sweep.Target{Raw: "dns://x"})
	if err == nil || !strings.Contains(err.Error(), "no step 1") {
		t.Fatalf("err = %v, want a 'no step' error", err)
	}
}
