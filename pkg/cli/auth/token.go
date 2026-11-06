package auth

// START imports OMIT

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"golang.org/x/oauth2"

	"github.com/rahulbalajee/platform-go/pkg/fsx"
)

// END imports OMIT
// START token OMIT

// Token is what a login leaves in the store: the OAuth 2.0 tokens plus the
// OpenID Connect ID token, which says who logged in.
type Token struct {
	AccessToken  string    `json:"access_token"`
	TokenType    string    `json:"token_type,omitempty"`
	RefreshToken string    `json:"refresh_token,omitempty"`
	Expiry       time.Time `json:"expiry,omitzero"`
	IDToken      string    `json:"id_token,omitempty"`
}

// fromOAuth2 converts a token response. Refresh responses may omit the ID
// token; then the previous one is kept.
func fromOAuth2(t *oauth2.Token, previousID string) *Token {
	id, _ := t.Extra("id_token").(string)
	if id == "" {
		id = previousID
	}
	return &Token{AccessToken: t.AccessToken, TokenType: t.TokenType,
		RefreshToken: t.RefreshToken, Expiry: t.Expiry, IDToken: id}
}

func (t *Token) oauth2() *oauth2.Token {
	return &oauth2.Token{AccessToken: t.AccessToken, TokenType: t.TokenType,
		RefreshToken: t.RefreshToken, Expiry: t.Expiry}
}

// Load returns the token stored under key.
func Load(s Store, key string) (*Token, error) {
	raw, err := s.Get(key)
	if err != nil {
		return nil, err
	}
	var t Token
	if err := json.Unmarshal([]byte(raw), &t); err != nil {
		return nil, fmt.Errorf("stored credentials for %q are corrupt: %w", key, err)
	}
	return &t, nil
}

// Save stores t under key.
func Save(s Store, key string, t *Token) error {
	raw, err := json.Marshal(t) //nolint:gosec // G117: s is the secret store
	if err != nil {
		return err
	}
	return s.Set(key, string(raw))
}

// END token OMIT
// START errors OMIT

// Errors a login or refresh can end with. Commands turn them into
// messages; scripts see them as exit codes.
var (
	ErrDenied       = errors.New("the login was denied")
	ErrCodeExpired  = errors.New("the login code expired before it was used")
	ErrLoginExpired = errors.New("the login has expired; log in again")
)

// END errors OMIT
// START login OMIT

// Login runs the device authorization grant (RFC 8628). It asks the
// provider for a code, calls show so the person can open the URL on any
// device and enter the code, then polls until they approve or deny it, or
// the code expires. cfg needs ClientID and an Endpoint with DeviceAuthURL;
// set Endpoint.AuthStyle (see NewConfig).
func Login(ctx context.Context, cfg *oauth2.Config,
	show func(*oauth2.DeviceAuthResponse) error,
) (*Token, error) {
	da, err := cfg.DeviceAuth(ctx)
	if err != nil {
		return nil, fmt.Errorf("starting the login: %w", err)
	}
	if err := show(da); err != nil {
		return nil, err
	}
	tok, err := cfg.DeviceAccessToken(ctx, da)
	if re, ok := errors.AsType[*oauth2.RetrieveError](err); ok {
		switch re.ErrorCode {
		case "access_denied":
			return nil, ErrDenied
		case "expired_token":
			return nil, ErrCodeExpired
		}
	}
	if errors.Is(err, context.DeadlineExceeded) && ctx.Err() == nil {
		return nil, ErrCodeExpired // the code's own deadline, not ours
	}
	if err != nil {
		return nil, err
	}
	return fromOAuth2(tok, ""), nil
}

// NewConfig returns the oauth2 configuration for a public client (one with
// no secret, like every CLI) at the given endpoints. It sets AuthStyle:
// left unset, x/oauth2 sends each failing token request twice (Basic auth,
// then form) to discover the style, so every pending device poll arrives as
// a pair and a strict provider answers the second with slow_down.
func NewConfig(clientID string, ep oauth2.Endpoint, scopes ...string) *oauth2.Config {
	ep.AuthStyle = oauth2.AuthStyleInParams
	return &oauth2.Config{ClientID: clientID, Endpoint: ep, Scopes: scopes}
}

