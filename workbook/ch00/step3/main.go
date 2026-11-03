// START head OMIT

// Command logq answers questions about log files. This version splits
// the work into functions and reports bad lines as errors.
package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

// sample is a small log written into the program as a raw string.
const sample = `2026-11-03T09:00:01Z INFO api listening on :8080
2026-11-03T09:01:12Z WARN db slow query took 1250ms
2026-11-03T09:02:40Z ERROR api GET /orders 500 timeout
2026-11-03T09:02:41Z ERROR db connection reset by peer
2026-11-03T09:04
2026-11-03T09:05:20Z DEBUG worker queue depth 3
`

// END head OMIT

// START main OMIT
func main() {
	var debug, info, warn, errorCount, bad int
	for i, line := range strings.Split(sample, "\n") {
		if line == "" {
			continue
		}
		level, err := parseLevel(line)
		if err != nil {
			fmt.Fprintf(os.Stderr, "line %d: %v\n", i+1, err)
			bad++
			continue
		}
		switch level {
		case "DEBUG":
			debug++
		case "INFO":
			info++
		case "WARN":
			warn++
		case "ERROR":
			errorCount++
		}
	}
	printSummary(debug, info, warn, errorCount, bad)
}

// END main OMIT

// START parse OMIT

// parseLevel returns the level of a log line: its second word. It
// returns an error if the line is too short or the level is unknown.
func parseLevel(line string) (string, error) {
	fields := strings.Fields(line)
	if len(fields) < 3 {
		return "", errors.New("too few fields")
	}
	level := fields[1]
	switch level {
	case "DEBUG", "INFO", "WARN", "ERROR":
		return level, nil
	}
	return "", fmt.Errorf("unknown level %q", level)
}

// END parse OMIT

// START summary OMIT

// percent returns part as a percentage of total, or 0 when total is 0.
func percent(part, total int) float64 {
	if total == 0 {
		return 0
	}
	return float64(part) / float64(total) * 100
}

// printSummary prints one line per level and the share of errors.
func printSummary(debug, info, warn, errorCount, bad int) {
	total := debug + info + warn + errorCount
	fmt.Printf("%-6s %d\n", "DEBUG", debug)
	fmt.Printf("%-6s %d\n", "INFO", info)
	fmt.Printf("%-6s %d\n", "WARN", warn)
	fmt.Printf("%-6s %d\n", "ERROR", errorCount)
	fmt.Printf("%-6s %d\n", "bad", bad)
	fmt.Printf("errors: %.1f%% of %d entries\n", percent(errorCount, total), total)
}

// END summary OMIT
