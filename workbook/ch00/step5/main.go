// START head OMIT

// Command logq answers questions about log files. This version reads
// the log one line at a time, so the file can be any size.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strings"
)

// maxLine is the longest line logq accepts, in bytes.
const maxLine = 1024 * 1024

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

// run counts the lines of the log file called name by level. It reads
// the file line by line instead of loading all of it into memory.
func run(name string) error {
	f, err := os.Open(name) //nolint:gosec // opening the named file is the job
	if err != nil {
		return err
	}
	defer f.Close()

	var debug, info, warn, errorCount, bad int
	scanner := bufio.NewScanner(f)
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
	if err := scanner.Err(); err != nil {
		return err
	}
	printSummary(debug, info, warn, errorCount, bad)
	return nil
}

// END run OMIT

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
