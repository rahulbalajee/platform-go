package logline

import "testing"

func TestParseLevelAliases(t *testing.T) {
	tests := []struct {
		name string
		want Level
	}{
		{"WARNING", Warn},
		{"warning", Warn},
		{"ERR", Error},
		{"err", Error},
		{"warn", Warn}, // the old names still work
		{"ERROR", Error},
	}
	for _, tt := range tests {
		got, err := ParseLevel(tt.name)
		if err != nil || got != tt.want {
			t.Errorf("ParseLevel(%q) = %v, %v; want %v, nil",
				tt.name, got, err, tt.want)
		}
	}
	for _, name := range []string{"WARNINGS", "E", ""} {
		if _, err := ParseLevel(name); err == nil {
			t.Errorf("ParseLevel(%q) returned no error", name)
		}
	}
}

func TestParseAcceptsAliases(t *testing.T) {
	e, err := Parse("2026-11-03T09:01:12Z WARNING db slow query")
	if err != nil {
		t.Fatal(err)
	}
	if e.Level != Warn {
		t.Errorf("Level = %v, want WARN", e.Level)
	}
}
