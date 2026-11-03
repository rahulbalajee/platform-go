// START string OMIT
package rollout

import (
	"encoding/json"
	"testing"
)

func TestStringAndParse(t *testing.T) {
	want := []string{"pending", "canary", "progressing", "paused",
		"complete", "rolled-back", "aborted"}
	for i, p := range Phases() {
		if got := p.String(); got != want[i] {
			t.Errorf("Phase(%d).String() = %q, want %q", i, got, want[i])
		}
		back, err := ParsePhase(want[i])
		if err != nil || back != p {
			t.Errorf("ParsePhase(%q) = %v, %v", want[i], back, err)
		}
	}
	// stringer's fallback for values outside the constant set.
	if got := Phase(42).String(); got != "Phase(42)" {
		t.Errorf("Phase(42).String() = %q", got)
	}
	if _, err := ParsePhase("deploying"); err == nil {
		t.Error("ParsePhase(unknown): want error")
	}
}

// END string OMIT

// START json OMIT
func TestJSON(t *testing.T) {
	type status struct {
		Phase Phase `json:"phase"`
	}
	b, err := json.Marshal(status{PhaseRolledBack})
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `{"phase":"rolled-back"}` {
		t.Errorf("marshal = %s", b)
	}
	var s status
	err = json.Unmarshal([]byte(`{"phase":"canary"}`), &s)
	if err != nil || s.Phase != PhaseCanary {
		t.Errorf("unmarshal = %v, %v", s.Phase, err)
	}
	if err := json.Unmarshal([]byte(`{"phase":"bogus"}`), &s); err == nil {
		t.Error("unmarshal of an unknown phase: want error")
	}
	if _, err := json.Marshal(status{Phase(-1)}); err == nil {
		t.Error("marshal of an invalid phase: want error")
	}
}

// END json OMIT
