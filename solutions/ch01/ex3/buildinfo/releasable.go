package buildinfo

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// START errors OMIT

// Reasons a build must not be published. Releasable wraps them, so callers
// test for them with errors.Is.
var (
	ErrNoVersion     = errors.New("no version: not built from a VCS checkout")
	ErrPseudoVersion = errors.New("pseudo-version: the commit is not tagged")
	ErrModified      = errors.New("built from a modified working tree")
	ErrNoRevision    = errors.New("no VCS revision recorded")
)

// END errors OMIT

// START releasable OMIT

// pseudo matches the timestamp and commit hash that every pseudo-version
// form ends with (vX.0.0-T-H, vX.Y.Z-0.T-H, vX.Y.Z-pre.0.T-H), followed by
// optional build metadata such as "+dirty".
var pseudo = regexp.MustCompile(`[-.]\d{14}-[0-9a-f]{12}(\+.*)?$`)

// Releasable reports whether the build may be published as a release. It
// returns nil for a clean build of a tagged commit, and otherwise every
// reason it is not, joined.
func (i Info) Releasable() error {
	var errs []error
	switch {
	case i.Version == "" || i.Version == Devel:
		errs = append(errs, ErrNoVersion)
	case pseudo.MatchString(i.Version):
		errs = append(errs, fmt.Errorf("%w: %s", ErrPseudoVersion, i.Version))
	}
	if i.Modified || strings.HasSuffix(i.Version, "+dirty") {
		errs = append(errs, ErrModified)
	}
	if i.Revision == "" {
		errs = append(errs, ErrNoRevision)
	}
	return errors.Join(errs...)
}

// END releasable OMIT
