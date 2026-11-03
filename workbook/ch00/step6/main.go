// START head OMIT

// Command logq answers questions about log files. This version counts
// levels in a map and remembers bad lines in a slice.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
)

// maxLine is the longest line logq accepts, in bytes.
const maxLine = 1024 * 1024

// levels lists the levels logq knows, from least to most severe.
var levels = []string{"DEBUG", "INFO", "WARN", "ERROR"}

// END head OMIT

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

// run counts the lines of the log file called name by level.
func run(name string) error {
	f, err := os.Open(name) //nolint:gosec // opening the named file is the job
	if err != nil {
		return err
	}
	defer f.Close()

	counts, bad, err := countLevels(f)
	if err != nil {
		return err
	}
	printSummary(counts, bad)
	return nil
}

// countLevels reads log lines from r and counts them by level. It also
// returns the numbers of the lines it could not parse.
func countLevels(r io.Reader) (map[string]int, []int, error) {
	counts := make(map[string]int)
	var bad []int
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), maxLine)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Text()
		if line == "" {
			continue
		}
		level, err := parseLevel(line)
		if err != nil {
			fmt.Fprintf(os.Stderr, "line %d: %v\n", lineNo, err)
			bad = append(bad, lineNo)
			continue
		}
		counts[level]++
	}
	return counts, bad, scanner.Err()
}

// END run OMIT

// START parse OMIT

// parseLevel returns the level of a log line: its second word. It
// returns an error if the line is too short or the level is unknown.
func parseLevel(line string) (string, error) {
	fields := strings.Fields(line)
	if len(fields) < 3 {
		return "", errors.New("too few fields")
	}
	level := fields[1]
	if !slices.Contains(levels, level) {
		return "", fmt.Errorf("unknown level %q", level)
	}
	return level, nil
}

// END parse OMIT

// percent returns part as a percentage of total, or 0 when total is 0.
func percent(part, total int) float64 {
	if total == 0 {
		return 0
	}
	return float64(part) / float64(total) * 100
}

// START summary OMIT

// printSummary prints the count for each level, in order of severity,
// and the numbers of the lines that did not parse.
func printSummary(counts map[string]int, bad []int) {
	total := 0
	for _, level := range levels {
		fmt.Printf("%-6s %d\n", level, counts[level])
		total += counts[level]
	}
	fmt.Printf("%-6s %d %v\n", "bad", len(bad), bad)
	errorShare := percent(counts["ERROR"], total)
	fmt.Printf("errors: %.1f%% of %d entries\n", errorShare, total)
}

// END summary OMIT
