// START head OMIT

// Package devidp is a small OpenID Connect provider for development and
// tests. It implements the parts a command-line tool's login needs: the
// device authorization grant (RFC 8628), refresh tokens that rotate on every
// use with reuse detection, RS256-signed JWT access and ID tokens, and the
// discovery and JWKS documents that let any OIDC library verify them.
//
// It keeps everything in memory, generates a fresh signing key at start-up,
// and approves logins through a bare HTML form (or automatically). It is
// for localhost, never for production.
package devidp

// END head OMIT
// START imports OMIT

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"html/template"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// END imports OMIT
// START provider OMIT

// Provider is an OIDC provider. Configure the exported fields, then serve
// it: it is an http.Handler. Its methods are safe for concurrent use.
type Provider struct {
	// Issuer is the provider's URL, the "iss" of every token. Discovery
	// documents are served relative to it.
	Issuer string
	// Audience is the "aud" of access tokens: the API that accepts them.
	Audience string
	// AccessTTL is how long access and ID tokens live. Default 10 minutes.
	AccessTTL time.Duration
	// Interval is the polling interval the device grant asks clients to
	// keep, in whole seconds as RFC 8628 requires. Default 5.
	Interval int
	// AutoApprove, if set, approves every device login at once as this
	// user (an email address), for tests and demos without a browser.
	AutoApprove string
	// Now returns the current time. Default time.Now.
	Now func() time.Time

	once    sync.Once
	key     *rsa.PrivateKey
	keyID   string
	signer  jose.Signer
	mux     *http.ServeMux
	initErr error

	mu      sync.Mutex
	devices map[string]*deviceGrant  // by device code
	codes   map[string]*deviceGrant  // by user code
	refresh map[string]*refreshGrant // by refresh token
}

// END provider OMIT
// START grants OMIT

// deviceGrant is one login in progress: created by the device
// authorization request, approved (or denied) in the browser, and redeemed
// once at the token endpoint.
type deviceGrant struct {
	clientID, deviceCode, userCode string
	expires, lastPoll              time.Time
	interval                       time.Duration
	user                           string // set on approval
	denied                         bool
}

// refreshGrant is one refresh token. All tokens descended from one login
// share a family, so a reused token can revoke every live sibling: if an
// attacker and the user both hold a token, one of them will reuse it.
type refreshGrant struct {
	clientID, user string
	family         *family
	used           bool
}

type family struct{ revoked bool }

// END grants OMIT
// START paths OMIT

// Paths of the endpoints, relative to Issuer.
const (
	DiscoveryPath  = "/.well-known/openid-configuration"
	JWKSPath       = "/oidc/jwks"
	DeviceAuthPath = "/oidc/device/code"
	TokenPath      = "/oidc/token"
	VerifyPath     = "/oidc/device"
)

// END paths OMIT
// START init OMIT

func (p *Provider) init() error {
	p.once.Do(func() {
		if p.AccessTTL <= 0 {
			p.AccessTTL = 10 * time.Minute
		}
		if p.Interval <= 0 {
			p.Interval = 5
		}
		if p.Now == nil {
			p.Now = time.Now
		}
		p.devices = map[string]*deviceGrant{}
		p.codes = map[string]*deviceGrant{}
		p.refresh = map[string]*refreshGrant{}
		p.key, p.initErr = rsa.GenerateKey(rand.Reader, 2048)
		if p.initErr != nil {
			return
		}
		p.keyID = randomString(8)
		p.signer, p.initErr = jose.NewSigner(
			jose.SigningKey{Algorithm: jose.RS256, Key: p.key},
			(&jose.SignerOptions{}).WithType("JWT").
				WithHeader(jose.HeaderKey("kid"), p.keyID))
		p.mux = http.NewServeMux()
		p.mux.HandleFunc("GET "+DiscoveryPath, p.discovery)
		p.mux.HandleFunc("GET "+JWKSPath, p.jwks)
		p.mux.HandleFunc("POST "+DeviceAuthPath, p.deviceAuth)
		p.mux.HandleFunc("POST "+TokenPath, p.token)
		p.mux.HandleFunc("GET "+VerifyPath, p.verifyForm)
		p.mux.HandleFunc("POST "+VerifyPath, p.verifySubmit)
	})
	return p.initErr
}

// ServeHTTP serves the provider's endpoints.
func (p *Provider) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if err := p.init(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	p.mux.ServeHTTP(w, r)
}

// END init OMIT
// START discovery OMIT

// discovery serves the OpenID Provider Metadata that clients such as
// go-oidc's NewProvider read to find everything else.
func (p *Provider) discovery(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"issuer":                        p.Issuer,
		"jwks_uri":                      p.Issuer + JWKSPath,
		"device_authorization_endpoint": p.Issuer + DeviceAuthPath,
		"token_endpoint":                p.Issuer + TokenPath,
		"grant_types_supported": []string{
			"urn:ietf:params:oauth:grant-type:device_code", "refresh_token"},
		"response_types_supported":              []string{"token"},
		"subject_types_supported":               []string{"public"},
		"id_token_signing_alg_values_supported": []string{"RS256"},
		"token_endpoint_auth_methods_supported": []string{"none"},
	})
}

