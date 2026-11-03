package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestScenarios(t *testing.T) {
	for scenario, want := range map[string][]string{
		"pages":  {"d-8  checkout  staging", "requests sent: 2"},
		"deploy": {"4/4 replicas updated", "| d-9 state: succeeded"},
		"flaky":  {"after 4 attempts", "status=429 wait=1s", "op-10, then op-10"},
		"errors": {
			"ErrNotFound)=true", "ErrConflict)=true", "still in_progress",
			"rollout_failed",
		},
	} {
		t.Run(scenario, func(t *testing.T) {
			var out bytes.Buffer
			if err := run(t.Context(), scenario, &out); err != nil {
				t.Fatal(err)
			}
			for _, w := range want {
				if !strings.Contains(out.String(), w) {
					t.Errorf("output lacks %q:\n%s", w, out.String())
				}
			}
		})
	}
	if err := run(t.Context(), "nope", &bytes.Buffer{}); err == nil {
		t.Error("unknown scenario accepted")
	}
}
