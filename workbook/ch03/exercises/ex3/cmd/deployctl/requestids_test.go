package main

import (
	"errors"
	"regexp"
	"testing"

	"deployctl/pkg/clierr"
)

// Exercise 3.3: the hint of a partial failure quotes the request ID of
// every failed target, in the order the failures are listed.
func TestPartialHintQuotesEveryRequestID(t *testing.T) {
	cfg := fakeAPI(t, "us-east-1", "eu-west-1", "sa-east-1")
	_, err := deployctl(t.Context(), token, "-config", cfg, "deploy",
		"-parallel", "1", "v1.4.2")
	e, ok := errors.AsType[*clierr.Error](err)
	if !ok || e.ID != "DPL-PARTIAL" {
		t.Fatalf("err = %v, want a DPL-PARTIAL error", err)
	}
	ids := regexp.MustCompile(`-only eu-west-1,sa-east-1; ` +
		`quote (req-\w+), (req-\w+) if you ask for help$`).FindStringSubmatch(e.Hint)
	if ids == nil {
		t.Fatalf("hint = %q, want both request IDs after the -only advice", e.Hint)
	}
	apiErrs := clierr.All[*APIError](err)
	if len(apiErrs) != 2 || apiErrs[0].RequestID != ids[1] ||
		apiErrs[1].RequestID != ids[2] {
		t.Errorf("hint quotes %v, but the errors carry %v", ids[1:], apiErrs)
	}
}
