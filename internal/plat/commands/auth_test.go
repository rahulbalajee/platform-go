package commands

// START imports OMIT

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/oauth2"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/internal/platformd"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/auth"
	"github.com/rahulbalajee/platform-go/pkg/cli/config"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
)

// END imports OMIT
// START harness OMIT

// loginPlat is plat against the full development platform: the API behind
// the JWT middleware, and the dev OIDC provider approving every login as
// dev@example.com. Configuration and credentials live in the test.
type loginPlat struct {
	*testPlat
	url   string
	store auth.Store
	dir   string
}

func newLoginPlat(t *testing.T, opts platformd.Options) *loginPlat {
	t.Helper()
	var srv *platformd.Server
	hs := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) { srv.ServeHTTP(w, r) }))
	t.Cleanup(hs.Close)
	opts.Issuer, opts.AutoApprove, opts.Interval = hs.URL, "dev@example.com", 1
	srv, err := platformd.New(opts)
	if err != nil {
		t.Fatal(err)
	}

	ios, _, _, _ := cli.Test()
	out, errOut := new(strings.Builder), new(strings.Builder)
	ios.Out, ios.ErrOut = out, errOut
	f := isolated(t, factory.New(ios, "v0.0.0-test"), nil)
	store, _ := f.Store()
	dir, _ := f.ConfigDir()
	return &loginPlat{
		testPlat: &testPlat{t: t, api: srv.API, f: f, out: out, errOut: errOut},
		url:      hs.URL, store: store, dir: dir,
	}
}

// END harness OMIT
// START login OMIT

func TestLoginThenUseThePlatform(t *testing.T) {
	p := newLoginPlat(t, platformd.Options{})
	if err := p.run("login", "--server", p.url); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"code: ", "/oidc/device?user_code=",
		"Logged in to " + p.url + " as dev@example.com"} {
		if !strings.Contains(p.errOut.String(), want) {
			t.Errorf("login output lacks %q:\n%s", want, p.errOut)
		}
	}
	file, err := config.Load(filepath.Join(p.dir, "config.yaml"))
	if err != nil || file.CurrentContext != "default" {
		t.Fatalf("config after login: %+v, %v", file, err)
	}

	if err := p.run("services", "list"); err != nil {
		t.Fatalf("authenticated call: %v", err)
	}
	if err := p.run("whoami"); err != nil || p.out.String() != "dev@example.com\n" {
		t.Errorf("whoami = %q, %v", p.out, err)
	}
	if err := p.run("auth", "token"); err != nil ||
		strings.Count(p.out.String(), ".") != 2 {
		t.Errorf("auth token = %q, %v; want a JWT", p.out, err)
	}
}

// END login OMIT
// START notloggedin OMIT

func TestNotLoggedInSaysWhatToRun(t *testing.T) {
	p := newLoginPlat(t, platformd.Options{})
	if err := p.run("config", "set-context", "dev", "--server", p.url); err != nil {
		t.Fatal(err)
	}
	e := wantCode(t, p.run("envs", "list", "--context", "dev"), clierr.ExitNoPerm)
	if e.Message != "not logged in to this context" || e.Hint != "Run 'plat login'." {
		t.Errorf("message, hint = %q, %q", e.Message, e.Hint)
	}
}

// END notloggedin OMIT
// START expired OMIT

// An access token that expired since the last command is refreshed
// silently, and the new tokens replace the old ones in the store.
func TestExpiredLoginIsRefreshed(t *testing.T) {
	p := newLoginPlat(t, platformd.Options{})
	if err := p.run("login", "--server", p.url); err != nil {
		t.Fatal(err)
	}
	old, _ := auth.Load(p.store, "default")
	old.Expiry = time.Now().Add(-time.Minute)
	if err := auth.Save(p.store, "default", old); err != nil {
		t.Fatal(err)
	}
	if err := p.run("envs", "list"); err != nil {
		t.Fatalf("call with an expired token: %v", err)
	}
	now, _ := auth.Load(p.store, "default")
	if now.AccessToken == old.AccessToken || now.RefreshToken == old.RefreshToken {
		t.Error("the expired login was not refreshed and saved")
	}
}

// END expired OMIT
// START contexts OMIT

