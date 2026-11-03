package buildinfo

import (
	"errors"
	"slices"
	"testing"
)

func TestReleasable(t *testing.T) {
	clean := Info{
		Name: "sweep", Version: "v1.4.0",
		Revision:  "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345",
		GoVersion: "go1.27.3", Platform: "linux/amd64",
	}
	if err := clean.Releasable(); err != nil {
		t.Fatalf("clean tagged build: Releasable() = %v, want nil", err)
	}
	rc := clean
	rc.Version = "v1.5.0-rc.1" // a pre-release tag is still a tag
	if err := rc.Releasable(); err != nil {
		t.Errorf("release candidate: Releasable() = %v, want nil", err)
	}

	tests := []struct {
		name   string
		mutate func(*Info)
		want   []error
	}{
		{"go run", func(i *Info) { i.Version = Devel }, []error{ErrNoVersion}},
		{"dirty checkout", func(i *Info) {
			i.Version = "v0.0.0-20261102140731-3f9c2a1b7d4e+dirty"
			i.Modified = true
		}, []error{ErrPseudoVersion, ErrModified}},
		{"modified tag", func(i *Info) {
			i.Version, i.Modified = "v1.4.0+dirty", true
		}, []error{ErrModified}},
		{"modified flag only", func(i *Info) { i.Modified = true },
			[]error{ErrModified}},
		{"commit after a tag", func(i *Info) {
			i.Version = "v1.4.1-0.20261102140731-3f9c2a1b7d4e"
		}, []error{ErrPseudoVersion}},
		{"commit after a pre-release tag", func(i *Info) {
			i.Version = "v1.5.0-rc.1.0.20261102140731-3f9c2a1b7d4e"
		}, []error{ErrPseudoVersion}},
		{"no revision", func(i *Info) { i.Revision = "" }, []error{ErrNoRevision}},
		{"everything wrong", func(i *Info) {
			i.Version, i.Revision, i.Modified = Devel, "", true
		}, []error{ErrNoVersion, ErrNoRevision, ErrModified}},
	}
	all := []error{ErrNoVersion, ErrPseudoVersion, ErrModified, ErrNoRevision}
	for _, tt := range tests {
		i := clean
		tt.mutate(&i)
		err := i.Releasable()
		for _, e := range all {
			got, want := errors.Is(err, e), slices.Contains(tt.want, e)
			if got != want {
				t.Errorf("%s: errors.Is(err, %v) = %v, want %v\nerr: %v",
					tt.name, e, got, want, err)
			}
		}
	}
}
