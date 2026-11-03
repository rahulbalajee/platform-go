// Package rollout models the phases of a progressive rollout. It exists to
// show a code generator pinned with the go.mod tool directive: the String
// method in phase_string.go is written by stringer, run through go tool.
package rollout

import "fmt"

// START phase OMIT
//go:generate go tool stringer -type=Phase -linecomment

// Phase is the state of one rollout. The numeric values are an internal
// detail; the wire and log form is the string from the line comment.
type Phase int

const (
	PhasePending     Phase = iota // pending
	PhaseCanary                   // canary
	PhaseProgressing              // progressing
	PhasePaused                   // paused
	PhaseComplete                 // complete
	PhaseRolledBack               // rolled-back
)

// END phase OMIT

// Phases lists every phase in order.
func Phases() []Phase {
	return []Phase{PhasePending, PhaseCanary, PhaseProgressing,
		PhasePaused, PhaseComplete, PhaseRolledBack}
}

// ParsePhase is the inverse of Phase.String.
func ParsePhase(s string) (Phase, error) {
	for _, p := range Phases() {
		if p.String() == s {
			return p, nil
		}
	}
	return 0, fmt.Errorf("rollout: unknown phase %q", s)
}

// MarshalText makes phases readable in JSON and YAML.
func (p Phase) MarshalText() ([]byte, error) {
	if p < PhasePending || p > PhaseRolledBack {
		return nil, fmt.Errorf("rollout: invalid phase %d", int(p))
	}
	return []byte(p.String()), nil
}

// UnmarshalText accepts the names produced by MarshalText.
func (p *Phase) UnmarshalText(b []byte) error {
	v, err := ParsePhase(string(b))
	if err != nil {
		return err
	}
	*p = v
	return nil
}
