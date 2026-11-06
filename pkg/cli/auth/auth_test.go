package auth_test

// START imports OMIT

import (
	"context"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"

	"github.com/rahulbalajee/platform-go/pkg/cli/auth"
	"github.com/rahulbalajee/platform-go/pkg/devidp"
)

// END imports OMIT
// START setup OMIT

// provider starts a dev OIDC provider that approves every login as
// dev@example.com, and returns the client configuration for it.
func provider(t *testing.T) *oauth2.Config {
	t.Helper()
	p := &devidp.Provider{Audience: "platform", Interval: 1,
		AutoApprove: "dev@example.com"}
	srv := httptest.NewServer(p)
	t.Cleanup(srv.Close)
	p.Issuer = srv.URL
	prov, err := oidc.NewProvider(context.Background(), srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	return auth.NewConfig("plat", prov.Endpoint())
}

// fixed adapts a ready configuration to NewSource's lazy parameter.
func fixed(cfg *oauth2.Config) func() (*oauth2.Config, error) {
	return func() (*oauth2.Config, error) { return cfg, nil }
}

// login logs in and stores the token, then marks it expired, as if the
// person had logged in yesterday.
func expiredLogin(t *testing.T, cfg *oauth2.Config, s auth.Store) *auth.Token {
	t.Helper()
	tok, err := auth.Login(context.Background(), cfg,
		func(*oauth2.DeviceAuthResponse) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	tok.Expiry = time.Now().Add(-time.Hour)
	if err := auth.Save(s, "dev", tok); err != nil {
		t.Fatal(err)
	}
	return tok
}

// END setup OMIT
// START login OMIT

func TestLoginShowsTheCodeAndReturnsTokens(t *testing.T) {
	cfg := provider(t)
	var shown *oauth2.DeviceAuthResponse
	tok, err := auth.Login(context.Background(), cfg,
		func(da *oauth2.DeviceAuthResponse) error { shown = da; return nil })
	if err != nil {
		t.Fatal(err)
	}
	if shown == nil || shown.UserCode == "" || shown.VerificationURI == "" {
		t.Errorf("show got %+v", shown)
	}
	if tok.AccessToken == "" || tok.RefreshToken == "" || tok.IDToken == "" {
		t.Errorf("token %+v lacks access, refresh or ID token", tok)
	}
}

// END login OMIT
// START refresh OMIT

func TestSourceRefreshesAndSaves(t *testing.T) {
	cfg := provider(t)
	s := &auth.Memory{}
	old := expiredLogin(t, cfg, s)

	lock := filepath.Join(t.TempDir(), "refresh.lock")
	src := auth.NewSource(context.Background(), fixed(cfg), s, "dev", lock)
	got, err := src.Token()
	if err != nil {
		t.Fatal(err)
	}
	if got.AccessToken == old.AccessToken {
		t.Fatal("expired token returned without a refresh")
	}
	saved, _ := auth.Load(s, "dev")
	if saved.AccessToken != got.AccessToken ||
		saved.RefreshToken == old.RefreshToken {
		t.Error("the refreshed tokens were not saved")
	}
	if saved.IDToken == "" { // a refresh may bring a new ID token, or none
		t.Error("the ID token was lost in the refresh")
	}
}

// END refresh OMIT
// START processes OMIT

// Two sources sharing a credential file and a lock file behave like two plat
// processes. Both find the token expired at once; with the lock, one
// refreshes and the other picks up its result. Without it, the second
// refresh would reuse a spent token and the provider would revoke the login.
func TestConcurrentProcessesRefreshOnce(t *testing.T) {
	cfg := provider(t)
	dir := t.TempDir()
	store := auth.File{Path: filepath.Join(dir, "credentials.json")}
	expiredLogin(t, cfg, store)
	lock := filepath.Join(dir, "refresh.lock")

	var wg sync.WaitGroup
	tokens := make([]*oauth2.Token, 4)
	errs := make([]error, 4)
	for i := range tokens {
		wg.Go(func() {
			ts := auth.NewSource(context.Background(), fixed(cfg), store, "dev", lock)
			tokens[i], errs[i] = ts.Token()
		})
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("process %d: %v", i, err)
		}
		if tokens[i].AccessToken != tokens[0].AccessToken {
			t.Errorf("process %d refreshed separately", i)
		}
	}
}

// END processes OMIT
// START revoked OMIT

func TestRevokedRefreshTokenMeansLogInAgain(t *testing.T) {
	cfg := provider(t)
	s := &auth.Memory{}
	tok := expiredLogin(t, cfg, s)
	// Spend the refresh token behind the source's back, twice: the second
	// use is a reuse, which revokes the login.
	for range 2 {
		_, _ = cfg.TokenSource(context.Background(), &oauth2.Token{
			RefreshToken: tok.RefreshToken, Expiry: time.Unix(1, 0)}).Token()
	}
	lock := filepath.Join(t.TempDir(), "refresh.lock")
	_, err := auth.NewSource(context.Background(), fixed(cfg), s, "dev", lock).Token()
	if !errors.Is(err, auth.ErrLoginExpired) {
		t.Fatalf("err = %v, want ErrLoginExpired", err)
	}
}

// END revoked OMIT
// START file OMIT

func TestFileStoreIsPrivate(t *testing.T) {
	f := auth.File{Path: filepath.Join(t.TempDir(), "plat", "credentials.json")}
	if _, err := f.Get("dev"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("empty store: %v", err)
	}
	if err := f.Set("dev", "secret"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(f.Path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v, %v; want 0600", info.Mode().Perm(), err)
	}
	if v, err := f.Get("dev"); v != "secret" || err != nil {
		t.Errorf("Get = %q, %v", v, err)
	}
	if err := f.Delete("dev"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Get("dev"); !errors.Is(err, auth.ErrNotFound) {
		t.Errorf("after Delete: %v", err)
	}
}

// END file OMIT
// START invalidate OMIT

// A token the server rejects is refreshed even though it has not expired:
// it may have been revoked, or the clocks disagree.
func TestInvalidatedTokenIsRefreshed(t *testing.T) {
	cfg := provider(t)
	s := &auth.Memory{}
	tok, err := auth.Login(context.Background(), cfg,
		func(*oauth2.DeviceAuthResponse) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if err := auth.Save(s, "dev", tok); err != nil {
		t.Fatal(err)
	}
	src := auth.NewSource(context.Background(), fixed(cfg), s, "dev",
		filepath.Join(t.TempDir(), "refresh.lock"))
	first, err := src.Token()
	if err != nil || first.AccessToken != tok.AccessToken {
		t.Fatalf("first token: %v, %v", first, err)
	}
	src.Invalidate(first.AccessToken)
	second, err := src.Token()
	if err != nil {
		t.Fatal(err)
	}
	if second.AccessToken == first.AccessToken {
		t.Error("the rejected token was returned again")
	}
}

// END invalidate OMIT
