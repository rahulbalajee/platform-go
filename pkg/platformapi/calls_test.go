// START head OMIT

package platformapi_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

var staging = platformapi.CreateDeploymentRequest{
	Service: "checkout", Environment: "staging", Version: "v1.5.0",
}

func TestEveryCallHasARequestID(t *testing.T) {
	client, fake := newClient(t)
	if _, err := client.GetService(t.Context(), "checkout"); err != nil {
		t.Fatal(err)
	}
	if _, err := client.GetService(t.Context(), "ledger",
		platformapi.RequestID("ci-run-77")); err != nil {
		t.Fatal(err)
	}
	reqs := fake.Requests()
	if id := reqs[0].RequestID; len(id) != 36 || id[14] != '7' {
		t.Errorf("default request ID %q is not a UUIDv7", id)
	}
	if got := reqs[1].RequestID; got != "ci-run-77" {
		t.Errorf("request ID = %q, want the caller's", got)
	}
}

// END head OMIT

// START ctx OMIT

func TestCancelledContextStopsTheCall(t *testing.T) {
	client, fake := newClient(t)
	ctx, cancel := context.WithCancel(t.Context())
	cancel() // the user pressed Ctrl-C before the call
	_, err := client.GetEnvironment(ctx, "dev")
	if !errors.Is(err, context.Canceled) {
		t.Errorf("err = %v, want context.Canceled", err)
	}
	if n := len(fake.Requests()); n != 0 {
		t.Errorf("sent %d requests on a cancelled context", n)
	}
}

func TestDeadlineCoversTheTokenFetch(t *testing.T) {
	stuck := platformapi.TokenSourceFunc(func(ctx context.Context) (string, error) {
		<-ctx.Done() // an identity provider that never answers
		return "", ctx.Err()
	})
	client, _ := newClient(t, platformapi.WithTokenSource(stuck))
	ctx, cancel := context.WithTimeout(t.Context(), 50*time.Millisecond)
	defer cancel()
	_, err := client.GetEnvironment(ctx, "dev")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("err = %v, want the caller's deadline", err)
	}
}

// END ctx OMIT

// START create OMIT

func TestCreateDeploymentSendsAnIdempotencyKey(t *testing.T) {
	client, fake := newClient(t)
	op, err := client.CreateDeployment(t.Context(), staging)
	if err != nil {
		t.Fatal(err)
	}
	if op.ID == "" || op.Done || op.Result.State != platformapi.StatePending {
		t.Errorf("operation = %+v, want a pending deployment", op)
	}
	if key := fake.Requests()[0].IdempotencyKey; len(key) != 36 {
		t.Errorf("Idempotency-Key = %q, want a UUID", key)
	}
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

// END create OMIT

// START validate OMIT

func TestCreateValidatesRequiredFields(t *testing.T) {
	client, fake := newClient(t)
	_, err := client.CreateDeployment(t.Context(),
		platformapi.CreateDeploymentRequest{Service: "checkout"})
	if err == nil || !strings.Contains(err.Error(),
		"Environment is required\nVersion is required") {
		t.Errorf("err = %v, want both missing fields reported", err)
	}
	if n := len(fake.Requests()); n != 0 {
		t.Errorf("sent %d requests for an invalid create", n)
	}
}

func TestConcurrentDeploymentIsAConflict(t *testing.T) {
	client, _ := newClient(t)
	if _, err := client.CreateDeployment(t.Context(), staging); err != nil {
		t.Fatal(err)
	}
	_, err := client.CreateDeployment(t.Context(), staging)
	if !errors.Is(err, platformapi.ErrConflict) {
		t.Errorf("second create = %v, want ErrConflict", err)
	}
}

func TestCancelDeployment(t *testing.T) {
	client, _ := newClient(t)
	op, err := client.CreateDeployment(t.Context(), staging)
	if err != nil {
		t.Fatal(err)
	}
	d, err := client.CancelDeployment(t.Context(), op.Result.ID)
	if err != nil || d.State != platformapi.StateCancelled {
		t.Fatalf("Cancel = %+v, %v", d, err)
	}
	if _, err := client.CancelDeployment(t.Context(), op.Result.ID); err != nil {
		t.Errorf("cancelling twice: %v", err)
	}
	_, err = client.CancelDeployment(t.Context(), "d-1") // succeeded long ago
	if !errors.Is(err, platformapi.ErrConflict) {
		t.Errorf("cancelling a finished deployment: %v, want ErrConflict", err)
	}
}

// END validate OMIT
