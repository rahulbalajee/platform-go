package commands

// START imports OMIT

import (
	"context"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/auth"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
	"github.com/rahulbalajee/platform-go/pkg/platformapi/platformapifake"
)

// END imports OMIT
// START harness OMIT

// testPlat is plat wired to an in-memory platform: a fresh fake API per
// test, a client that polls every millisecond, and buffers for stdout and
// stderr.
type testPlat struct {
	t           *testing.T
	api         *platformapifake.Server
	f           *factory.Factory
	out, errOut *strings.Builder
}

func newTestPlat(t *testing.T) *testPlat {
	t.Helper()
	api := platformapifake.New()
	srv := httptest.NewServer(api)
	t.Cleanup(srv.Close)

	ios, _, _, _ := cli.Test()
	out, errOut := new(strings.Builder), new(strings.Builder)
	ios.Out, ios.ErrOut = out, errOut
	f := isolated(t, factory.New(ios, "v0.0.0-test"), nil)
	f.Client = func() (*platformapi.Client, error) {
		return platformapi.New(srv.URL,
			platformapi.WithPollInterval(time.Millisecond))
	}
	return &testPlat{t: t, api: api, f: f, out: out, errOut: errOut}
}

// isolated keeps f away from the real user's configuration, keychain and
// environment: a developer's own `plat login` must not change test results.
func isolated(t *testing.T, f *factory.Factory, env map[string]string,
) *factory.Factory {
	t.Helper()
	dir := t.TempDir()
	f.Getenv = func(k string) string { return env[k] }
	f.ConfigDir = func() (string, error) { return dir, nil }
	cache, work := t.TempDir(), t.TempDir()
	f.CacheDir = func() (string, error) { return cache, nil }
	f.WorkDir = func() (string, error) { return work, nil }
	store := &auth.Memory{}
	f.Store = func() (auth.Store, error) { return store, nil }
	return f
}

// run executes `plat args...` and returns its error, as main would see it.
func (p *testPlat) run(args ...string) error {
	p.t.Helper()
	p.out.Reset()
	p.errOut.Reset()
	return cli.Execute(context.Background(), NewRoot(p.f), args)
}

// wantCode fails the test unless err maps to the exit code want.
func wantCode(t *testing.T, err error, want clierr.Code) *clierr.Error {
	t.Helper()
	if got := clierr.CodeOf(err); got != want {
		t.Fatalf("exit code = %v (%v), want %v", got, err, want)
	}
	e, _ := errors.AsType[*clierr.Error](err)
	return e
}

// END harness OMIT
// START list OMIT

func TestServicesList(t *testing.T) {
	p := newTestPlat(t)
	if err := p.run("services", "list", "--team", "payments"); err != nil {
		t.Fatal(err)
	}
	want := `NAME      TEAM      REPLICAS
checkout  payments  4
ledger    payments  2
`
	if p.out.String() != want {
		t.Errorf("stdout:\n%s\nwant:\n%s", p.out, want)
	}
}

func TestDeploymentsListStopsAtLimit(t *testing.T) {
	p := newTestPlat(t)
	if err := p.run("deployments", "list", "-L", "2"); err != nil {
		t.Fatal(err)
	}
	if rows := strings.Count(p.out.String(), "\n") - 1; rows != 2 {
		t.Errorf("%d rows, want 2:\n%s", rows, p.out)
	}
}

func TestNotFound(t *testing.T) {
	p := newTestPlat(t)
	e := wantCode(t, p.run("services", "get", "nope"), clierr.ExitFailure)
	if e.Message != `service "nope" not found` {
		t.Errorf("message = %q", e.Message)
	}
}

// END list OMIT
// START deploy OMIT

func TestDeployWaitsAndPrintsTheID(t *testing.T) {
	p := newTestPlat(t)
	err := p.run("deploy", "checkout", "v1.5.0", "--env", "staging")
	if err != nil {
		t.Fatal(err)
	}
	if p.out.String() != "d-9\n" {
		t.Errorf("stdout = %q, want only the deployment ID", p.out)
	}
	for _, want := range []string{
		"Deploying checkout v1.5.0 to staging as d-9",
		"4/4 replicas updated",
	} {
		if !strings.Contains(p.errOut.String(), want) {
			t.Errorf("stderr lacks %q:\n%s", want, p.errOut)
		}
	}
	if s := p.api.DeploymentState("d-9"); s != "succeeded" {
		t.Errorf("deployment state = %q", s)
	}
}

