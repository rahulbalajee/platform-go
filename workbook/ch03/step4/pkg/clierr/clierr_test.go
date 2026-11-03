// START imports OMIT
package clierr_test

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"testing"

	"deployctl/pkg/clierr"
)

// END imports OMIT
// START fixtures OMIT
var update = flag.Bool("update", false, "rewrite testdata/*.golden")

// netTimeout behaves like a *net.OpError for an i/o timeout.
type netTimeout struct{}

func (netTimeout) Error() string { return "read tcp 10.0.0.1:443: i/o timeout" }
func (netTimeout) Timeout() bool { return true }

// gaveUp is how a retry helper reports its last failure: a type of its
// own that wraps the cause.
type gaveUp struct{ last error }

func (g *gaveUp) Error() string { return "gave up: " + g.last.Error() }
func (g *gaveUp) Unwrap() error { return g.last }

// END fixtures OMIT
// START codeof OMIT
func TestCodeOf(t *testing.T) {
	usage := &clierr.Error{Code: clierr.ExitUsage, Message: "bad flag"}
	tests := []struct {
		name string
		err  error
		want clierr.Code
	}{
		{"nil", nil, clierr.ExitOK},
		{"help", fmt.Errorf("parse: %w", flag.ErrHelp), clierr.ExitOK},
		{"plain", errors.New("boom"), clierr.ExitFailure},
		{"explicit", usage, clierr.ExitUsage},
		{"wrapped", fmt.Errorf("deploy: %w", usage), clierr.ExitUsage},
		{"joined", errors.Join(errors.New("a"), usage), clierr.ExitUsage},
		{"zero code infers", &clierr.Error{Err: netTimeout{}}, clierr.ExitTempFail},
		{"explicit beats inferred",
			&clierr.Error{Code: clierr.ExitFailure, Err: netTimeout{}},
			clierr.ExitFailure},
		{"deadline", fmt.Errorf("x: %w", context.DeadlineExceeded),
			clierr.ExitTempFail},
		{"behaviour", fmt.Errorf("get: %w", netTimeout{}), clierr.ExitTempFail},
		{"retry wrapper", &gaveUp{last: netTimeout{}}, clierr.ExitTempFail},
		{"permission",
			&fs.PathError{Op: "open", Path: "/etc/x", Err: fs.ErrPermission},
			clierr.ExitNoPerm},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := clierr.CodeOf(tt.err); got != tt.want {
				t.Errorf("CodeOf(%v) = %d (%v), want %d (%v)",
					tt.err, got, got, tt.want, tt.want)
			}
		})
	}
}

// END codeof OMIT
// START partial OMIT
// partial is the multi-target failure used by the golden tests.
func partial() error {
	return &clierr.Error{
		Code:    clierr.ExitFailure,
		ID:      "DPL-PARTIAL",
		Message: "deploy of v1.4.2 failed on 2 of 3 targets",
		Hint:    "re-run with -only eu-west-1,sa-east-1",
		Err: errors.Join(
			&clierr.Error{Message: "eu-west-1: health check failing (HTTP 503)",
				Err: errors.New("POST /deploy: 503 Service Unavailable")},
			fmt.Errorf("sa-east-1: %w", errors.New("deploy already in progress")),
		),
	}
}

// END partial OMIT
// START golden OMIT
// TestReportGolden pins the exact text people and scripts see. Run
// `go test -update` in this package after an intended change, and review
// the diff of testdata/*.golden like any other code change.
func TestReportGolden(t *testing.T) {
	for _, tc := range []struct {
		name string
		json bool
	}{
		{"partial.text", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var stderr bytes.Buffer
			p := &clierr.Program{Name: "deployctl", Stderr: &stderr}
			code := p.Run(t.Context(), func(context.Context) error {
				return partial()
			})
			if code != clierr.ExitFailure {
				t.Fatalf("code = %d, want %d", code, clierr.ExitFailure)
			}
			golden := filepath.Join("testdata", tc.name+".golden")
			if *update {
				if err := os.WriteFile(golden, stderr.Bytes(), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			want, err := os.ReadFile(golden)
			if err != nil {
				t.Fatal(err)
			}
			if got := stderr.String(); got != string(want) {
				t.Errorf("stderr mismatch (-update to accept)\ngot:\n%s\nwant:\n%s",
					got, want)
			}
		})
	}
}

// END golden OMIT
// START help OMIT
func TestHelpIsSilentSuccess(t *testing.T) {
	var stderr bytes.Buffer
	p := &clierr.Program{Name: "x", Stderr: &stderr}
	code := p.Run(t.Context(), func(context.Context) error { return flag.ErrHelp })
	if code != clierr.ExitOK || stderr.Len() != 0 {
		t.Fatalf("code = %d, stderr = %q; want 0 and nothing printed", code, &stderr)
	}
}

// END help OMIT
