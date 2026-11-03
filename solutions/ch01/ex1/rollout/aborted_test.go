package rollout

import (
	"encoding/json"
	"slices"
	"testing"
)

// An aborted rollout was stopped by an operator before it finished. It is
// the last phase, so the numeric values of the others do not change.
func TestAbortedPhase(t *testing.T) {
	if got := PhaseAborted.String(); got != "aborted" {
		t.Errorf("PhaseAborted.String() = %q, want %q", got, "aborted")
	}
	if PhaseAborted != PhaseRolledBack+1 {
		t.Errorf("PhaseAborted = %d, want %d",
			int(PhaseAborted), int(PhaseRolledBack+1))
	}
	if p, err := ParsePhase("aborted"); err != nil || p != PhaseAborted {
		t.Errorf("ParsePhase(%q) = %v, %v", "aborted", p, err)
	}
	want := []Phase{PhasePending, PhaseCanary, PhaseProgressing,
		PhasePaused, PhaseComplete, PhaseRolledBack, PhaseAborted}
	if got := Phases(); !slices.Equal(got, want) {
		t.Errorf("Phases() = %v, want %v", got, want)
	}
}

// Every phase, including the new one, must survive a JSON round trip, and
// the value just past the last phase must still be rejected.
func TestEveryPhaseRoundTrips(t *testing.T) {
	for _, p := range Phases() {
		b, err := json.Marshal(p)
		if err != nil {
			t.Errorf("Marshal(%v): %v", p, err)
			continue
		}
		var back Phase
		if err := json.Unmarshal(b, &back); err != nil || back != p {
			t.Errorf("round trip of %v: got %v, %v", p, back, err)
		}
	}
	if _, err := json.Marshal(PhaseAborted + 1); err == nil {
		t.Error("Marshal of the value after the last phase: want error")
	}
}
