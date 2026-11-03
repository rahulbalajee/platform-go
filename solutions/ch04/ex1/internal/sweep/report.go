// START head OMIT

package sweep

import (
	"cmp"
	"encoding/json"
	"fmt"
	"io"
	"slices"
	"text/tabwriter"
	"time"
	"unicode/utf8"
)

// A Reporter receives results as they arrive and renders them. Implementations
// are used from a single goroutine (the range loop over Runner.Run), so they
// need no locking: ownership, not mutexes, keeps output coherent.
type Reporter interface {
	Add(Result) error
	Close(Summary) error
}

// END head OMIT

// START summary OMIT
// Summary describes a finished (or interrupted) run.
type Summary struct {
	Total       int           `json:"total"`
	Checked     int           `json:"checked"`
	Up          int           `json:"up"`
	Down        int           `json:"down"`
	Cancelled   int           `json:"cancelled"`
	Retried     int           `json:"retried"` // needed more than one attempt
	Elapsed     time.Duration `json:"elapsed_ns"`
	Interrupted bool          `json:"interrupted"`
}

// Healthy reports whether every target was checked and found up.
func (s Summary) Healthy() bool {
	return !s.Interrupted && s.Checked == s.Total && s.Down == 0
}

// Tally updates the summary with one result.
func (s *Summary) Tally(r Result) {
	s.Checked++
	if r.Attempts > 1 {
		s.Retried++
	}
	switch r.Status {
	case StatusUp:
		s.Up++
	case StatusDown:
		s.Down++
	case StatusCancelled:
		s.Cancelled++
	}
}

func (s Summary) String() string {
	msg := fmt.Sprintf("checked %d/%d targets in %s: %d up, %d down",
		s.Checked, s.Total, s.Elapsed.Round(time.Millisecond), s.Up, s.Down)
	if s.Retried > 0 {
		msg += fmt.Sprintf(", %d retried", s.Retried)
	}
	if s.Cancelled > 0 {
		msg += fmt.Sprintf(", %d cancelled", s.Cancelled)
	}
	if s.Interrupted {
		msg += fmt.Sprintf(" (interrupted; %d never started)", s.Total-s.Checked)
	}
	return msg
}

// END summary OMIT

// START new OMIT
// NewReporter returns a reporter for format "table", "wide", "json" or
// "jsonl". "table" truncates long details to keep rows on one line; "wide"
// prints them in full, like kubectl's -o wide.
func NewReporter(format string, w io.Writer) (Reporter, error) {
	switch format {
	case "table":
		return &tableReporter{w: w, maxDetail: 36}, nil
	case "wide":
		return &tableReporter{w: w}, nil
	case "json":
		return &jsonReporter{w: w}, nil
	case "jsonl":
		return &jsonlReporter{enc: json.NewEncoder(w)}, nil
	}
	return nil, fmt.Errorf("unknown output format %q (want table, wide, json, jsonl)",
		format)
}

// END new OMIT

// START table OMIT
// tableReporter buffers results and prints them in input order, because a
// human scanning a table expects it to match the inventory file.
type tableReporter struct {
	w         io.Writer
	maxDetail int // 0 = unlimited
	results   []Result
}

func (t *tableReporter) Add(r Result) error {
	t.results = append(t.results, r)
	return nil
}

func (t *tableReporter) Close(Summary) error {
	slices.SortFunc(t.results, byIndex)
	tw := tabwriter.NewWriter(t.w, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "STATUS\tTARGET\tLATENCY\tTRIES\tDETAIL")
	for _, r := range t.results {
		detail := r.Detail
		if r.Error != "" {
			detail = r.Error
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%d\t%s\n", symbol(r.Status), r.Target,
			r.Latency.Round(time.Millisecond), r.Attempts,
			truncate(detail, t.maxDetail))
	}
	return tw.Flush()
}

// byIndex orders results as the inventory listed their targets.
func byIndex(a, b Result) int { return cmp.Compare(a.Index, b.Index) }

// truncate shortens s to at most n runes, marking the cut with an ellipsis.
func truncate(s string, n int) string {
	if n <= 0 || utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n-1]) + "…"
}

func symbol(s Status) string {
	switch s {
	case StatusUp:
		return "UP"
	case StatusDown:
		return "DOWN"
	default:
		return "CANCELLED"
	}
}

// END table OMIT

// START json OMIT
// jsonlReporter streams one JSON object per line as results complete:
// ideal for piping into jq or a log shipper while the sweep is running.
type jsonlReporter struct{ enc *json.Encoder }

func (j *jsonlReporter) Add(r Result) error  { return j.enc.Encode(r) }
func (j *jsonlReporter) Close(Summary) error { return nil }

// jsonReporter emits a single document with results in input order and the
// summary, for tools that want one parseable blob.
type jsonReporter struct {
	w       io.Writer
	results []Result
}

func (j *jsonReporter) Add(r Result) error {
	j.results = append(j.results, r)
	return nil
}

func (j *jsonReporter) Close(s Summary) error {
	slices.SortFunc(j.results, byIndex)
	enc := json.NewEncoder(j.w)
	enc.SetIndent("", "  ")
	return enc.Encode(struct {
		Summary Summary  `json:"summary"`
		Results []Result `json:"results"`
	}{s, j.results})
}

// END json OMIT
