// START head OMIT

// Package buildinfo reports how the running binary was built, for --version
// flags, User-Agent headers and the build_info metric every service exports.
//
// The values come from two places. The Go toolchain embeds the main module's
// version and, for builds inside a Git checkout, the commit, commit time and
// a dirty flag in every binary (read with [debug.ReadBuildInfo]). Release
// pipelines can override the version, revision and time with the linker:
//
//	go build -ldflags "-X $PKG.version=v1.4.0"
//
// where $PKG is this package's import path. Linker values win, because a
// pipeline knows things the toolchain cannot: a tag created after the commit
// was built, or the commit of a source tree that was copied into a container
// without its .git directory.
package buildinfo

import (
	"encoding/json"
	"fmt"
	"io"
	"path"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"
)

// END head OMIT

// START vars OMIT

// Linker overrides, set with -ldflags "-X <package path>.name=value". They
// must stay package-level string variables without an initializer that
// calls a function: -X can only replace a string variable's static value.
var (
	version   string // release version, e.g. v1.4.0
	revision  string // full commit hash, e.g. from $GITHUB_SHA
	buildTime string // RFC 3339, or Unix seconds as in SOURCE_DATE_EPOCH
)

// END vars OMIT

// START info OMIT

// Info describes one build of a program.
type Info struct {
	Name      string    `json:"name"`               // program name
	Version   string    `json:"version"`            // "devel" if unknown
	Revision  string    `json:"revision,omitempty"` // VCS commit
	Time      time.Time `json:"time,omitzero"`      // commit time
	Modified  bool      `json:"modified"`           // uncommitted changes
	Module    string    `json:"module,omitempty"`   // main module path
	GoVersion string    `json:"goVersion"`          // toolchain, e.g. go1.27.3
	Platform  string    `json:"platform"`           // GOOS/GOARCH
}

// Devel is the version reported when neither the linker nor the toolchain
// supplied one, as with go run and go test.
const Devel = "devel"

// END info OMIT

// START get OMIT

// overrides holds the linker-supplied values, so tests can vary them
// without touching the package variables.
type overrides struct {
	version, revision, buildTime string
}

var current = sync.OnceValue(func() Info {
	bi, ok := debug.ReadBuildInfo()
	return from(bi, ok, overrides{version, revision, buildTime})
})

// Get returns the build information of the running binary. The result is
// computed once and cached; Name defaults to the last element of the main
// package's import path, which callers may replace.
func Get() Info { return current() }

// END get OMIT

// START from OMIT

// from merges the toolchain's build information with linker overrides.
// Precedence for each field: linker value, then toolchain value, then a
// documented default. ok is false when the binary has no build information.
func from(bi *debug.BuildInfo, ok bool, ov overrides) Info {
	info := Info{
		Version:   Devel,
		GoVersion: runtime.Version(),
		Platform:  runtime.GOOS + "/" + runtime.GOARCH,
	}
	if ok && bi != nil {
		info.Name = path.Base(bi.Path)
		info.Module = bi.Main.Path
		info.GoVersion = bi.GoVersion
		if v := bi.Main.Version; v != "" && v != "(devel)" {
			info.Version = v // a tag, or a pseudo-version stamped from VCS
		}
		for _, s := range bi.Settings {
			switch s.Key {
			case "vcs.revision":
				info.Revision = s.Value
			case "vcs.time":
				info.Time, _ = time.Parse(time.RFC3339, s.Value)
			case "vcs.modified":
				info.Modified = s.Value == "true"
			}
		}
	}
	if ov.version != "" {
		info.Version = ov.version
	}
	if ov.revision != "" {
		info.Revision = ov.revision
	}
	if t, ok := parseTime(ov.buildTime); ok {
		info.Time = t
	}
	return info
}

// END from OMIT

// START parsetime OMIT

// parseTime accepts RFC 3339 or Unix seconds (the SOURCE_DATE_EPOCH
// convention from reproducible-builds.org). Anything else is ignored, so a
// malformed pipeline value cannot stop the program from starting.
func parseTime(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC(), true
	}
	if n, err := strconv.ParseInt(s, 10, 64); err == nil && n > 0 {
		return time.Unix(n, 0).UTC(), true
	}
	return time.Time{}, false
}

// END parsetime OMIT

// START format OMIT

// ShortRevision returns the first 12 characters of the revision, the same
// abbreviation pseudo-versions use.
func (i Info) ShortRevision() string {
	if len(i.Revision) > 12 {
		return i.Revision[:12]
	}
	return i.Revision
}

// String returns the one-line human form, for example
//
//	sweep v1.4.0 (3f9c2a1b7d4e, 2026-11-02T14:07:31Z) go1.27.3 linux/amd64
//
// A pseudo-version already contains the commit time, revision and +dirty
// suffix, so for those builds the details are not repeated.
func (i Info) String() string {
	var b strings.Builder
	b.WriteString(i.Name)
	b.WriteString(" " + i.Version)
	var detail []string
	r := i.ShortRevision()
	if r != "" && !strings.Contains(i.Version, r) {
		detail = append(detail, r)
		if !i.Time.IsZero() {
			detail = append(detail, i.Time.UTC().Format(time.RFC3339))
		}
	}
	if i.Modified && !strings.HasSuffix(i.Version, "+dirty") {
		detail = append(detail, "modified")
	}
	if len(detail) > 0 {
		b.WriteString(" (" + strings.Join(detail, ", ") + ")")
	}
	b.WriteString(" " + i.GoVersion + " " + i.Platform)
	return strings.TrimSpace(b.String())
}

// END format OMIT

// START write OMIT

// Write prints the information in format "text" (one line, for humans) or
// "json" (one object, for scripts and support bundles).
func (i Info) Write(w io.Writer, format string) error {
	switch format {
	case "text", "":
		_, err := fmt.Fprintln(w, i.String())
		return err
	case "json":
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(i)
	default:
		return fmt.Errorf("buildinfo: unknown format %q (want text or json)", format)
	}
}

// END write OMIT

// START useragent OMIT

// UserAgent returns a User-Agent value such as
// "sweep/v1.4.0 (go1.27.3; linux/amd64)", so server logs show which client
// builds are calling an API.
func (i Info) UserAgent() string {
	return fmt.Sprintf("%s/%s (%s; %s)", i.Name, i.Version, i.GoVersion, i.Platform)
}

// END useragent OMIT
