package logline

import (
	"fmt"
	"io"
	"time"
)

// START stats OMIT

// Stats summarizes a log: how many entries it has at each level and
// from each service, when they start and end, and how many lines could
// not be parsed.
type Stats struct {
	Total    int
	Levels   map[Level]int
	Services map[string]int
	First    time.Time
	Last     time.Time
	Bad      int
}

// Add counts one entry. Add changes s, so it has a pointer receiver.
func (s *Stats) Add(e Entry) {
	s.init()
	s.Total++
	s.Levels[e.Level]++
	s.Services[e.Service]++
	if s.First.IsZero() || e.Time.Before(s.First) {
		s.First = e.Time
	}
	if e.Time.After(s.Last) {
		s.Last = e.Time
	}
}

// END stats OMIT

// START merge OMIT

// Merge adds the counts in o to s, as if s had seen o's entries too.
func (s *Stats) Merge(o Stats) {
	s.init()
	s.Total += o.Total
	s.Bad += o.Bad
	for l, n := range o.Levels {
		s.Levels[l] += n
	}
	for svc, n := range o.Services {
		s.Services[svc] += n
	}
	if !o.First.IsZero() && (s.First.IsZero() || o.First.Before(s.First)) {
		s.First = o.First
	}
	if o.Last.After(s.Last) {
		s.Last = o.Last
	}
}

// init makes the maps in s, so that the zero Stats is ready to use.
func (s *Stats) init() {
	if s.Levels == nil {
		s.Levels = make(map[Level]int)
		s.Services = make(map[string]int)
	}
}

// END merge OMIT

// START print OMIT

// Print writes a summary of s to w. Print only reads s, so a value
// receiver is enough.
func (s Stats) Print(w io.Writer) {
	for l := Debug; l <= Error; l++ {
		fmt.Fprintf(w, "%-6s %d\n", l, s.Levels[l])
	}
	fmt.Fprintf(w, "%-6s %d\n", "bad", s.Bad)
	errorShare := percent(s.Levels[Error], s.Total)
	fmt.Fprintf(w, "errors: %.1f%% of %d entries\n", errorShare, s.Total)
	fmt.Fprintf(w, "from %s to %s (%s)\n",
		s.First.Format(time.TimeOnly), s.Last.Format(time.TimeOnly),
		s.Last.Sub(s.First))
}

// END print OMIT

// percent returns part as a percentage of total, or 0 when total is 0.
func percent(part, total int) float64 {
	if total == 0 {
		return 0
	}
	return float64(part) / float64(total) * 100
}
