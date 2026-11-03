package platformapi_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/platformapi"
	"github.com/rahulbalajee/platform-go/pkg/platformapi/platformapifake"
	"github.com/rahulbalajee/platform-go/pkg/retry"
)

// START fixture OMIT

// newClient starts a fake platform on httptest.NewTestServer's in-memory
// network (Go 1.27), so it also works inside a synctest bubble, and
// returns a client configured for it. opts are applied last.
func newClient(t *testing.T, opts ...platformapi.Option) (
	*platformapi.Client, *platformapifake.Server) {

	t.Helper()
	fake := platformapifake.New()
	fake.RequireToken("test-token")
	srv := httptest.NewTestServer(t, fake)
	base := []platformapi.Option{
		platformapi.WithHTTPClient(srv.Client()),
		platformapi.WithToken("test-token"),
		platformapi.WithUserAgent("ship/0.0.1"),
		platformapi.WithPollInterval(2 * time.Second),
	}
	client, err := platformapi.New(srv.URL, append(base, opts...)...)
	if err != nil {
		t.Fatal(err)
	}
	return client, fake
}

// END fixture OMIT

var staging = platformapi.CreateDeploymentRequest{
	Service: "checkout", Environment: "staging", Version: "v1.5.0",
}

// START newtest OMIT
func TestNewReportsEveryProblem(t *testing.T) {
	_, err := platformapi.New("ftp://platform.internal",
		platformapi.WithUserAgent(""),
		platformapi.WithPollInterval(0),
		platformapi.WithHTTPClient(nil),
	)
	if err == nil {
		t.Fatal("New succeeded with four invalid settings")
	}
	for _, want := range []string{"scheme must be http or https",
		"WithUserAgent", "WithPollInterval", "WithHTTPClient"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %q", err, want)
		}
	}
}

// END newtest OMIT

func TestNewAcceptsBaseURLWithPathPrefix(t *testing.T) {
	fake := platformapifake.New()
	mux := http.NewServeMux()
	mux.Handle("/api/", http.StripPrefix("/api", fake))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	client, err := platformapi.New(srv.URL + "/api/")
	if err != nil {
		t.Fatal(err)
	}
	env, err := client.GetEnvironment(t.Context(), "prod")
	if err != nil {
		t.Fatal(err)
	}
	if !env.Protected {
		t.Errorf("prod environment = %+v, want Protected", env)
	}
}

func TestEveryRequestIsIdentified(t *testing.T) {
	client, fake := newClient(t)
	if _, err := client.GetService(t.Context(), "checkout"); err != nil {
		t.Fatal(err)
	}
	if _, err := client.GetService(t.Context(), "ledger",
		platformapi.RequestID("ci-run-77")); err != nil {
		t.Fatal(err)
	}
	reqs := fake.Requests()
	if len(reqs) != 2 {
		t.Fatalf("got %d requests, want 2", len(reqs))
	}
	if got := reqs[0].UserAgent; got != "ship/0.0.1 platformapi-go/1.0.0" {
		t.Errorf("User-Agent = %q", got)
	}
	if got := reqs[0].Authorization; got != "Bearer test-token" {
		t.Errorf("Authorization = %q", got)
	}
	if id := reqs[0].RequestID; len(id) != 36 || id[14] != '7' {
		t.Errorf("default request ID %q is not a UUIDv7", id)
	}
	if got := reqs[1].RequestID; got != "ci-run-77" {
		t.Errorf("request ID = %q, want the caller's", got)
	}
}

func TestIDsCannotEscapeTheirPath(t *testing.T) {
	client, fake := newClient(t)
	_, err := client.GetDeployment(t.Context(), "../environments/prod")
	if !errors.Is(err, platformapi.ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
	if got := fake.Requests()[0].Path; got != "/v1/deployments/..%2Fenvironments%2Fprod" {
		t.Errorf("path = %q, want the ID escaped as one segment", got)
	}
	if _, err := client.GetDeployment(t.Context(), ".."); err == nil {
		t.Error(`GetDeployment("..") succeeded`)
	}
}

// START retrytest OMIT
func TestRetriesReuseTheIdempotencyKey(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, fake := newClient(t)
		fake.FailNext(2, http.StatusServiceUnavailable, 0)

		op, err := client.CreateDeployment(t.Context(), staging)
		if err != nil {
			t.Fatal(err)
		}
		reqs := fake.Requests()
		if len(reqs) != 3 {
			t.Fatalf("got %d requests, want 3 (two 503s, then success)", len(reqs))
		}
		for _, r := range reqs[1:] {
			if r.IdempotencyKey != reqs[0].IdempotencyKey ||
				r.RequestID != reqs[0].RequestID {
				t.Errorf("attempt sent key %q, request %q; want %q, %q",
					r.IdempotencyKey, r.RequestID,
					reqs[0].IdempotencyKey, reqs[0].RequestID)
			}
		}
		if op.ID == "" || op.Result.State != platformapi.StatePending {
			t.Errorf("operation = %+v, want a pending deployment", op)
		}
	})
}

// END retrytest OMIT

// START retryafter OMIT
func TestRetryAfterIsHonoured(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		policy := retry.Policy{MaxAttempts: 3, MaxDelay: time.Minute}
		client, fake := newClient(t, platformapi.WithRetry(policy))
		fake.FailNext(1, http.StatusTooManyRequests, 7*time.Second)

		start := time.Now()
		if _, err := client.GetEnvironment(t.Context(), "dev"); err != nil {
			t.Fatal(err)
		}
		if el := time.Since(start); el != 7*time.Second {
			t.Errorf("retried after %v of virtual time, want exactly 7s", el)
		}
	})
}