func TestContexts(t *testing.T) {
	p := newLoginPlat(t, platformd.Options{})
	for _, args := range [][]string{
		{"config", "set-context", "dev", "--server", p.url},
		{"config", "set-context", "prod", "--server", "https://platform.acme.dev"},
		{"config", "use-context", "dev"},
		{"login"},
	} {
		if err := p.run(args...); err != nil {
			t.Fatalf("plat %s: %v", strings.Join(args, " "), err)
		}
	}
	if err := p.run("config", "get-contexts"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(p.out.String(), "*         dev    "+p.url) {
		t.Errorf("get-contexts:\n%s", p.out)
	}
	if err := p.run("config", "delete-context", "dev"); err != nil {
		t.Fatal(err)
	}
	if _, err := p.store.Get("dev"); err == nil {
		t.Error("delete-context left the login in the credential store")
	}
}

func TestUnknownContextNamesWhereItCameFrom(t *testing.T) {
	p := newLoginPlat(t, platformd.Options{})
	p.f.Getenv = func(k string) string {
		return map[string]string{"PLAT_CONTEXT": "staging"}[k]
	}
	e := wantCode(t, p.run("envs", "list"), clierr.ExitUsage)
	if e.Message != `context "staging" (from PLAT_CONTEXT) does not exist` {
		t.Errorf("message = %q", e.Message)
	}
}

func TestAuthStatusShowsOrigins(t *testing.T) {
	p := newLoginPlat(t, platformd.Options{})
	if err := p.run("login", "--server", p.url); err != nil {
		t.Fatal(err)
	}
	p.f.Getenv = func(k string) string {
		return map[string]string{"PLAT_SERVER": "http://elsewhere"}[k]
	}
	if err := p.run("auth", "status"); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"default (from current-context)",
		"http://elsewhere (from PLAT_SERVER)", "refreshable (stored in memory)"} {
		if !strings.Contains(p.out.String(), want) {
			t.Errorf("status lacks %q:\n%s", want, p.out)
		}
	}
}

// END contexts OMIT
// START github OMIT

// fakeGitHub answers the three GitHub endpoints a login uses: the device
// code, the token (approved at once) and GET /user.
func fakeGitHub(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, v any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(v)
	}
	mux.HandleFunc("POST /login/device/code",
		func(w http.ResponseWriter, _ *http.Request) {
			reply(w, map[string]any{"device_code": "dc",
				"user_code":        "WDJB-MJHT",
				"verification_uri": "https://github.com/login/device",
				"expires_in":       900, "interval": 1})
		})
	mux.HandleFunc("POST /login/oauth/access_token",
		func(w http.ResponseWriter, _ *http.Request) {
			reply(w, map[string]any{"access_token": "gho_test",
				"token_type": "bearer", "expires_in": 28800,
				"refresh_token": "ghr_test"})
		})
	mux.HandleFunc("GET /user", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer gho_test" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		reply(w, map[string]string{"login": "octocat"})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

// With --provider github, plat logs in with GitHub's device flow and the
// platform accepts the GitHub token by asking GitHub whose it is.
func TestGitHubLogin(t *testing.T) {
	gh := fakeGitHub(t)
	p := newLoginPlat(t, platformd.Options{GitHub: true, GitHubAPI: gh.URL})
	p.f.GitHubAPI = gh.URL
	real := p.f.OAuth
	p.f.OAuth = func(ctx context.Context, c config.Context) (*oauth2.Config, error) {
		if c.Provider != "github" {
			return real(ctx, c)
		}
		return auth.NewConfig(factory.GitHubClientID, oauth2.Endpoint{
			DeviceAuthURL: gh.URL + "/login/device/code",
			TokenURL:      gh.URL + "/login/oauth/access_token"}), nil
	}
	err := p.run("login", "--context", "gh", "--server", p.url,
		"--provider", "github")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(p.errOut.String(), "open https://github.com/login/device") ||
		!strings.Contains(p.errOut.String(), "as github:octocat") {
		t.Errorf("login output:\n%s", p.errOut)
	}
	if err := p.run("deployments", "list", "--context", "gh", "-L", "1"); err != nil {
		t.Fatalf("platform call with a GitHub token: %v", err)
	}
}

// END github OMIT