// jwks publishes the public half of the signing key.
func (p *Provider) jwks(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{
		Key: &p.key.PublicKey, KeyID: p.keyID, Algorithm: "RS256", Use: "sig",
	}}})
}

// END discovery OMIT
// START deviceauth OMIT

// deviceAuth starts a login: the client gets a long secret device code to
// poll with, and the person gets a short user code to type in a browser.
func (p *Provider) deviceAuth(w http.ResponseWriter, r *http.Request) {
	clientID := clientIDOf(r)
	if clientID == "" {
		oauthError(w, "invalid_client", "client_id is required")
		return
	}
	now := p.Now()
	g := &deviceGrant{
		clientID:   clientID,
		deviceCode: randomString(32),
		expires:    now.Add(10 * time.Minute),
		interval:   time.Duration(p.Interval) * time.Second,
	}
	p.mu.Lock()
	for g.userCode == "" || p.codes[g.userCode] != nil {
		g.userCode = userCode() // 20^8 codes; a clash is rare, not impossible
	}
	p.devices[g.deviceCode] = g
	p.codes[g.userCode] = g
	if p.AutoApprove != "" {
		g.user = p.AutoApprove
	}
	p.mu.Unlock()

	verify := p.Issuer + VerifyPath
	writeJSON(w, http.StatusOK, map[string]any{
		"device_code":               g.deviceCode,
		"user_code":                 g.userCode,
		"verification_uri":          verify,
		"verification_uri_complete": verify + "?user_code=" + g.userCode,
		"expires_in":                int(g.expires.Sub(now).Seconds()),
		"interval":                  p.Interval,
	})
}

// END deviceauth OMIT
// START token OMIT

// token is the token endpoint, for both grant types.
func (p *Provider) token(w http.ResponseWriter, r *http.Request) {
	switch r.PostFormValue("grant_type") {
	case "urn:ietf:params:oauth:grant-type:device_code":
		p.redeemDeviceCode(w, clientIDOf(r), r.PostFormValue("device_code"))
	case "refresh_token":
		p.redeemRefreshToken(w, clientIDOf(r), r.PostFormValue("refresh_token"))
	default:
		oauthError(w, "unsupported_grant_type", "")
	}
}

// clientIDOf returns the client's ID from HTTP Basic authentication or the
// form body: RFC 6749 allows both, and golang.org/x/oauth2 picks one by
// trial (see the AuthStyle note in package auth).
func clientIDOf(r *http.Request) string {
	if user, _, ok := r.BasicAuth(); ok && user != "" {
		if id, err := url.QueryUnescape(user); err == nil {
			return id
		}
	}
	return r.PostFormValue("client_id")
}

// END token OMIT
// START redeemdevice OMIT

// redeemDeviceCode answers a client's poll. The error codes are RFC 8628's:
// authorization_pending (keep polling), slow_down (polling too fast: add 5
// seconds), access_denied and expired_token (stop).
func (p *Provider) redeemDeviceCode(w http.ResponseWriter, clientID, code string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := p.Now()
	g := p.devices[code]
	switch {
	case g == nil || g.clientID != clientID:
		oauthError(w, "invalid_grant", "unknown device code")
		return
	case now.After(g.expires):
		p.forget(g)
		oauthError(w, "expired_token", "the login expired; start again")
		return
	case g.denied:
		// Keep the grant until it expires, so a retried poll gets the
		// same answer instead of "unknown device code".
		oauthError(w, "access_denied", "the login was denied")
		return
	case g.user == "":
		if !g.lastPoll.IsZero() && now.Sub(g.lastPoll) < g.interval {
			g.interval += 5 * time.Second
			g.lastPoll = now
			oauthError(w, "slow_down", "")
			return
		}
		g.lastPoll = now
		oauthError(w, "authorization_pending", "")
		return
	}
	p.forget(g) // a device code is redeemed exactly once
	p.issue(w, g.clientID, g.user, &family{})
}

func (p *Provider) forget(g *deviceGrant) {
	delete(p.devices, g.deviceCode)
	delete(p.codes, g.userCode)
}

// END redeemdevice OMIT
// START redeemrefresh OMIT

// redeemRefreshToken rotates a refresh token: the old one stops working and
// a new one is issued with the new access token. Presenting a token that
// was already used means two parties hold it, so the whole family is
// revoked and the user must log in again.
func (p *Provider) redeemRefreshToken(w http.ResponseWriter, clientID, token string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	g := p.refresh[token]
	switch {
	case g == nil || g.clientID != clientID || g.family.revoked:
		oauthError(w, "invalid_grant", "unknown or revoked refresh token")
		return
	case g.used:
		g.family.revoked = true
		oauthError(w, "invalid_grant",
			"refresh token reused; all tokens from this login are revoked")
		return
	}
	g.used = true
	p.issue(w, g.clientID, g.user, g.family)
}

