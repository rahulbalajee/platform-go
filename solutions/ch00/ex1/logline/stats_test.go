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

// START merge OMIT
func TestStatsMerge(t *testing.T) {
	var a, b, total Stats
	for i, line := range []string{
		"2026-11-03T09:05:00Z INFO api GET /users 200 12ms",
		"2026-11-03T09:01:12Z WARN db slow query took 1250ms",
		"2026-11-03T09:06:11Z ERROR api GET /checkout 502",
	} {
		e, err := Parse(line)
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			a.Add(e)
		} else {
			b.Add(e)
		}
	}
	b.Bad = 2
	total.Merge(a)
	total.Merge(b)

	if total.Total != 3 || total.Bad != 2 || total.Services["api"] != 2 {
		t.Errorf("Total = %d, Bad = %d, Services = %v; want 3, 2, two api",
			total.Total, total.Bad, total.Services)
	}
	if got := total.First.Format(time.TimeOnly); got != "09:01:12" {
		t.Errorf("First = %s, want 09:01:12", got)
	}
	if got := total.Last.Format(time.TimeOnly); got != "09:06:11" {
		t.Errorf("Last = %s, want 09:06:11", got)
	}
}

// END merge OMIT
