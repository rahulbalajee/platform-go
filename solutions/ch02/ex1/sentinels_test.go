package platformapi_test

import (
	"errors"
	"net/http"
	"testing"
	"testing/synctest"

	"platformapi"
	"platformapi/retry"
)

func TestErrUnauthorized(t *testing.T) {
	client, _ := newClient(t, platformapi.WithToken("stale-token"))
	_, err := client.GetEnvironment(t.Context(), "dev")
	if !errors.Is(err, platformapi.ErrUnauthorized) {
		t.Fatalf("err = %v, want ErrUnauthorized", err)
	}
	for _, other := range []error{platformapi.ErrNotFound, platformapi.ErrConflict,
		platformapi.ErrRateLimited} {
		if errors.Is(err, other) {
			t.Errorf("a 401 must not match %v", other)
		}
	}
}

func TestErrRateLimitedSurvivesRetries(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		twice := platformapi.WithRetry(retry.Policy{MaxAttempts: 2})
		client, fake := newClient(t, twice)
		fake.FailNext(5, http.StatusTooManyRequests, 0)
		_, err := client.GetEnvironment(t.Context(), "dev")
		if _, ok := errors.AsType[*retry.ExhaustedError](err); !ok {
			t.Fatalf("err = %v, want the client to have retried", err)
		}
		if !errors.Is(err, platformapi.ErrRateLimited) {
			t.Errorf("err = %v, want ErrRateLimited through the retry wrapper", err)
		}
		if errors.Is(err, platformapi.ErrUnauthorized) {
			t.Error("a 429 must not match ErrUnauthorized")
		}
	})
}

func TestSentinelsAreDistinctErrors(t *testing.T) {
	if platformapi.ErrUnauthorized.Error() != "platformapi: unauthorized" ||
		platformapi.ErrRateLimited.Error() != "platformapi: rate limited" {
		t.Errorf("messages: %q, %q", platformapi.ErrUnauthorized,
			platformapi.ErrRateLimited)
	}
}