// END redeemrefresh OMIT
// START issue OMIT

// issue signs an access token for the API and an ID token for the client,
// and creates a refresh token. The caller holds p.mu.
func (p *Provider) issue(w http.ResponseWriter, clientID, user string, fam *family) {
	now := p.Now()
	base := jwt.Claims{
		Issuer:   p.Issuer,
		Subject:  user,
		IssuedAt: jwt.NewNumericDate(now),
		Expiry:   jwt.NewNumericDate(now.Add(p.AccessTTL)),
		ID:       randomString(12),
	}
	access := base
	access.Audience = jwt.Audience{p.Audience}
	extra := map[string]any{"client_id": clientID, "email": user}
	at, err := jwt.Signed(p.signer).Claims(access).Claims(extra).Serialize()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	idClaims := base
	idClaims.Audience = jwt.Audience{clientID}
	name, _, _ := strings.Cut(user, "@")
	id, err := jwt.Signed(p.signer).Claims(idClaims).
		Claims(map[string]any{"email": user, "name": name}).Serialize()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	rt := randomString(32)
	p.refresh[rt] = &refreshGrant{clientID: clientID, user: user, family: fam}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{
		"access_token":  at,
		"token_type":    "Bearer",
		"expires_in":    int(p.AccessTTL.Seconds()),
		"refresh_token": rt,
		"id_token":      id,
	})
}

// END issue OMIT
// START approve OMIT

// Approve approves the login with the given user code as user, as if they
// had submitted the browser form. It is for tests.
func (p *Provider) Approve(userCode, user string) error {
	if err := p.init(); err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	g := p.codes[strings.ToUpper(strings.TrimSpace(userCode))]
	if g == nil || p.Now().After(g.expires) {
		return errors.New("devidp: no pending login with that code")
	}
	g.user = user
	return nil
}

// END approve OMIT
// START form OMIT

var form = template.Must(template.New("form").Parse(`<!doctype html>
<title>Log in to the dev platform</title>
<h1>Log in to the dev platform</h1>
{{if .Done}}<p>{{.Done}} You can close this tab.</p>{{else}}
<form method="post">
<p><label>Code from your terminal <input name="user_code" value="{{.Code}}"></label>
<p><label>Log in as <input name="email" value="dev@example.com"></label>
<p><button name="action" value="approve">Approve</button>
<button name="action" value="deny">Deny</button>
</form>{{end}}`))

func (p *Provider) verifyForm(w http.ResponseWriter, r *http.Request) {
	_ = form.Execute(w, map[string]string{"Code": r.URL.Query().Get("user_code")})
}

// verifySubmit handles the form. A dev provider on localhost has no
// sessions or CSRF protection; a real one authenticates the person first.
func (p *Provider) verifySubmit(w http.ResponseWriter, r *http.Request) {
	code := strings.ToUpper(strings.TrimSpace(r.PostFormValue("user_code")))
	var err error
	if r.PostFormValue("action") == "deny" {
		err = p.deny(code)
	} else {
		err = p.Approve(code, r.PostFormValue("email"))
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	_ = form.Execute(w, map[string]string{"Done": "Done."})
}

func (p *Provider) deny(code string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	g := p.codes[code]
	if g == nil {
		return errors.New("devidp: no pending login with that code")
	}
	g.denied = true
	return nil
}

// END form OMIT
// START helpers OMIT

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// oauthError writes an OAuth 2.0 error response (RFC 6749 section 5.2).
func oauthError(w http.ResponseWriter, code, description string) {
	body := map[string]string{"error": code}
	if description != "" {
		body["error_description"] = description
	}
	writeJSON(w, http.StatusBadRequest, body)
}

// randomString returns n random bytes, base64url-encoded: unguessable,
// and safe in URLs and form values.
func randomString(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b) // never fails (crypto/rand panics instead)
	return base64.RawURLEncoding.EncodeToString(b)
}

// userCode returns a code like "WDJB-MJHT": consonants only, as RFC 8628
// suggests, so it never spells a word and is easy to type from a screen.
// Bytes of 240 and above are skipped: 256 is not a multiple of 20, so
// taking every byte modulo 20 would make the first 16 letters likelier.
func userCode() string {
	const alphabet = "BCDFGHJKLMNPQRSTVWXZ"
	var sb strings.Builder
	b := make([]byte, 1)
	for n := 0; n < 8; {
		_, _ = rand.Read(b)
		if b[0] >= 240 {
			continue
		}
		if n == 4 {
			sb.WriteByte('-')
		}
		sb.WriteByte(alphabet[b[0]%20])
		n++
	}
	return sb.String()
}

// END helpers OMIT
