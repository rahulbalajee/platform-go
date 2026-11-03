// START head OMIT

package platformapi_test

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/time/rate"

	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

func TestNewReportsEveryProblem(t *testing.T) {
	_, err := platformapi.New("ftp://platform.internal",
		platformapi.WithUserAgent(""),
		platformapi.WithToken(""),
		platformapi.WithHTTPClient(nil),
	)
	if err == nil {
		t.Fatal("New succeeded with four invalid settings")
	}
	t.Log(err)
	for _, want := range []string{"scheme must be http or https",
		"WithUserAgent", "WithToken", "WithHTTPClient"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %q", err, want)
		}
	}
}

// END head OMIT

// START identified OMIT
func TestEveryRequestIsIdentified(t *testing.T) {
	client, fake := newClient(t)
	if _, err := client.GetService(t.Context(), "checkout"); err != nil {
		t.Fatal(err)
	}
	reqs := fake.Requests()
	if len(reqs) != 1 {
		t.Fatalf("got %d requests, want 1", len(reqs))
	}
	if got := reqs[0].UserAgent; got != "ship/0.0.1 platformapi-go/1.0.0" {
		t.Errorf("User-Agent = %q", got)
	}
	if got := reqs[0].Authorization; got != "Bearer test-token" {
		t.Errorf("Authorization = %q", got)
	}
}

func TestWrongTokenIsRejected(t *testing.T) {
	client, _ := newClient(t, platformapi.WithToken("stale-token"))
	_, err := client.GetService(t.Context(), "checkout")
	if err == nil || !strings.Contains(err.Error(), "401") {
		t.Errorf("err = %v, want a 401", err)
	}
}

func TestTokenSourceErrorStopsTheCall(t *testing.T) {
	sealed := platformapi.TokenSourceFunc(func(context.Context) (string, error) {
		return "", errors.New("vault is sealed")
	})
	client, fake := newClient(t, platformapi.WithTokenSource(sealed))
	_, err := client.GetEnvironment(t.Context(), "dev")
	if err == nil || !strings.Contains(err.Error(), "vault is sealed") {
		t.Errorf("err = %v, want the token source's error", err)
	}
	if n := len(fake.Requests()); n != 0 {
		t.Errorf("sent %d requests without a token", n)
	}
}

// END identified OMIT

// START limiter OMIT

// countingLimiter is a Limiter that never makes anyone wait. It counts
// how often it was asked.
type countingLimiter struct{ waits atomic.Int32 }

func (l *countingLimiter) Wait(context.Context) error {
	l.waits.Add(1)
	return nil
}

func TestLimiterIsConsultedBeforeEveryRequest(t *testing.T) {
	lim := &countingLimiter{}
	client, _ := newClient(t, platformapi.WithLimiter(lim))
	for range 3 {
		if _, err := client.GetEnvironment(t.Context(), "dev"); err != nil {
			t.Fatal(err)
		}
	}
	if n := lim.waits.Load(); n != 3 {
		t.Errorf("limiter consulted %d times, want 3", n)
	}
}

// *rate.Limiter has the one method Limiter asks for, so it is a Limiter.
// Neither package mentions the other.
var _ platformapi.Limiter = (*rate.Limiter)(nil)

func TestRateLimiterSpacesRequests(t *testing.T) {
	lim := rate.NewLimiter(rate.Every(50*time.Millisecond), 1)
	client, _ := newClient(t, platformapi.WithLimiter(lim))
	start := time.Now()
	for range 3 { // the first is free, then one every 50ms
		if _, err := client.GetEnvironment(t.Context(), "dev"); err != nil {
			t.Fatal(err)
		}
	}
	if el := time.Since(start); el < 90*time.Millisecond {
		t.Errorf("3 requests took %v, want about 100ms", el)
	}
}

// END limiter OMIT
