package rank

import (
	"slices"
	"testing"

	"logq/logline"
)

// START test OMIT
func TestTopStrings(t *testing.T) {
	counts := map[string]int{"api": 7, "db": 3, "worker": 5, "edge": 3}
	got := Top(counts, 3)
	want := []Count[string]{{"api", 7}, {"worker", 5}, {"db", 3}}
	if !slices.Equal(got, want) {
		t.Errorf("Top = %v, want %v", got, want)
	}
}

func TestTopLevels(t *testing.T) {
	counts := map[logline.Level]int{logline.Info: 8, logline.Error: 4}
	got := Top(counts, 10) // asking for more than there are is fine
	want := []Count[logline.Level]{{logline.Info, 8}, {logline.Error, 4}}
	if !slices.Equal(got, want) {
		t.Errorf("Top = %v, want %v", got, want)
	}
}

// END test OMIT

func TestTopEmpty(t *testing.T) {
	if got := Top(map[string]int{}, 3); len(got) != 0 {
		t.Errorf("Top of an empty map = %v, want nothing", got)
	}
	if got := Top(map[string]int{"a": 1}, -1); len(got) != 0 {
		t.Errorf("Top with n = -1 returned %v, want nothing", got)
	}
}
