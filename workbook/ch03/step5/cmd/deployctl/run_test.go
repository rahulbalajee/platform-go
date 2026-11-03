// START imports OMIT
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"deployctl/internal/fakeapi"
	"deployctl/pkg/clierr"
)

// END imports OMIT
// START helpers OMIT
// fakeAPI starts the fake deployment API and writes a config file that
// deploys to targets through it. It returns the config file's path.
func fakeAPI(t *testing.T, targets ...string) string {
	t.Helper()
	api := fakeapi.New(fakeapi.Options{Fast: time.Millisecond, Slow: 2 * time.Second})
	srv := httptest.NewServer(api)
	t.Cleanup(srv.Close)
	data, err := json.Marshal(Config{API: srv.URL, Service: "checkout",
		Targets: targets})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "deployctl.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// token is an environment with a token the fake API accepts.
var token = map[string]string{"DEPLOYCTL_TOKEN": fakeapi.Token}

// deployctl runs the command in-process with env as its environment, and
// returns what it printed on stdout and the error it returned.
func deployctl(ctx context.Context, env map[string]string,
	args ...string) (string, error) {

	var stdout bytes.Buffer
	err := run(ctx, args, func(k string) string { return env[k] }, &stdout)
	return stdout.String(), err
}

// END helpers OMIT
// START step1 OMIT
func TestDeployAllTargets(t *testing.T) {
	cfg := fakeAPI(t, "us-east-1", "us-west-2")
	out, err := deployctl(t.Context(), token, "-config", cfg, "deploy", "v1.4.2")
	if err != nil {
		t.Fatalf("deploy failed: %v", err)
	}
	for _, target := range []string{"us-east-1", "us-west-2"} {
		if !strings.Contains(out, target+"   deployed") {
			t.Errorf("output lacks %s:\n%s", target, out)
		}
	}
}

func TestFailureNamesTheTarget(t *testing.T) {
	cfg := fakeAPI(t, "us-east-1", "eu-west-1")
	_, err := deployctl(t.Context(), token, "-config", cfg, "deploy", "v1.4.2")
	if err == nil || !strings.Contains(err.Error(), "eu-west-1") {
		t.Fatalf("err = %v, want an error that names eu-west-1", err)
	}
}

func TestMissingConfigIsNotExist(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "nope.json")
	_, err := deployctl(t.Context(), token, "-config", missing, "deploy", "v1")
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("err = %v, want one that wraps fs.ErrNotExist", err)
	}
}

// END step1 OMIT
// START step2 OMIT
func TestAPIErrorKeepsTheDetails(t *testing.T) {
	cfg := fakeAPI(t, "sa-east-1")
	_, err := deployctl(t.Context(), token, "-config", cfg, "deploy", "v1.4.2")
	apiErr, ok := errors.AsType[*APIError](err)
	if !ok {
		t.Fatalf("err = %v, want an *APIError in the chain", err)
	}
	if apiErr.Status != 409 || !strings.HasPrefix(apiErr.RequestID, "req-") {
		t.Errorf("APIError = %+v, want status 409 and a request ID", apiErr)
	}
	if _, retried := errors.AsType[*RetryError](err); retried {
		t.Errorf("a 409 was retried: %v", err)
	}
}

func TestTemporaryFailuresAreRetried(t *testing.T) {
	cfg := fakeAPI(t, "eu-west-1")
	_, err := deployctl(t.Context(), token, "-config", cfg, "deploy", "v1.4.2")
	re, ok := errors.AsType[*RetryError](err)
	if !ok || re.Attempts != 3 {
		t.Fatalf("err = %v, want a *RetryError after 3 attempts", err)
	}
	if apiErr, ok := errors.AsType[*APIError](err); !ok || apiErr.Status != 503 {
		t.Errorf("the last attempt's *APIError is lost: %v", err)
	}
}

func TestBadTokenStopsBeforeDeploying(t *testing.T) {
	cfg := fakeAPI(t, "us-east-1")
	bad := map[string]string{"DEPLOYCTL_TOKEN": "expired"}
	out, err := deployctl(t.Context(), bad, "-config", cfg, "deploy", "v1.4.2")
	if apiErr, ok := errors.AsType[*APIError](err); !ok || apiErr.Status != 401 {
		t.Fatalf("err = %v, want the API's 401 in the chain", err)
	}
	if out != "" {
		t.Errorf("printed %q before checking the token", out)
	}
}

func TestInitRefusesToOverwrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "deployctl.json")
	if _, err := deployctl(t.Context(), nil, "-config", path, "init"); err != nil {
		t.Fatal(err)
	}
	_, err := deployctl(t.Context(), nil, "-config", path, "init")
	if !errors.Is(err, fs.ErrExist) {
		t.Fatalf("err = %v, want one that wraps fs.ErrExist", err)
	}
}

// END step2 OMIT
// START step3 OMIT
func TestPartialFailureReportsEveryTarget(t *testing.T) {
	cfg := fakeAPI(t, "us-east-1", "eu-west-1", "us-west-2", "sa-east-1")
	out, err := deployctl(t.Context(), token, "-config", cfg, "deploy", "v1.4.2")
	if err == nil {
		t.Fatal("deploy succeeded, want a partial failure")
	}
	for _, failed := range []string{"eu-west-1", "sa-east-1"} {
		if !strings.Contains(err.Error(), failed) {
			t.Errorf("the error does not mention %s: %v", failed, err)
		}
	}
	if n := strings.Count(out, "deployed"); n != 2 {
		t.Errorf("%d targets deployed, want 2:\n%s", n, out)
	}
}

func TestConfigProblemsReportedTogether(t *testing.T) {
	path := filepath.Join(t.TempDir(), "deployctl.json")
	if err := os.WriteFile(path, []byte(`{"service": "x"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := deployctl(t.Context(), token, "-config", path, "deploy", "v1")
	for _, want := range []string{`"api" is empty`, `"targets" is empty`} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("err = %v, want it to say %s", err, want)
		}
	}
}

// END step3 OMIT
// START step4 OMIT
func TestErrorCodes(t *testing.T) {
	cfg := fakeAPI(t, "us-east-1", "eu-west-1")
	tests := []struct {
		name string
		env  map[string]string
		args []string
		want clierr.Code
	}{
		{"ok", token, []string{"-config", cfg, "deploy", "-only", "us-east-1",
			"v1"}, clierr.ExitOK},
		{"help", token, []string{"-h"}, clierr.ExitOK},
		{"bad flag", token, []string{"-config", cfg, "deploy", "-parallel=x",
			"v1"}, clierr.ExitUsage},
		{"no version", token, []string{"-config", cfg, "deploy"}, clierr.ExitUsage},
		{"no config", token, []string{"-config", "nope.json", "deploy", "v1"},
			clierr.ExitUsage},
		{"no token", nil, []string{"-config", cfg, "deploy", "v1"},
			clierr.ExitNoPerm},
		{"partial", token, []string{"-config", cfg, "deploy", "v1"},
			clierr.ExitFailure},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := deployctl(t.Context(), tt.env, tt.args...)
			if got := clierr.CodeOf(err); got != tt.want {
				t.Errorf("CodeOf(%v) = %v, want %v", err, got, tt.want)
			}
		})
	}
}

// END step4 OMIT
// START step5 OMIT
func TestTimeoutComesFromTheCause(t *testing.T) {
	cfg := fakeAPI(t, "us-east-1", "ap-south-1") // ap-south-1 takes 2s
	_, err := deployctl(t.Context(), token, "-config", cfg, "deploy",
		"-timeout", "200ms", "v1.4.2")
	if got := clierr.CodeOf(err); got != clierr.ExitTempFail {
		t.Errorf("CodeOf = %v, want %v", got, clierr.ExitTempFail)
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("errors.Is(err, DeadlineExceeded) = false for %v", err)
	}
	if msg := clierr.UserMessage(err); msg != "deploy did not finish within 200ms" {
		t.Errorf("message = %q", msg)
	}
}

func TestSignalStopsTheRollout(t *testing.T) {
	cfg := fakeAPI(t, "us-east-1", "ap-south-1")
	ctx, cancel := context.WithCancelCause(t.Context())
	time.AfterFunc(200*time.Millisecond, func() {
		cancel(&clierr.SignalError{Signal: syscall.SIGINT}) // as Main does
	})
	_, err := deployctl(ctx, token, "-config", cfg, "deploy", "v1.4.2")
	if got := clierr.CodeOf(err); got != clierr.ExitInterrupted {
		t.Errorf("CodeOf = %v, want %v", got, clierr.ExitInterrupted)
	}
	if msg := clierr.UserMessage(err); !strings.Contains(msg,
		"1 of 2 targets not updated") {
		t.Errorf("message = %q", msg)
	}
}

// END step5 OMIT
