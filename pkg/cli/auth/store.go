// START head OMIT

// Package auth is the login layer of the CLI framework: where credentials
// are stored (the OS keychain, or a private file where there is none), how
// a person logs in from a terminal (the OAuth 2.0 device authorization
// grant), and how an expired access token is refreshed without a second
// login and without two processes spending the same refresh token.
package auth

// END head OMIT
// START imports OMIT

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/zalando/go-keyring"

	"github.com/rahulbalajee/platform-go/pkg/fsx"
)

// END imports OMIT
// START store OMIT

// ErrNotFound means a store holds nothing under that key.
var ErrNotFound = errors.New("no stored credentials")

// Store keeps one secret per key; the CLI uses context names as keys.
type Store interface {
	Get(key string) (string, error) // ErrNotFound if there is none
	Set(key, secret string) error
	Delete(key string) error // deleting a missing key is not an error
	Name() string            // "keyring", "file" or "memory", for status output
}

// END store OMIT
// START keyring OMIT

// Keyring stores secrets in the operating system's credential store: the
// macOS keychain, the Secret Service (GNOME Keyring, KWallet) on Linux, or
// the Windows Credential Manager. Secrets are encrypted at rest and other
// users' processes cannot read them.
type Keyring struct{ Service string }

// Get returns the secret stored under key.
func (k Keyring) Get(key string) (string, error) {
	s, err := keyring.Get(k.Service, key)
	if errors.Is(err, keyring.ErrNotFound) {
		return "", ErrNotFound
	}
	return s, err
}

// Set stores secret under key, replacing any previous one. On macOS the
// whole request to the keychain must fit in 4 KiB, which a set of JWTs
// can exceed; the error then says to use the file store.
func (k Keyring) Set(key, secret string) error {
	err := keyring.Set(k.Service, key, secret)
	if errors.Is(err, keyring.ErrSetDataTooBig) {
		return fmt.Errorf("%w (%d bytes); set the credential store to "+
			"\"file\" instead", err, len(secret))
	}
	return err
}

// Delete removes the secret stored under key.
func (k Keyring) Delete(key string) error {
	if err := keyring.Delete(k.Service, key); err != nil &&
		!errors.Is(err, keyring.ErrNotFound) {
		return err
	}
	return nil
}

// Name returns "keyring".
func (Keyring) Name() string { return "keyring" }

// END keyring OMIT
// START file OMIT

// File stores secrets in a JSON file that only the user can read (0600), for
// machines without a keychain: CI runners, containers, SSH sessions on a
// headless Linux box. Anyone who can read the file, root included, can use
// the tokens in it, which is why it is the fallback, not the default.
type File struct{ Path string }

// Get returns the secret stored under key.
func (f File) Get(key string) (string, error) {
	m, err := f.read()
	if err != nil {
		return "", err
	}
	s, ok := m[key]
	if !ok {
		return "", ErrNotFound
	}
	return s, nil
}

// Set stores secret under key. Read, modify and write happen under a lock,
// so two processes saving tokens for different contexts don't lose one.
func (f File) Set(key, secret string) error {
	return f.update(func(m map[string]string) { m[key] = secret })
}

// Delete removes the secret stored under key.
func (f File) Delete(key string) error {
	return f.update(func(m map[string]string) { delete(m, key) })
}

// Name returns "file".
func (File) Name() string { return "file" }

func (f File) read() (map[string]string, error) {
	data, err := os.ReadFile(f.Path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, err
	}
	m := map[string]string{}
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("%s: %w", f.Path, err)
	}
	return m, nil
}

func (f File) update(change func(map[string]string)) error {
	if err := os.MkdirAll(filepath.Dir(f.Path), 0o700); err != nil {
		return err
	}
	// The lock is held for one small read and write; waiting longer than
	// a few seconds means something is wrong, so give up with an error.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	lock, err := fsx.Acquire(ctx, f.Path+".lock")
	if err != nil {
		return fmt.Errorf("locking %s: %w", f.Path, err)
	}
	defer func() { _ = lock.Unlock() }()
	m, err := f.read()
	if err != nil {
		return err
	}
	change(m)
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return fsx.WriteFile(f.Path, data, 0o600)
}

// END file OMIT
// START memory OMIT

// Memory is a Store for tests.
type Memory struct {
	mu sync.Mutex
	m  map[string]string
}

// Get returns the secret stored under key.
func (s *Memory) Get(key string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.m[key]
	if !ok {
		return "", ErrNotFound
	}
	return v, nil
}

// Set stores secret under key.
func (s *Memory) Set(key, secret string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.m == nil {
		s.m = map[string]string{}
	}
	s.m[key] = secret
	return nil
}

// Delete removes the secret stored under key.
func (s *Memory) Delete(key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.m, key)
	return nil
}

// Name returns "memory".
func (*Memory) Name() string { return "memory" }

// END memory OMIT
// START open OMIT

// Open returns the store to use. mode is "keyring", "file" or "auto" (or
// empty): auto uses the keyring if one answers, and otherwise falls back to
// a file in dir and returns a warning to show the person, because they
// should know their tokens are in a plain file.
func Open(service, dir, mode string) (store Store, warning string, err error) {
	file := File{Path: filepath.Join(dir, "credentials.json")}
	switch mode {
	case "keyring":
		return Keyring{Service: service}, "", nil
	case "file":
		return file, "", nil
	case "", "auto":
		k := Keyring{Service: service}
		if _, err := k.Get("probe"); err == nil || errors.Is(err, ErrNotFound) {
			return k, "", nil
		}
		return file, fmt.Sprintf("no OS keychain is available; credentials "+
			"are stored in %s, readable by your user", file.Path), nil
	}
	return nil, "", fmt.Errorf("unknown credential store %q: want auto, "+
		"keyring or file", mode)
}

// END open OMIT
