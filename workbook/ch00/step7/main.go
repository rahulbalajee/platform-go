// START head OMIT

// Command logq answers questions about log files. This version parses
// each line into a struct and keeps its statistics in another one.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"time"
)

// END head OMIT

// maxLine is the longest line logq accepts, in bytes.
const maxLine = 1024 * 1024

// levels lists the levels logq knows, from least to most severe.
var levels = []string{"DEBUG", "INFO", "WARN", "ERROR"}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: logq FILE")
		os.Exit(2)
	}
	if err := run(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, "logq:", err)
		os.Exit(1)
	}
}

// START run OMIT

// run prints statistics about the log file called name.
func run(name string) error {
	f, err := os.Open(name) //nolint:gosec // opening the named file is the job
	if err != nil {
		return err
	}
	defer f.Close()

	st, err := summarize(f)
	if err != nil {
		return err
	}
	st.Print()
	return nil
}

// summarize reads log lines from r and returns their statistics.
func summarize(r io.Reader) (Stats, error) {
	var st Stats
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), maxLine)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Text()
		if line == "" {
			continue
		}
		e, err := parseEntry(line)
		if err != nil {
			fmt.Fprintf(os.Stderr, "line %d: %v\n", lineNo, err)
			st.Bad++
			continue
		}
		st.Add(e)
	}
	return st, scanner.Err()
}

// END run OMIT

// START entry OMIT

// Entry is one parsed log line.
type Entry struct {
	Time    time.Time
	Level   string
	Service string
	Message string
}

// parseEntry parses a line of the form "TIME LEVEL SERVICE MESSAGE".
// The message is the rest of the line and may contain spaces.
func parseEntry(line string) (Entry, error) {
	parts := strings.SplitN(line, " ", 4)
	if len(parts) < 4 {
		return Entry{}, errors.New("want TIME LEVEL SERVICE MESSAGE")
	}
	t, err := time.Parse(time.RFC3339, parts[0])
	if err != nil {
		return Entry{}, fmt.Errorf("bad time %q", parts[0])
	}
	if !slices.Contains(levels, parts[1]) {
		return Entry{}, fmt.Errorf("unknown level %q", parts[1])
	}
	e := Entry{Time: t, Level: parts[1], Service: parts[2], Message: parts[3]}
	return e, nil
}

// END entry OMIT

// START stats OMIT

// Stats summarizes a log: how many entries it has at each level, when
// they start and end, and how many lines could not be parsed.
type Stats struct {
	Total  int
	Levels map[string]int
	First  time.Time
	Last   time.Time
	Bad    int
}

// Add counts one entry. Add changes s, so it has a pointer receiver.
func (s *Stats) Add(e Entry) {
	if s.Levels == nil {
		s.Levels = make(map[string]int)
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
	for _, level := range levels {
		fmt.Printf("%-6s %d\n", level, s.Levels[level])
	}
	fmt.Printf("%-6s %d\n", "bad", s.Bad)
	errorShare := percent(s.Levels["ERROR"], s.Total)
	fmt.Printf("errors: %.1f%% of %d entries\n", errorShare, s.Total)
	fmt.Printf("from %s to %s (%s)\n",
		s.First.Format(time.TimeOnly), s.Last.Format(time.TimeOnly),
		s.Last.Sub(s.First))
}

// END stats OMIT

// percent returns part as a percentage of total, or 0 when total is 0.
func percent(part, total int) float64 {
	if total == 0 {
		return 0
	}
	return float64(part) / float64(total) * 100
}
