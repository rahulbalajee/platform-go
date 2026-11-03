// START imports OMIT
package buildinfo

import (
	"bytes"
	"encoding/json"
	"runtime"
	"runtime/debug"
	"strings"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
)

// END imports OMIT

// START fixtures OMIT

// The fixtures use the text format that `go version -m` prints, which
// debug.ParseBuildInfo reads back. Each one is a real kind of build.
const (
	// go build inside a Git checkout with uncommitted changes (Go 1.24+
	// stamps the main module version from VCS and appends +dirty).
	devBuild = "go\tgo1.27.3\n" +
		"path\texample.com/fleet/cmd/sweep\n" +
		"mod\texample.com/fleet\tv0.0.0-20261102140731-3f9c2a1b7d4e+dirty\t\n" +
		"build\t-trimpath=true\n" +
		"build\tvcs=git\n" +
		"build\tvcs.revision=3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345\n" +
		"build\tvcs.time=2026-11-02T14:07:31Z\n" +
		"build\tvcs.modified=true\n"

	// go install example.com/fleet/cmd/sweep@v1.4.0: the module
	// version is known, but there is no checkout, so no vcs.* settings.
	installBuild = "go\tgo1.27.3\n" +
		"path\texample.com/fleet/cmd/sweep\n" +
		"mod\texample.com/fleet\tv1.4.0\th1:abc=\n"

	// go run and go test: no version, no VCS information.
	runBuild = "go\tgo1.27.3\n" +
		"path\texample.com/fleet/cmd/sweep\n" +
		"mod\texample.com/fleet\t(devel)\t\n"
)

func parse(t *testing.T, s string) *debug.BuildInfo {
	t.Helper()
	bi, err := debug.ParseBuildInfo(s)
	if err != nil {
		t.Fatalf("ParseBuildInfo: %v", err)
	}
	// ParseBuildInfo is the reverse of BuildInfo.String except for the
	// "go" line, which it skips; restore it from the fixture.
	if first, _, _ := strings.Cut(s, "\n"); strings.HasPrefix(first, "go\t") {
		bi.GoVersion = strings.TrimPrefix(first, "go\t")
	}
	return bi
}

// END fixtures OMIT

// START from OMIT

// fromTest is one row of a table that feeds a build to from.
type fromTest struct {
	name  string
	build string // "" means the binary has no build information
	ov    overrides
	want  Info
}

func runFromTests(t *testing.T, tests []fromTest) {
	t.Helper()
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var bi *debug.BuildInfo
			if tt.build != "" {
				bi = parse(t, tt.build)
			}
			got := from(bi, bi != nil, tt.ov)
			if diff := cmp.Diff(tt.want, got); diff != "" {
				t.Errorf("from() mismatch (-want +got):\n%s", diff)
			}
		})
	}
}

// END from OMIT

// START toolchain OMIT
func TestFrom(t *testing.T) {
	platform := runtime.GOOS + "/" + runtime.GOARCH
	commit := time.Date(2026, 11, 2, 14, 7, 31, 0, time.UTC)
	runFromTests(t, []fromTest{{
		name:  "dirty checkout",
		build: devBuild,
		want: Info{
			Name: "sweep", Version: "v0.0.0-20261102140731-3f9c2a1b7d4e+dirty",
			Revision: "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345",
			Time:     commit, Modified: true,
			Module: "example.com/fleet", GoVersion: "go1.27.3", Platform: platform,
		},
	}, {
		name:  "go install at a tag",
		build: installBuild,
		want: Info{
			Name: "sweep", Version: "v1.4.0", Module: "example.com/fleet",
			GoVersion: "go1.27.3", Platform: platform,
		},
	}, {
		name:  "go run",
		build: runBuild,
		want: Info{
			Name: "sweep", Version: Devel, Module: "example.com/fleet",
			GoVersion: "go1.27.3", Platform: platform,
		},
	}, {
		name: "no build information at all",
		want: Info{Version: Devel, GoVersion: runtime.Version(), Platform: platform},
	}})
}

// END toolchain OMIT

// START string OMIT
func TestString(t *testing.T) {
	info := Info{
		Name: "sweep", Version: "v1.4.0",
		Revision:  "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345",
		Time:      time.Date(2026, 11, 2, 14, 7, 31, 0, time.UTC),
		GoVersion: "go1.27.3", Platform: "linux/amd64",
	}
	const tail = " go1.27.3 linux/amd64"
	tests := []struct {
		name   string
		mutate func(*Info)
		want   string
	}{
		{"release", func(*Info) {},
			"sweep v1.4.0 (3f9c2a1b7d4e, 2026-11-02T14:07:31Z)" + tail},
		{"modified", func(i *Info) { i.Modified = true },
			"sweep v1.4.0 (3f9c2a1b7d4e, 2026-11-02T14:07:31Z, modified)" + tail},
		{"no vcs", func(i *Info) { i.Revision, i.Time = "", time.Time{} },
			"sweep v1.4.0" + tail},
		{"short revision kept", func(i *Info) {
			i.Revision, i.Time = "abc123", time.Time{}
		}, "sweep v1.4.0 (abc123)" + tail},
		{"time without revision is not shown", func(i *Info) { i.Revision = "" },
			"sweep v1.4.0" + tail},
		{"pseudo-version is not repeated", func(i *Info) {
			i.Version = "v0.0.0-20261102140731-3f9c2a1b7d4e+dirty"
			i.Modified = true
		}, "sweep v0.0.0-20261102140731-3f9c2a1b7d4e+dirty" + tail},
	}
	for _, tt := range tests {
		i := info
		tt.mutate(&i)
		if got := i.String(); got != tt.want {
			t.Errorf("%s: String() =\n%q\nwant\n%q", tt.name, got, tt.want)
		}
	}
}

