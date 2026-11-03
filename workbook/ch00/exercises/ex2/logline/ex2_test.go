package logline

import "testing"

func TestStatsPercent(t *testing.T) {
	var st Stats
	if got := st.Percent(Error); got != 0 {
		t.Errorf("empty Stats: Percent(ERROR) = %v, want 0", got)
	}
	for _, line := range []string{
		"2026-11-03T09:00:01Z INFO api one",
		"2026-11-03T09:00:02Z INFO api two",
		"2026-11-03T09:00:03Z INFO api three",
		"2026-11-03T09:00:04Z ERROR api four",
	} {
		e, err := Parse(line)
		if err != nil {
			t.Fatal(err)
		}
		st.Add(e)
	}
	tests := []struct {
		level Level
		want  float64
	}{
		{Info, 75},
		{Error, 25},
		{Warn, 0},
	}
	for _, tt := range tests {
		if got := st.Percent(tt.level); got != tt.want {
			t.Errorf("Percent(%v) = %v, want %v", tt.level, got, tt.want)
		}
	}
}
