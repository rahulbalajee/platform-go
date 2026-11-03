package logline

import (
	"fmt"
	"time"
)

// Stats summarizes a log: how many entries it has at each level, when
// they start and end, and how many lines could not be parsed.
type Stats struct {
	Total  int
	Levels map[Level]int
	First  time.Time
	Last   time.Time
	Bad    int
}

// Add counts one entry. Add changes s, so it has a pointer receiver.
func (s *Stats) Add(e Entry) {
	if s.Levels == nil {
		s.Levels = make(map[Level]int)
	}
	s.Total++
	s.Levels[e.Level]++
	if s.First.IsZero() || e.Time.Before(s.First) {
		s.First = e.Time
	}
	if e.Time.After(s.Last) {
		s.Last = e.Time
	}
}

// Print writes a summary of s to standard output. Print only reads s,
// so a value receiver is enough.
func (s Stats) Print() {
	for l := Debug; l <= Error; l++ {
		fmt.Printf("%-6s %d\n", l, s.Levels[l])
	}
	fmt.Printf("%-6s %d\n", "bad", s.Bad)
	errorShare := percent(s.Levels[Error], s.Total)
	fmt.Printf("errors: %.1f%% of %d entries\n", errorShare, s.Total)
	fmt.Printf("from %s to %s (%s)\n",
		s.First.Format(time.TimeOnly), s.Last.Format(time.TimeOnly),
		s.Last.Sub(s.First))
}

// percent returns part as a percentage of total, or 0 when total is 0.
func percent(part, total int) float64 {
	if total == 0 {
		return 0
	}
	return float64(part) / float64(total) * 100
}
