package devidp_test

// START imports OMIT

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"

	"github.com/rahulbalajee/platform-go/pkg/devidp"
)

// END imports OMIT
// START setup OMIT

// start serves a provider with a 1-second polling interval (the smallest
// RFC 8628 allows) and returns it with an oauth2 config for client "plat".
func start(t *testing.T, autoApprove string) (*devidp.Provider, *oauth2.Config) {
	t.Helper()
	p := &devidp.Provider{Audience: "platform", Interval: 1,
		AutoApprove: autoApprove}
	srv := httptest.NewServer(p)
	t.Cleanup(srv.Close)
	p.Issuer = srv.URL

	prov, err := oidc.NewProvider(context.Background(), srv.URL)
	if err != nil {
		t.Fatalf("discovery: %v", err)
	}
	ep := prov.Endpoint()
	// Without an explicit style, x/oauth2 sends every failing token request
	// twice (Basic auth, then form), which turns each pending device poll
	// into a pair and earns slow_down. Public clients use the form.
	ep.AuthStyle = oauth2.AuthStyleInParams
	return p, &oauth2.Config{ClientID: "plat", Endpoint: ep}
}

// END setup OMIT
// START login OMIT

// The whole device flow through golang.org/x/oauth2, and the ID token
// verified by go-oidc against the published keys: if these two libraries
// accept the provider, real clients will.
func TestDeviceLoginAndIDToken(t *testing.T) {
	p, cfg := start(t, "")
	ctx := context.Background()
	da, err := cfg.DeviceAuth(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(da.UserCode) != 9 || da.UserCode[4] != '-' ||
		!strings.HasSuffix(da.VerificationURI, devidp.VerifyPath) {
		t.Errorf("device auth = %+v", da)
	}
	if err := p.Approve(da.UserCode, "alice@acme.dev"); err != nil {
		t.Fatal(err)
	}
	tok, err := cfg.DeviceAccessToken(ctx, da)
	if err != nil {
		t.Fatal(err)
	}
	if tok.RefreshToken == "" || tok.Expiry.IsZero() {
		t.Errorf("token = %+v, want a refresh token and an expiry", tok)
	}

	prov, _ := oidc.NewProvider(ctx, p.Issuer)
	raw, _ := tok.Extra("id_token").(string)
	id, err := prov.Verifier(&oidc.Config{ClientID: "plat"}).Verify(ctx, raw)
	if err != nil {
		t.Fatalf("ID token: %v", err)
	}
	var claims struct{ Email, Name string }
	if err := id.Claims(&claims); err != nil {
		t.Fatal(err)
	}
	if id.Subject != "alice@acme.dev" || claims.Name != "alice" {
		t.Errorf("subject %q, claims %+v", id.Subject, claims)
	}

	// The access token is for the API: right audience, wrong for the client.
	api := prov.Verifier(&oidc.Config{ClientID: "platform"})
	if _, err := api.Verify(ctx, tok.AccessToken); err != nil {
		t.Errorf("access token rejected for audience platform: %v", err)
	}
	if _, err := prov.Verifier(&oidc.Config{ClientID: "plat"}).
		Verify(ctx, tok.AccessToken); err == nil {
		t.Error("access token accepted as an ID token for the client")
	}
}

// END login OMIT
// START denied OMIT

func TestDeniedLogin(t *testing.T) {
	p, cfg := start(t, "")
	ctx := context.Background()
	da, err := cfg.DeviceAuth(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// Deny through the browser form, as a person would.
	form := url.Values{"action": {"deny"}, "user_code": {da.UserCode}}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost,
		p.Issuer+devidp.VerifyPath, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("deny: status %d", resp.StatusCode)
	}
	_, err = cfg.DeviceAccessToken(ctx, da)
	re, ok := errors.AsType[*oauth2.RetrieveError](err)
	if !ok || re.ErrorCode != "access_denied" {
		t.Fatalf("err = %v, want access_denied", err)
	}
}

// END denied OMIT
// START refresh OMIT

// Refresh tokens rotate, and replaying a spent one revokes the whole login:
// the replay could come from an attacker who copied the token.
func TestRefreshRotationAndReuse(t *testing.T) {
	_, cfg := start(t, "bob@acme.dev")
	ctx := context.Background()
	da, err := cfg.DeviceAuth(ctx)
	if err != nil {
		t.Fatal(err)
	}
	first, err := cfg.DeviceAccessToken(ctx, da)
	if err != nil {
		t.Fatal(err)
	}
	refresh := func(rt string) (*oauth2.Token, error) {
		expired := &oauth2.Token{RefreshToken: rt, Expiry: time.Unix(1, 0)}
		return cfg.TokenSource(ctx, expired).Token()
	}
	second, err := refresh(first.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if second.RefreshToken == first.RefreshToken {
		t.Fatal("refresh token did not rotate")
	}
	if _, err := refresh(first.RefreshToken); err == nil {
		t.Fatal("a spent refresh token worked again")
	}
	// The replay revoked the family, so even the newest token is dead.
	if _, err := refresh(second.RefreshToken); err == nil {
		t.Fatal("refresh token survived the reuse of its predecessor")
	}
}

// END refresh OMIT
// START race OMIT

// Two clients redeeming one refresh token at once: exactly one wins. This is
// the race that two plat processes refreshing together would run, and why
// plat holds a file lock around its refresh.
func TestConcurrentRefreshOneWins(t *testing.T) {
	_, cfg := start(t, "carol@acme.dev")
	ctx := context.Background()
	da, _ := cfg.DeviceAuth(ctx)
	tok, err := cfg.DeviceAccessToken(ctx, da)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i := range errs {
		wg.Go(func() {
			expired := &oauth2.Token{RefreshToken: tok.RefreshToken,
				Expiry: time.Unix(1, 0)}
			_, errs[i] = cfg.TokenSource(ctx, expired).Token()
		})
	}
	wg.Wait()
	if (errs[0] == nil) == (errs[1] == nil) {
		t.Fatalf("errors = %v; want exactly one refresh to fail", errs)
	}
}

// END race OMIT
