package sweep

import (
	"testing"
	"time"
)

// TestParseRetryAfterFollowsRFC9110 pins the delay-seconds grammar of
// RFC 9110, section 10.2.3: one or more ASCII digits, nothing else.
func TestParseRetryAfterFollowsRFC9110(t *testing.T) {
	for _, v := range []string{"+5", "-0", "5s", " 5", "0x10", "1e3", "٣"} {
		if d, ok := parseRetryAfter(v); ok {
			t.Errorf("parseRetryAfter(%q) = %v, true; want it rejected", v, d)
		}
	}
	for v, want := range map[string]time.Duration{
		"0":   0,
		"007": 7 * time.Second,
		"120": 2 * time.Minute,
	} {
		if got, ok := parseRetryAfter(v); !ok || got != want {
			t.Errorf("parseRetryAfter(%q) = %v, %v; want %v, true", v, got, ok, want)
		}
	}
}
