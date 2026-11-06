package cli

import "testing"

// START colour OMIT

func TestColourAllowed(t *testing.T) {
	for _, tc := range []struct {
		name string
		env  map[string]string
		tty  bool
		want bool
	}{
		{"terminal", nil, true, true},
		{"pipe", nil, false, false},
		{"NO_COLOR beats a terminal", map[string]string{"NO_COLOR": "1"},
			true, false},
		{"CLICOLOR_FORCE into a pipe", map[string]string{"CLICOLOR_FORCE": "1"},
			false, true},
		{"CLICOLOR_FORCE=0 is not force", map[string]string{"CLICOLOR_FORCE": "0"},
			false, false},
		{"NO_COLOR beats CLICOLOR_FORCE",
			map[string]string{"NO_COLOR": "1", "CLICOLOR_FORCE": "1"}, true, false},
		{"dumb terminal", map[string]string{"TERM": "dumb"}, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			getenv := func(k string) string { return tc.env[k] }
			if got := colourAllowed(getenv, tc.tty); got != tc.want {
				t.Errorf("colourAllowed = %v, want %v", got, tc.want)
			}
		})
	}
}

// END colour OMIT
// START prompt OMIT

func TestCanPrompt(t *testing.T) {
	s, _, _, _ := Test()
	if s.CanPrompt() {
		t.Error("CanPrompt with no terminals")
	}
	s.SetStdinTTY(true)
	s.SetStdoutTTY(true)
	if !s.CanPrompt() {
		t.Error("cannot prompt on a terminal")
	}
	s.SetNeverPrompt(true)
	if s.CanPrompt() {
		t.Error("CanPrompt after SetNeverPrompt (--no-input)")
	}
}

// END prompt OMIT
