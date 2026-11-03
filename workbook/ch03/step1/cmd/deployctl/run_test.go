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
	"testing"
	"time"

	"deployctl/internal/fakeapi"
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
