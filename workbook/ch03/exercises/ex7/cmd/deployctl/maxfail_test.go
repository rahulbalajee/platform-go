package main

import (
	"errors"
	"strings"
	"testing"

	"deployctl/pkg/clierr"
)

// Exercise 3.7: -max-failures N stops starting targets once N have failed.
// Targets never started are skipped: reported, counted and re-runnable.
func TestMaxFailuresStopsTheRollout(t *testing.T) {
	cfg := fakeAPI(t, "us-east-1", "sa-east-1", "eu-west-1", "us-west-2")
	out, err := deployctl(t.Context(), token, "-config", cfg, "deploy",
		"-parallel", "1", "-max-failures", "1", "v1.4.2")
	e, ok := errors.AsType[*clierr.Error](err)
	if !ok || e.ID != "DPL-PARTIAL" || clierr.CodeOf(err) != clierr.ExitFailure {
		t.Fatalf("err = %v, want a DPL-PARTIAL failure", err)
	}
	want := "deploy of v1.4.2 failed on 1 of 4 targets; 2 skipped"
	if e.Message != want {
		t.Errorf("message = %q, want %q", e.Message, want)
	}
	only := "-only sa-east-1,eu-west-1,us-west-2"
	if !strings.HasSuffix(e.Hint, only) {
		t.Errorf("hint = %q, want it to end with %q", e.Hint, only)
	}
	if !errors.Is(err, ErrSkipped) {
		t.Errorf("errors.Is(err, ErrSkipped) = false for %v", err)
	}
	for _, want := range []string{"us-east-1   deployed", "sa-east-1   failed",
		"eu-west-1   skipped", "us-west-2   skipped"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
}

// Targets already running when the limit is reached finish normally. All
// three start at once, long before eu-west-1 fails (it is retried for a
// few hundred milliseconds first), so nothing is skipped.
func TestMaxFailuresLetsRunningTargetsFinish(t *testing.T) {
	cfg := fakeAPI(t, "eu-west-1", "us-east-1", "us-west-2")
	out, err := deployctl(t.Context(), token, "-config", cfg, "deploy",
		"-max-failures", "1", "v1.4.2")
	e, ok := errors.AsType[*clierr.Error](err)
	if !ok || e.Message != "deploy of v1.4.2 failed on 1 of 3 targets" {
		t.Fatalf("err = %v, want 1 of 3 failed and none skipped", err)
	}
	if strings.Contains(out, "skipped") || errors.Is(err, ErrSkipped) {
		t.Errorf("a target was skipped:\n%s", out)
	}
}

func TestMaxFailuresMustNotBeNegative(t *testing.T) {
	cfg := fakeAPI(t, "us-east-1")
	_, err := deployctl(t.Context(), token, "-config", cfg, "deploy",
		"-max-failures", "-1", "v1.4.2")
	if clierr.CodeOf(err) != clierr.ExitUsage {
		t.Errorf("err = %v, want a usage error", err)
	}
}