// END retryafter OMIT

func TestClientErrorsAreNotRetried(t *testing.T) {
	client, fake := newClient(t)
	_, err := client.GetDeployment(t.Context(), "d-404")
	if !errors.Is(err, platformapi.ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
	apiErr, ok := errors.AsType[*platformapi.APIError](err)
	if !ok {
		t.Fatalf("err = %T, want *APIError in the chain", err)
	}
	if apiErr.Code != "not_found" || apiErr.RequestID != fake.Requests()[0].RequestID {
		t.Errorf("APIError = %+v", apiErr)
	}
	if errors.Is(err, platformapi.ErrConflict) {
		t.Error("a 404 must not match ErrConflict")
	}
	if n := len(fake.Requests()); n != 1 {
		t.Errorf("sent %d requests, want 1: a 404 is not retryable", n)
	}
}

func TestRetriesGiveUp(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, fake := newClient(t)
		fake.FailNext(10, http.StatusBadGateway, 0)
		_, err := client.GetEnvironment(t.Context(), "dev")
		if _, ok := errors.AsType[*retry.ExhaustedError](err); !ok {
			t.Fatalf("err = %v, want *retry.ExhaustedError", err)
		}
		if apiErr, ok := errors.AsType[*platformapi.APIError](err); !ok ||
			apiErr.StatusCode != http.StatusBadGateway {
			t.Errorf("err = %v, want the last 502 in the chain", err)
		}
		if n := len(fake.Requests()); n != 4 {
			t.Errorf("sent %d requests, want the default 4 attempts", n)
		}
	})
}

func TestIdempotencyKeyMakesCreateRepeatable(t *testing.T) {
	client, fake := newClient(t)
	key := platformapi.IdempotencyKey("pipeline-981-staging")
	first, err := client.CreateDeployment(t.Context(), staging, key)
	if err != nil {
		t.Fatal(err)
	}
	// The process restarts and runs the same step again.
	second, err := client.CreateDeployment(t.Context(), staging, key)
	if err != nil {
		t.Fatal(err)
	}
	if first.ID != second.ID {
		t.Errorf("replayed create returned %s, want %s", second.ID, first.ID)
	}
	other := staging
	other.Version = "v9.9.9"
	_, err = client.CreateDeployment(t.Context(), other, key)
	if apiErr, ok := errors.AsType[*platformapi.APIError](err); !ok ||
		apiErr.Code != "idempotency_mismatch" {
		t.Errorf("reusing a key for a different request: err = %v", err)
	}
	if n := len(fake.Requests()); n != 3 {
		t.Errorf("sent %d requests, want 3", n)
	}
}

func TestCreateValidatesRequiredFields(t *testing.T) {
	client, fake := newClient(t)
	_, err := client.CreateDeployment(t.Context(),
		platformapi.CreateDeploymentRequest{Service: "checkout"})
	if err == nil || !strings.Contains(err.Error(), "Environment is required\nVersion is required") {
		t.Errorf("err = %v, want both missing fields reported", err)
	}
	if n := len(fake.Requests()); n != 0 {
		t.Errorf("sent %d requests for an invalid create", n)
	}
}

// cachingTokens caches one token and counts how often it is invalidated.
type cachingTokens struct {
	mu          sync.Mutex
	cached      string
	issue       func() string
	invalidated atomic.Int32
}

func (c *cachingTokens) Token(context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cached == "" {
		c.cached = c.issue()
	}
	return c.cached, nil
}

func (c *cachingTokens) InvalidateToken(rejected string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cached == rejected { // another request may have refreshed it already
		c.cached = ""
		c.invalidated.Add(1)
	}
}

func TestRejectedTokenIsRefreshedOnce(t *testing.T) {
	current := "token-1"
	tokens := &cachingTokens{issue: func() string { return current }}
	client, fake := newClient(t, platformapi.WithTokenSource(tokens))
	fake.RequireToken("token-1")
	if _, err := client.GetService(t.Context(), "checkout"); err != nil {
		t.Fatal(err)
	}

	current = "token-2" // the identity provider rotates credentials
	fake.RequireToken("token-2")
	if _, err := client.GetService(t.Context(), "checkout"); err != nil {
		t.Fatalf("after rotation: %v", err)
	}
	if n := tokens.invalidated.Load(); n != 1 {
		t.Errorf("invalidated %d times, want 1", n)
	}

	fake.RequireToken("token-3") // a token the source will never issue
	_, err := client.GetService(t.Context(), "checkout")
	if apiErr, ok := errors.AsType[*platformapi.APIError](err); !ok ||
		apiErr.StatusCode != http.StatusUnauthorized {
		t.Errorf("err = %v, want a 401 after one refresh attempt", err)
	}
}

type countingLimiter struct{ waits atomic.Int32 }

func (l *countingLimiter) Wait(context.Context) error {
	l.waits.Add(1)
	return nil
}

func TestLimiterGatesEveryAttempt(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		lim := &countingLimiter{}
		client, fake := newClient(t, platformapi.WithLimiter(lim))
		fake.FailNext(2, http.StatusServiceUnavailable, 0)
		if _, err := client.GetEnvironment(t.Context(), "dev"); err != nil {
			t.Fatal(err)
		}
		if n := lim.waits.Load(); n != 3 {
			t.Errorf("limiter consulted %d times, want once per attempt (3)", n)
		}
	})
}
