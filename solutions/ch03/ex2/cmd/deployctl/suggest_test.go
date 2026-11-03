package main

import (
	"errors"
	"strings"
	"testing"

	"deployctl/pkg/clierr"
)

// Exercise 3.2: an unknown command close to a real one gets a suggestion
// at the start of its hint; the advice to run -h stays.
func TestUnknownCommandSuggestsTheClosest(t *testing.T) {
	for _, tt := range []struct{ typed, want string }{
		{"deplyo", `did you mean "deploy"?`},
		{"stauts", `did you mean "status"?`},
		{"int", `did you mean "init"?`},
		{"frobnicate", ""}, // nothing is close: no suggestion
	} {
		t.Run(tt.typed, func(t *testing.T) {
			_, err := deployctl(t.Context(), token, tt.typed)
			e, ok := errors.AsType[*clierr.Error](err)
			if !ok || clierr.CodeOf(err) != clierr.ExitUsage {
				t.Fatalf("err = %v, want a usage error", err)
			}
			if !strings.Contains(e.Message, `unknown command "`+tt.typed+`"`) {
				t.Errorf("message = %q", e.Message)
			}
			if !strings.Contains(e.Hint, `run "deployctl -h" for usage`) {
				t.Errorf("hint = %q, want it to keep the -h advice", e.Hint)
			}
			if tt.want == "" {
				if strings.Contains(e.Hint, "did you mean") {
					t.Errorf("hint = %q, want no suggestion", e.Hint)
				}
				return
			}
			if !strings.HasPrefix(e.Hint, tt.want) {
				t.Errorf("hint = %q, want it to start with %q", e.Hint, tt.want)
			}
		})
	}
}
