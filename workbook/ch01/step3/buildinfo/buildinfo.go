// START head OMIT

// Package buildinfo reports how the running binary was built, for --version
// flags, User-Agent headers and the build_info metric every service exports.
//
// The Go toolchain embeds the main module's version and, for builds inside a
// Git checkout, the commit, commit time and a dirty flag in every binary.
// This package reads them with [debug.ReadBuildInfo] and fills the gaps with
// documented defaults.
package buildinfo

import (
	"path"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"
)

// END head OMIT

// START info OMIT

// Info describes one build of a program.
type Info struct {
	Name      string    // program name
	Version   string    // "devel" if unknown
	Revision  string    // VCS commit
	Time      time.Time // commit time
	Modified  bool      // uncommitted changes
	Module    string    // main module path
	GoVersion string    // toolchain, e.g. go1.27.3
	Platform  string    // GOOS/GOARCH
}

// Devel is the version reported when the toolchain supplied none, as with
// go run and go test.
const Devel = "devel"

// END info OMIT

// START get OMIT
var current = sync.OnceValue(func() Info {
	bi, ok := debug.ReadBuildInfo()
	return from(bi, ok)
})

// Get returns the build information of the running binary. The result is
// computed once and cached; Name defaults to the last element of the main
// package's import path, which callers may replace.
func Get() Info { return current() }

// END get OMIT

// START from OMIT

// from turns the toolchain's build information into an Info. Fields the
// toolchain did not record keep a documented default. ok is false when the
// binary has no build information.
func from(bi *debug.BuildInfo, ok bool) Info {
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
	return info
}

// END from OMIT

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
