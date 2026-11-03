package alerting_test

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"watchtower/internal/alerting"
)

// TestDatadogRateLimitIsReported: a 429 becomes a *RateLimitedError that
// says how long to wait, from Datadog's X-RateLimit-Reset header.
func TestDatadogRateLimitIsReported(t *testing.T) {
	for name, tc := range map[string]struct {
		reset string
		want  time.Duration
	}{
		"reset header":   {"7", 7 * time.Second},
		"no header":      {"", time.Minute},
		"not a number":   {"soon", time.Minute},
		"absurdly large": {"86400", time.Hour},
	} {
		t.Run(name, func(t *testing.T) {
			h := func(w http.ResponseWriter, _ *http.Request) {
				if tc.reset != "" {
					w.Header().Set("X-RateLimit-Reset", tc.reset)
				}
				http.Error(w, `{"errors":["Rate limit exceeded"]}`,
					http.StatusTooManyRequests)
			}
			srv := httptest.NewServer(http.HandlerFunc(h))
			defer srv.Close()
			dd := &alerting.Datadog{
				BaseURL: srv.URL, APIKey: "k", AppKey: "a", HTTP: srv.Client(),
			}
			_, err := dd.Ensure(t.Context(), check())
			rl, ok := errors.AsType[*alerting.RateLimitedError](err)
			if !ok || rl.RetryAfter != tc.want {
				t.Fatalf("err = %v; want *RateLimitedError with RetryAfter %s",
					err, tc.want)
			}
		})
	}
}
