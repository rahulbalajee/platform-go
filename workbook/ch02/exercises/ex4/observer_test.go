package platformapi_test

import (
	"net/http"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"platformapi"
	"platformapi/retry"
)

func TestObserverSeesEveryAttempt(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var seen []platformapi.Attempt
		record := func(a platformapi.Attempt) { seen = append(seen, a) }
		client, fake := newClient(t, platformapi.WithObserver(record))
		fake.FailNext(2, http.StatusServiceUnavailable, 0)
		if _, err := client.GetEnvironment(t.Context(), "dev"); err != nil {
			t.Fatal(err)
		}
		if len(seen) != 3 {
			t.Fatalf("observed %d attempts, want 3: %+v", len(seen), seen)
		}
		rid := fake.Requests()[0].RequestID
		for i, a := range seen {
			status := http.StatusServiceUnavailable
			if i == 2 {
				status = http.StatusOK
			}
			if a.Call != "GET /v1/environments/dev" || a.Attempt != i+1 ||
				a.Status != status || a.RequestID != rid {
				t.Errorf("attempt %d = %+v", i+1, a)
			}
			if failed := a.Err != nil; failed != (i < 2) {
				t.Errorf("attempt %d: Err = %v", i+1, a.Err)
			}
		}
	})
}

func TestObserverSeesNetworkErrors(t *testing.T) {
	var seen []platformapi.Attempt
	quick := retry.Policy{MaxAttempts: 2, BaseDelay: time.Millisecond}
	client, err := platformapi.New("http://127.0.0.1:1", // nothing listens here
		platformapi.WithRetry(quick),
		platformapi.WithObserver(func(a platformapi.Attempt) {
			seen = append(seen, a)
		}))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.GetEnvironment(t.Context(), "dev"); err == nil {
		t.Fatal("GetEnvironment succeeded against a closed port")
	}
	if len(seen) != 2 || seen[1].Attempt != 2 || seen[1].Status != 0 ||
		seen[1].Err == nil {
		t.Errorf("observed %+v, want two attempts with no status", seen)
	}
}

func TestNilObserverIsRejected(t *testing.T) {
	_, err := platformapi.New("https://platform.internal",
		platformapi.WithObserver(nil))
	if err == nil || !strings.Contains(err.Error(), "WithObserver") {
		t.Errorf("err = %v, want WithObserver to reject nil", err)
	}
}
