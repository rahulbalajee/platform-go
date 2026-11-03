// START top OMIT
// START head OMIT

package sweep_test

import (
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"

	"sweep/internal/sweep"
)

// END head OMIT

// START project OMIT
// parsed is the part of a Target the tests care about. Comparing a
// projection keeps *url.URL internals out of the assertions.
type parsed struct {
	Index int
	Kind  sweep.Kind
	Host  string
	Raw   string
}

func project(ts []sweep.Target) []parsed {
	out := make([]parsed, 0, len(ts))
	for _, t := range ts {
		out = append(out, parsed{t.Index, t.Kind, t.Host(), t.Raw})
	}
	return out
}

// END project OMIT
// END top OMIT

// START table OMIT
func TestParseTargets(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want []parsed
	}{{
		name: "http/path and query",
		in:   "https://api.example.com/healthz?deep=1",
		want: []parsed{{0, sweep.KindHTTP, "api.example.com",
			"https://api.example.com/healthz?deep=1"}},
	}, {
		name: "http/scheme is case-insensitive",
		in:   "HTTPS://Example.com/",
		want: []parsed{{0, sweep.KindHTTP, "Example.com", "HTTPS://Example.com/"}},
	}, {
		name: "tcp/ipv6 literal",
		in:   "tcp://[::1]:5432",
		want: []parsed{{0, sweep.KindTCP, "[::1]:5432", "tcp://[::1]:5432"}},
	}, {
		name: "tls/host and port",
		in:   "tls://example.com:443",
		want: []parsed{{0, sweep.KindTLS, "example.com:443",
			"tls://example.com:443"}},
	}, {
		name: "inventory/comments, blanks and indentation",
		in:   "# staging\n\n  dns://example.com  \n\t# db\ntcp://db:5432\n",
		want: []parsed{
			{0, sweep.KindDNS, "example.com", "dns://example.com"},
			{1, sweep.KindTCP, "db:5432", "tcp://db:5432"},
		},
	}}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := sweep.ParseTargets(strings.NewReader(tc.in))
			if err != nil {
				t.Fatalf("ParseTargets(%q): %v", tc.in, err)
			}
			if diff := cmp.Diff(tc.want, project(got)); diff != "" {
				t.Errorf("ParseTargets(%q) mismatch (-want +got):\n%s", tc.in, diff)
			}
		})
	}
}

// END table OMIT

// START errors OMIT
func TestParseTargetsRejects(t *testing.T) {
	tests := map[string]struct{ in, want string }{
		"unsupported scheme": {"ftp://files.example.com", `unsupported scheme "ftp"`},
		"tcp without port":   {"tcp://db.example.com", "tcp targets need host:port"},
		"missing host":       {"https:///healthz", "missing host"},
		"unparseable":        {"http://[::1", "missing ']' in host"},
		"line numbers": {
			"# fleet\nhttps://ok.example.com\nftp://a\ntcp://b\n",
			"line 3: \"ftp://a\": unsupported scheme \"ftp\" (want http, https, " +
				"tcp, tls, dns)\n  line 4: \"tcp://b\": tcp targets need host:port",
		},
		// START portrows OMIT
		// Found by FuzzParseTargets: url.Parse accepts any digits as a port.
		"port out of range": {"tcp://db.example.com:100000", "invalid port"},
		"port zero":         {"https://example.com:0/", "invalid port"},
		// END portrows OMIT
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			_, err := sweep.ParseTargets(strings.NewReader(tc.in))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Errorf("ParseTargets(%q) error = %v, want it to contain %q",
					tc.in, err, tc.want)
			}
		})
	}
}

// END errors OMIT
