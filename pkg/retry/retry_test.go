package retry_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/retry"
)

var errFlaky = errors.New("flaky")

// START test OMIT
func TestDoRetriesUntilSuccessWithinBackoffCeiling(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := retry.Policy{
			MaxAttempts: 5,
			BaseDelay:   time.Second,
			MaxDelay:    10 * time.Second,
		}
		calls := 0
		start := time.Now() // fake clock: midnight UTC 2000-01-01

		err := p.Do(t.Context(), func(context.Context) error {
			if calls++; calls < 4 {
				return errFlaky
			}
			return nil
		})
		if err != nil {
			t.Fatalf("Do = %v, want nil", err)
		}
		if calls != 4 {
			t.Errorf("calls = %d, want 4", calls)
		}
		// Three sleeps with full jitter: each in (0, 1s], (0, 2s], (0, 4s].
		if el := time.Since(start); el <= 0 || el > 7*time.Second {
			t.Errorf("elapsed %v, want within (0, 7s]", el)
		}
	})
}

// END test OMIT

func TestDoStopsOnPermanent(t *testing.T) {
	calls := 0
	bad := errors.New("404 not found")
	err := retry.Policy{}.Do(t.Context(), func(context.Context) error {
		calls++
		return retry.Permanent(bad)
	})
	if !errors.Is(err, bad) || err.Error() != bad.Error() {
		t.Fatalf("err = %v, want the permanent error, unchanged", err)
	}
	if calls != 1 {
		t.Errorf("calls = %d, want 1", calls)
	}
}

func TestDoExhaustionWrapsLastError(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		err := retry.Policy{MaxAttempts: 3}.Do(t.Context(), func(context.Context) error {
			return errFlaky
		})
		ex, ok := errors.AsType[*retry.ExhaustedError](err)
		if !ok || ex.Attempts != 3 {
			t.Fatalf("err = %v, want ExhaustedError after 3 attempts", err)
		}
		if !errors.Is(err, errFlaky) {
			t.Error("ExhaustedError must wrap the last error")
		}
	})
}

func TestDoHonoursRetryAfter(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := retry.Policy{MaxAttempts: 2, BaseDelay: time.Millisecond, MaxDelay: time.Minute}
		start := time.Now()
		calls := 0
		_ = p.Do(t.Context(), func(context.Context) error {
			if calls++; calls == 1 {
				return retry.After(30*time.Second, errors.New("429 too many requests"))
			}
			return nil
		})
		if el := time.Since(start); el != 30*time.Second {
			t.Errorf("waited %v, want exactly the Retry-After of 30s", el)
		}
	})
}

func TestDoAbortsWhenContextEnds(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithTimeoutCause(t.Context(), 3*time.Second, errors.New("deploy window closed"))
		defer cancel()
		p := retry.Policy{MaxAttempts: 100, BaseDelay: time.Second, MaxDelay: time.Second}

		err := p.Do(ctx, func(context.Context) error { return errFlaky })
		if err == nil || !errors.Is(err, errFlaky) {
			t.Fatalf("err = %v, want it to wrap the last op error", err)
		}
		if got := err.Error(); !strings.Contains(got, "deploy window closed") {
			t.Errorf("err = %q, want it to carry the context cause", got)
		}
	})
}

func TestValueGenericMethod(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		calls := 0
		v, err := retry.Policy{}.Value(t.Context(), func(context.Context) (string, error) {
			if calls++; calls < 2 {
				return "", errFlaky
			}
			return "v1.42.0", nil
		})
		if err != nil || v != "v1.42.0" {
			t.Fatalf("Value = %q, %v", v, err)
		}
	})
}