// END string OMIT

// START get OMIT

// TestGet checks the real build information of the test binary. go test
// never stamps VCS information, so only toolchain-derived fields are stable.
func TestGet(t *testing.T) {
	info := Get()
	if info.GoVersion != runtime.Version() {
		t.Errorf("GoVersion = %q, want %q", info.GoVersion, runtime.Version())
	}
	if want := runtime.GOOS + "/" + runtime.GOARCH; info.Platform != want {
		t.Errorf("Platform = %q, want %q", info.Platform, want)
	}
	if bi, ok := debug.ReadBuildInfo(); !ok || info.Module != bi.Main.Path {
		t.Errorf("Module = %q, want the main module of the test binary", info.Module)
	}
	if diff := cmp.Diff(info, Get()); diff != "" {
		t.Errorf("Get is not stable across calls:\n%s", diff)
	}
}

// END get OMIT

// START overrides OMIT
func TestFromOverrides(t *testing.T) {
	platform := runtime.GOOS + "/" + runtime.GOARCH
	commit := time.Date(2026, 11, 2, 14, 7, 31, 0, time.UTC)
	runFromTests(t, []fromTest{{
		name:  "release pipeline overrides, no .git in the build context",
		build: runBuild,
		ov:    overrides{"v1.5.0", "9e8d7c6b5a4f3e2d", "1793887200"},
		want: Info{
			Name: "sweep", Version: "v1.5.0", Revision: "9e8d7c6b5a4f3e2d",
			Time:   time.Unix(1793887200, 0).UTC(),
			Module: "example.com/fleet", GoVersion: "go1.27.3", Platform: platform,
		},
	}, {
		name:  "malformed linker time is ignored",
		build: devBuild,
		ov:    overrides{buildTime: "yesterday"},
		want: Info{
			Name: "sweep", Version: "v0.0.0-20261102140731-3f9c2a1b7d4e+dirty",
			Revision: "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345",
			Time:     commit, Modified: true,
			Module: "example.com/fleet", GoVersion: "go1.27.3", Platform: platform,
		},
	}})
}

func TestParseTime(t *testing.T) {
	commit := time.Date(2026, 11, 2, 14, 7, 31, 0, time.UTC)
	tests := []struct {
		in     string
		want   time.Time
		wantOK bool
	}{
		{"2026-11-02T14:07:31Z", commit, true},
		{"2026-11-02T19:37:31+05:30", commit, true},
		{"1793887200", time.Unix(1793887200, 0).UTC(), true},
		{"", time.Time{}, false},
		{"0", time.Time{}, false},
		{"-5", time.Time{}, false},
		{"02/11/2026", time.Time{}, false},
	}
	for _, tt := range tests {
		got, ok := parseTime(tt.in)
		if ok != tt.wantOK || !got.Equal(tt.want) {
			t.Errorf("parseTime(%q) = %v, %v; want %v, %v",
				tt.in, got, ok, tt.want, tt.wantOK)
		}
	}
}

// END overrides OMIT

// START write OMIT
func TestUserAgent(t *testing.T) {
	i := Info{
		Name: "sweep", Version: "v1.4.0",
		GoVersion: "go1.27.3", Platform: "linux/arm64",
	}
	want := "sweep/v1.4.0 (go1.27.3; linux/arm64)"
	if got := i.UserAgent(); got != want {
		t.Errorf("UserAgent() = %q, want %q", got, want)
	}
}

func TestWrite(t *testing.T) {
	info := from(parse(t, devBuild), true, overrides{})

	var text bytes.Buffer
	if err := info.Write(&text, "text"); err != nil {
		t.Fatal(err)
	}
	if got := text.String(); got != info.String()+"\n" {
		t.Errorf("text output = %q", got)
	}

	var js bytes.Buffer
	if err := info.Write(&js, "json"); err != nil {
		t.Fatal(err)
	}
	var back Info
	if err := json.Unmarshal(js.Bytes(), &back); err != nil {
		t.Fatalf("json output does not round-trip: %v\n%s", err, js.String())
	}
	if diff := cmp.Diff(info, back); diff != "" {
		t.Errorf("json round trip (-want +got):\n%s", diff)
	}
	if !strings.Contains(js.String(), `"goVersion": "go1.27.3"`) {
		t.Errorf("json output lacks camelCase keys:\n%s", js.String())
	}

	if err := info.Write(&bytes.Buffer{}, "yaml"); err == nil {
		t.Error("Write with an unknown format: want error, got nil")
	}
}

func TestJSONOmitsUnknownFields(t *testing.T) {
	info := from(parse(t, runBuild), true, overrides{})
	b, err := json.Marshal(info)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{`"revision"`, `"time"`} {
		if bytes.Contains(b, []byte(key)) {
			t.Errorf("%s present for a build without VCS information: %s", key, b)
		}
	}
}

// END write OMIT
