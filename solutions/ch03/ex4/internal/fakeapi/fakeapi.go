// Package fakeapi is a small stand-in for a deployment API, used by the
// deployctl example and its tests. Each target name has fixed behaviour so
// every failure mode can be triggered on demand:
//
//	eu-west-1   503: the health check after rollout keeps failing
//	sa-east-1   409: another deploy is already in progress
//	ap-south-1  slow: answers after Options.Slow (default 3s)
//	anything    200 after 100ms
//
// Every request needs "Authorization: Bearer " + Token. Every response
// carries an X-Request-Id header, as real APIs do.
package fakeapi

import (
	"crypto/rand"
	"encoding/json"
	"io"
	"net/http"
	"time"
)

// Token is the only bearer token the fake API accepts. It is not a secret.
const Token = "dev-token"

// Options tune the fake API. The zero value is what the book's captures use.
type Options struct {
	Slow time.Duration // how long ap-south-1 takes; default 3s
	Fast time.Duration // how long other targets take; default 100ms
}

// Release is one version of the service on a target.
type Release struct {
	Version    string `json:"version"`
	DeployedAt string `json:"deployed_at"`
}

// TargetStatus is one row of GET /v1/status.
type TargetStatus struct {
	Target   string   `json:"target"`
	Version  string   `json:"version"`
	Previous *Release `json:"previous"` // null for a first deploy
}

// New returns the API's handler.
func New(opts Options) http.Handler {
	if opts.Slow == 0 {
		opts.Slow = 3 * time.Second
	}
	if opts.Fast == 0 {
		opts.Fast = 100 * time.Millisecond
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/whoami", func(w http.ResponseWriter, _ *http.Request) {
		reply(w, http.StatusOK, map[string]string{"user": "rahul"})
	})
	mux.HandleFunc("POST /v1/deploy/{target}", func(w http.ResponseWriter,
		r *http.Request) {

		// Read the body first: only then does the server notice a client
		// that hangs up, and cancel r.Context() for the slow path below.
		_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 1<<20))
		target := r.PathValue("target")
		delay := opts.Fast
		switch target {
		case "eu-west-1":
			reply(w, http.StatusServiceUnavailable,
				problem("health check failing on 3/3 replicas"))
			return
		case "sa-east-1":
			reply(w, http.StatusConflict,
				problem("deploy already in progress, started by ci-bot"))
			return
		case "ap-south-1":
			delay = opts.Slow
		}
		select {
		case <-time.After(delay):
		case <-r.Context().Done(): // the client gave up; so do we
			return
		}
		reply(w, http.StatusOK, map[string]string{"target": target})
	})
	mux.HandleFunc("GET /v1/status", func(w http.ResponseWriter, _ *http.Request) {
		reply(w, http.StatusOK, []TargetStatus{
			{"us-east-1", "v1.4.1", &Release{"v1.4.0", "2026-10-28T09:12:00Z"}},
			{"ap-south-1", "v1.4.1", nil}, // a region added last week
		})
	})
	return withAuth(mux)
}

// withAuth stamps a request ID on every response and rejects bad tokens.
func withAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Request-Id", "req-"+rand.Text()[:10])
		if r.Header.Get("Authorization") != "Bearer "+Token {
			reply(w, http.StatusUnauthorized, problem("token is invalid or expired"))
			return
		}
		next.ServeHTTP(w, r)
	})
}

func problem(msg string) map[string]string { return map[string]string{"error": msg} }

func reply(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
