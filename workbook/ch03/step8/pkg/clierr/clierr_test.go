// START imports OMIT
package clierr_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"testing"

	"go.uber.org/goleak"

	"deployctl/pkg/clierr"
)

// END imports OMIT
// START testmain OMIT
func TestMain(m *testing.M) { goleak.VerifyTestMain(m) }

// END testmain OMIT
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
		// START codeofsignal OMIT
		{"sigint", &clierr.SignalError{Signal: syscall.SIGINT}, 130},
		{"sigterm", &clierr.SignalError{Signal: syscall.SIGTERM}, 143},
		// END codeofsignal OMIT
		// START codeofpanic OMIT
		{"panic beats all", errors.Join(usage, &clierr.PanicError{Value: 1}),
			clierr.ExitInternal},
		// END codeofpanic OMIT
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
		// START goldenjson OMIT
		{"partial.json", true},
		// END goldenjson OMIT
	} {
		t.Run(tc.name, func(t *testing.T) {
			var stderr bytes.Buffer
			p := &clierr.Program{Name: "deployctl", Stderr: &stderr, JSON: tc.json}
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
// START signal OMIT
func TestSignalCauseDecidesCode(t *testing.T) {
	ctx, cancel := context.WithCancelCause(t.Context())
	cancel(&clierr.SignalError{Signal: syscall.SIGTERM})

	var stderr bytes.Buffer
	p := &clierr.Program{Name: "x", Stderr: &stderr}
	code := p.Run(ctx, func(ctx context.Context) error {
		return fmt.Errorf("upload: %w", ctx.Err()) // a bare context.Canceled
	})
	if code != 143 {
		t.Errorf("code = %d, want 143 (128 + SIGTERM)", code)
	}
}

// END signal OMIT
// START panic OMIT
func TestPanicBecomesCrashReport(t *testing.T) {
	dir := t.TempDir()
	var stderr bytes.Buffer
	p := &clierr.Program{Name: "x", Stderr: &stderr, CrashDir: dir,
		BugURL: "https://example.com/issues"}
	code := p.Run(t.Context(), func(context.Context) error {
		counts := func() map[string]int { return nil }
		counts()["boom"]++ // assignment to entry in nil map
		return nil
	})
	if code != clierr.ExitInternal {
		t.Fatalf("code = %d, want %d", code, clierr.ExitInternal)
	}
	if strings.Contains(stderr.String(), "goroutine ") {
		t.Errorf("stack trace leaked to the user:\n%s", &stderr)
	}
	files, _ := filepath.Glob(filepath.Join(dir, "x-crash-*.txt"))
	if len(files) != 1 {
		t.Fatalf("crash files = %v, want exactly one", files)
	}
	report, _ := os.ReadFile(files[0])
	for _, want := range []string{"nil map", "goroutine ", "go:           go1."} {
		if !strings.Contains(string(report), want) {
			t.Errorf("crash report lacks %q:\n%s", want, report)
		}
	}
	if !strings.Contains(stderr.String(), files[0]) {
		t.Errorf("stderr does not point at %s:\n%s", files[0], &stderr)
	}
}

// END panic OMIT
// START safe OMIT
func TestSafeCarriesPanicsAcrossGoroutines(t *testing.T) {
	errs := make([]error, 3)
	var wg sync.WaitGroup
	for i := range errs {
		wg.Go(func() {
			errs[i] = clierr.Safe(func() error {
				if i == 1 {
					var p *struct{ n int }
					p.n++ // nil pointer dereference on a worker goroutine
				}
				return nil
			})
		})
	}
	wg.Wait()

	err := errors.Join(errs...)
	pe, ok := errors.AsType[*clierr.PanicError](err)
	if !ok {
		t.Fatalf("err = %v, want a *PanicError in the tree", err)
	}
	if _, ok := errors.AsType[runtime.Error](err); !ok {
		t.Errorf("PanicError should unwrap to the runtime.Error")
	}
	if !bytes.Contains(pe.Stack, []byte("TestSafeCarriesPanicsAcrossGoroutines")) {
		t.Errorf("stack lacks the panicking function:\n%s", pe.Stack)
	}
	if clierr.CodeOf(err) != clierr.ExitInternal {
		t.Errorf("CodeOf = %d, want %d", clierr.CodeOf(err), clierr.ExitInternal)
	}
}

// END safe OMIT
// START fallback OMIT
func TestCrashFallsBackToStderr(t *testing.T) {
	var stderr bytes.Buffer
	p := &clierr.Program{Name: "x", Stderr: &stderr,
		CrashDir: filepath.Join(t.TempDir(), "missing")}
	code := p.Run(t.Context(), func(context.Context) error { panic("boom") })
	if code != clierr.ExitInternal {
		t.Fatalf("code = %d, want %d", code, clierr.ExitInternal)
	}
	if !strings.Contains(stderr.String(), "could not save a crash report") ||
		!strings.Contains(stderr.String(), "goroutine ") {
		t.Errorf("want the stack on stderr when no file can be written:\n%s",
			&stderr)
	}
}

// END fallback OMIT
// START logrecord OMIT
func TestLogRecordForOperators(t *testing.T) {
	var log bytes.Buffer
	p := &clierr.Program{Name: "x", Stderr: &bytes.Buffer{},
		Logger: slog.New(slog.NewJSONHandler(&log, nil))}
	p.Run(t.Context(), func(context.Context) error { return partial() })

	var rec struct {
		Msg      string   `json:"msg"`
		ExitCode int      `json:"exit_code"`
		ErrorID  string   `json:"error_id"`
		Error    string   `json:"error"`
		Chain    []string `json:"chain"`
	}
	if err := json.Unmarshal(log.Bytes(), &rec); err != nil {
		t.Fatalf("log is not one JSON record: %v\n%s", err, &log)
	}
	if rec.ExitCode != 1 || rec.ErrorID != "DPL-PARTIAL" {
		t.Errorf("record = %+v", rec)
	}
	if !strings.Contains(rec.Error, "503 Service Unavailable") {
		t.Errorf("operator log lost the cause chain: %q", rec.Error)
	}
	if len(rec.Chain) == 0 || rec.Chain[0] != "*clierr.Error" {
		t.Errorf("chain = %v", rec.Chain)
	}
}

// END logrecord OMIT
// START secret OMIT
func TestSecretNeverPrints(t *testing.T) {
	tok := clierr.Secret("ghp_live_0123456789")
	var log bytes.Buffer
	slog.New(slog.NewJSONHandler(&log, nil)).Info("login", "token", tok)
	js, _ := json.Marshal(struct{ Token clierr.Secret }{tok})

	for _, out := range []string{
		fmt.Sprintf("%v %s %q %x %#v %+v", tok, tok, tok, tok, tok, tok),
		fmt.Sprint(tok),
		fmt.Errorf("auth with %v: %w", tok, errors.New("401")).Error(),
		log.String(),
		string(js),
	} {
		if strings.Contains(out, string(tok)) {
			t.Errorf("secret leaked: %s", out)
		}
	}
}

// END secret OMIT
