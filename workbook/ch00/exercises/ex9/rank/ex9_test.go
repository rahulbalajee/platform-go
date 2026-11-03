package rank

import (
	"slices"
	"testing"
	"time"
)

func TestTopFunc(t *testing.T) {
	t1 := time.Date(2026, 11, 3, 9, 1, 0, 0, time.UTC)
	t2 := t1.Add(time.Minute)
	t3 := t2.Add(time.Minute)
	counts := map[time.Time]int{t1: 2, t2: 5, t3: 2}

	got := TopFunc(counts, 2, time.Time.Compare)
	want := []Count[time.Time]{{t2, 5}, {t1, 2}}
	if !slices.Equal(got, want) {
		t.Errorf("TopFunc = %v, want %v", got, want)
	}
}
