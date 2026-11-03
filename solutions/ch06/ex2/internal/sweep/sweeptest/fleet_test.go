// START head OMIT

package sweeptest_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"testing/synctest"
	"time"

	"sweep/internal/sweep/sweeptest"
)

// END head OMIT

// START get OMIT
func get(t *testing.T, c *http.Client, url string) int {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

// END get OMIT

// START behaviours OMIT
func TestFleetBehaviours(t *testing.T) {
	srv, fleet := sweeptest.NewServer(t)
	c := srv.Client()
	for _, tc := range []struct {
		path string
		want []int
	}{
		{"/ok", []int{200, 200}},
		{"/flaky", []int{502, 502, 200, 200}},
		{"/down", []int{503}},
		{"/missing", []int{404}},
	} {
		for i, want := range tc.want {
			if got := get(t, c, srv.URL+tc.path); got != want {
				t.Errorf("%s request %d: status %d, want %d", tc.path, i+1, got, want)
			}
		}
		if got := fleet.Hits(tc.path); got != len(tc.want) {
			t.Errorf("Hits(%s) = %d, want %d", tc.path, got, len(tc.want))
		}
	}
}

// END behaviours OMIT

// START waitfor OMIT
func TestWaitForUnblocksOnRequest(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		fleet := sweeptest.NewFleet()
		fleet.SlowFor = 10 * time.Second
		srv := httptest.NewTestServer(t, fleet)

		done := make(chan error, 1)
		go func() { done <- fleet.WaitFor(t.Context(), "/slow", 1) }()
		synctest.Wait()
		select {
		case err := <-done:
			t.Fatalf("WaitFor returned %v before any request", err)
		default:
		}

		start := time.Now()
		if got := get(t, srv.Client(), srv.URL+"/slow"); got != 200 {
			t.Errorf("/slow status = %d, want 200 after stalling", got)
		}
		if err := <-done; err != nil {
			t.Fatal(err)
		}
		if el := time.Since(start); el != 10*time.Second {
			t.Errorf("/slow stalled for %v, want 10s", el)
		}
	})
}

func TestWaitForHonoursContext(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithTimeout(t.Context(), time.Second)
		defer cancel()
		err := sweeptest.NewFleet().WaitFor(ctx, "/ok", 1)
		if err == nil {
			t.Fatal("WaitFor returned nil without any request")
		}
	})
}

// END waitfor OMIT
