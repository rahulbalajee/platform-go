// START head OMIT

package sweep_test

import (
	"strconv"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"

	"sweep/internal/sweep"
)

// END head OMIT

// START fuzz OMIT

// FuzzParseTargets checks ParseTargets' contract on arbitrary input: it
// never panics, and anything it accepts can be probed and parses again to
// the same result.
func FuzzParseTargets(f *testing.F) {
	for _, seed := range []string{
		"https://api.example.com/healthz",
		"tcp://db.internal:5432\ntls://example.com:443",
		"# staging\n\n  dns://example.com\n",
		"tcp://[::1]:6379",
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, in string) {
		targets, err := sweep.ParseTargets(strings.NewReader(in))
		if err != nil {
			return // rejecting input is fine; accepting junk is not
		}
		var again strings.Builder
		for i, tg := range targets {
			if tg.Index != i || tg.URL.Hostname() == "" {
				t.Fatalf("target %d: bad index or empty host: %+v", i, tg)
			}
			// What the parser accepts, the runner must be able to dial.
			if p := tg.URL.Port(); p != "" {
				if n, err := strconv.Atoi(p); err != nil || n < 1 || n > 65535 {
					t.Fatalf("accepted %q with port %q", tg.Raw, p)
				}
			}
			again.WriteString(tg.Raw + "\n")
		}
		reparsed, err := sweep.ParseTargets(strings.NewReader(again.String()))
		if err != nil {
			t.Fatalf("accepted lines fail to parse again: %v", err)
		}
		if diff := cmp.Diff(project(targets), project(reparsed)); diff != "" {
			t.Fatalf("round trip changed targets (-first +second):\n%s", diff)
		}
	})
}

// END fuzz OMIT
