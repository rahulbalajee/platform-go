package sweep

import (
	"math"
	"net/http"
	"testing"
	"time"
)

// START fuzz OMIT
// FuzzParseRetryAfter checks the Retry-After parser on arbitrary header
// values: a value it accepts is a delay, and delays are never negative.
func FuzzParseRetryAfter(f *testing.F) {
	f.Add("120")
	f.Add("0")
	f.Add("Wed, 21 Oct 2015 07:28:00 GMT")
	f.Fuzz(func(t *testing.T, v string) {
		d, ok := parseRetryAfter(v)
		switch {
		case !ok && d != 0:
			t.Fatalf("%q -> %v, false; want 0 when rejected", v, d)
		case ok && d < 0:
			t.Fatalf("%q -> %v, want >= 0", v, d)
		}
	})
}

// END fuzz OMIT

func TestParseRetryAfter(t *testing.T) {
	future := time.Now().Add(90 * time.Second).UTC().Format(http.TimeFormat)
	tests := []struct {
		in     string
		want   time.Duration
		wantOK bool
	}{
		{"", 0, false},
		{"120", 120 * time.Second, true},
		{"-1", 0, false},
		{"soon", 0, false},
		{"Wed, 21 Oct 2015 07:28:00 GMT", 0, true}, // in the past: retry now
		// Found by FuzzParseRetryAfter: this used to overflow to -2553746h.
		{"27700000000", math.MaxInt64 / time.Second * time.Second, true},
	}
	for _, tc := range tests {
		got, ok := parseRetryAfter(tc.in)
		if got != tc.want || ok != tc.wantOK {
			t.Errorf("parseRetryAfter(%q) = %v, %v; want %v, %v",
				tc.in, got, ok, tc.want, tc.wantOK)
		}
	}
	// An HTTP date in the future yields roughly the time until then.
	if got, ok := parseRetryAfter(future); !ok || got < 80*time.Second ||
		got > 90*time.Second {
		t.Errorf("parseRetryAfter(%q) = %v, %v; want about 90s", future, got, ok)
	}
}
