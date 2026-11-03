package logline

import (
	"testing"
	"time"
)

func TestStatsAdd(t *testing.T) {
	var st Stats // the zero value is ready to use
	lines := []string{
		"2026-11-03T09:05:00Z INFO api GET /users 200 12ms",
		"2026-11-03T09:01:12Z WARN db slow query took 1250ms",
		"2026-11-03T09:06:11Z ERROR api GET /checkout 502",
	}
	for _, line := range lines {
		e, err := Parse(line)
		if err != nil {
			t.Fatal(err)
		}
		st.Add(e)
	}

	if st.Total != 3 {
		t.Errorf("Total = %d, want 3", st.Total)
	}
	if st.Levels[Warn] != 1 || st.Levels[Debug] != 0 {
		t.Errorf("Levels = %v, want one WARN and no DEBUG", st.Levels)
	}
	if got := st.First.Format(time.TimeOnly); got != "09:01:12" {
		t.Errorf("First = %s, want 09:01:12", got)
	}
	if got := st.Last.Format(time.TimeOnly); got != "09:06:11" {
		t.Errorf("Last = %s, want 09:06:11", got)
	}
}