func TestDeployFailedRolloutExitsOne(t *testing.T) {
	p := newTestPlat(t)
	p.api.BreakVersion("v1.5.0")
	e := wantCode(t, p.run("deploy", "checkout", "v1.5.0", "-e", "staging"),
		clierr.ExitFailure)
	if !strings.HasPrefix(e.Message, "deployment d-9 failed") ||
		e.Hint != "See the rollout log: plat logs d-9" {
		t.Errorf("message, hint = %q, %q", e.Message, e.Hint)
	}
}

func TestDeployConflict(t *testing.T) {
	p := newTestPlat(t)
	err := p.run("deploy", "checkout", "v1.5.0", "-e", "dev", "--no-wait")
	if err != nil {
		t.Fatal(err)
	}
	e := wantCode(t, p.run("deploy", "checkout", "v1.5.1", "-e", "dev"),
		clierr.ExitFailure)
	if e.Message != "checkout is already being deployed to dev" {
		t.Errorf("message = %q", e.Message)
	}
}

// A timed-out wait is a temporary failure (75): the rollout goes on, and
// the message says how to find it again.
func TestDeployTimeoutLeavesTheRolloutRunning(t *testing.T) {
	p := newTestPlat(t)
	e := wantCode(t, p.run("deploy", "checkout", "v1.5.0", "-e", "dev",
		"--timeout", "1ns"), clierr.ExitTempFail)
	if e.Message != "stopped waiting for d-9" ||
		!strings.Contains(e.Hint, "plat deployments get d-9") {
		t.Errorf("message, hint = %q, %q", e.Message, e.Hint)
	}
	if s := p.api.DeploymentState("d-9"); s == "cancelled" {
		t.Error("the timeout cancelled the deployment")
	}
}

// END deploy OMIT
// START auth OMIT

func TestTokenFromTheEnvironment(t *testing.T) {
	api := platformapifake.New()
	api.RequireToken("s3cret")
	srv := httptest.NewServer(api)
	defer srv.Close()

	for _, tc := range []struct {
		token string
		want  clierr.Code
	}{
		{"s3cret", clierr.ExitOK},
		{"wrong", clierr.ExitNoPerm},
		{"", clierr.ExitNoPerm},
	} {
		ios, _, _, _ := cli.Test()
		f := isolated(t, factory.New(ios, "test"), map[string]string{
			"PLAT_SERVER": srv.URL, "PLAT_TOKEN": tc.token})
		err := cli.Execute(context.Background(), NewRoot(f),
			[]string{"envs", "list"})
		if got := clierr.CodeOf(err); got != tc.want {
			t.Errorf("PLAT_TOKEN=%q: exit %v (%v), want %v",
				tc.token, got, err, tc.want)
		}
	}
}

func TestNoServerIsAUsageError(t *testing.T) {
	ios, _, _, _ := cli.Test()
	f := isolated(t, factory.New(ios, "test"), nil)
	err := cli.Execute(context.Background(), NewRoot(f), []string{"envs", "ls"})
	e := wantCode(t, err, clierr.ExitUsage)
	if e.Message != "no platform server configured" {
		t.Errorf("message = %q", e.Message)
	}
}

// END auth OMIT
// START completion OMIT

// Shells call the hidden __complete command on every Tab press; this is
// exactly what `plat services get <Tab>` runs.
func TestCompletesServiceNames(t *testing.T) {
	p := newTestPlat(t)
	if err := p.run("__complete", "services", "get", ""); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"checkout\tpayments", "search\tdiscovery",
		":4"} { // 4 = ShellCompDirectiveNoFileComp
		if !strings.Contains(p.out.String(), want) {
			t.Errorf("completions lack %q:\n%s", want, p.out)
		}
	}
}

// END completion OMIT
// START docs OMIT

func TestGeneratesDocs(t *testing.T) {
	p := newTestPlat(t)
	dir := t.TempDir()
	if err := p.run("docs", "markdown", dir); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "plat_deploy.md"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "plat deploy SERVICE VERSION --env ENV") {
		t.Errorf("plat_deploy.md lacks the usage line:\n%s", b)
	}
}

// END docs OMIT