// END login OMIT
// START source OMIT

// Source returns a token source for the token stored under key. It returns
// the stored access token while it is valid, and otherwise refreshes it and
// saves the result. ctx bounds the refresh and the wait for the lock.
// cfg is called only when a refresh is needed: for an OIDC provider it
// runs discovery, a network round trip most commands never need.
//
// Refresh tokens rotate: each one works once. Two plat processes that
// both find an expired token (a deploy in one terminal, logs in another)
// must not both refresh with it, or the provider sees a reuse and revokes
// the login. So the refresh holds lockPath, a file lock shared by every
// process, and re-reads the store after taking it: the process that lost
// the race finds the token the winner just saved.
func NewSource(ctx context.Context, cfg func() (*oauth2.Config, error),
	s Store, key, lockPath string,
) *Source {
	return &Source{ctx: ctx, cfg: cfg, store: s, key: key, lockPath: lockPath}
}

// Source is an oauth2.TokenSource backed by a Store. It is safe for
// concurrent use.
type Source struct {
	ctx           context.Context
	cfg           func() (*oauth2.Config, error)
	store         Store
	key, lockPath string

	mu       sync.Mutex
	cur      *Token
	rejected string // an access token the server refused
}

// Invalidate reports that the server rejected the access token rejected
// (401 Unauthorized) although its expiry says it is still good: it was
// revoked, or a clock is wrong. The next Token call refreshes.
func (s *Source) Invalidate(rejected string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.rejected = rejected
	if s.cur != nil && s.cur.AccessToken == rejected {
		s.cur = nil
	}
}

// usable reports whether t can be sent: not expired (oauth2.Token.Valid
// treats a token as expired ten seconds early) and not rejected.
func (s *Source) usable(t *Token) bool {
	return t.oauth2().Valid() && t.AccessToken != s.rejected
}

// Token returns a usable access token, refreshing if necessary.
func (s *Source) Token() (*oauth2.Token, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cur != nil && s.usable(s.cur) {
		return s.cur.oauth2(), nil
	}
	t, err := Load(s.store, s.key)
	if err != nil {
		return nil, err
	}
	if s.usable(t) {
		s.cur = t
		return t.oauth2(), nil
	}

	lock, err := fsx.Acquire(s.ctx, s.lockPath)
	if err != nil {
		return nil, fmt.Errorf("waiting to refresh the login: %w", err)
	}
	defer func() { _ = lock.Unlock() }()
	if t, err = Load(s.store, s.key); err != nil { // another process may
		return nil, err // have refreshed while we waited
	}
	if !s.usable(t) {
		if t, err = s.refresh(t); err != nil {
			return nil, err
		}
	}
	s.cur = t
	return t.oauth2(), nil
}

// refresh exchanges t's refresh token and saves the new pair. A rejected
// refresh token (expired, revoked, or reused) means only a new login helps.
func (s *Source) refresh(t *Token) (*Token, error) {
	if t.RefreshToken == "" {
		return nil, ErrLoginExpired
	}
	// Hand x/oauth2 the refresh token alone. Given the whole token, its
	// TokenSource returns the access token unchanged while it looks valid,
	// which is exactly the case after Invalidate.
	cfg, err := s.cfg()
	if err != nil {
		return nil, err
	}
	only := &oauth2.Token{RefreshToken: t.RefreshToken}
	fresh, err := cfg.TokenSource(s.ctx, only).Token()
	if re, ok := errors.AsType[*oauth2.RetrieveError](err); ok &&
		re.ErrorCode == "invalid_grant" {
		return nil, fmt.Errorf("%w (%s)", ErrLoginExpired, re.ErrorDescription)
	}
	if err != nil {
		return nil, fmt.Errorf("refreshing the login: %w", err)
	}
	nt := fromOAuth2(fresh, t.IDToken)
	if err := Save(s.store, s.key, nt); err != nil {
		return nil, fmt.Errorf("saving the refreshed login: %w", err)
	}
	return nt, nil
}

// END source OMIT
