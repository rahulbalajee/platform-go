// START head OMIT

// Command logq answers questions about log files. This version reads
// the log from a file named on the command line.
package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// END head OMIT

// START main OMIT
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

// END main OMIT

// START run OMIT

// run counts the lines of the log file called name by level.
func run(name string) error {
	text, err := readLog(name)
	if err != nil {
		return err
	}
	var debug, info, warn, errorCount, bad int
	for i, line := range strings.Split(text, "\n") {
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
	return nil
}

// END run OMIT

// START readlog OMIT

// readLog returns the whole content of the file called name.
func readLog(name string) (string, error) {
	f, err := os.Open(name) //nolint:gosec // opening the named file is the job
	if err != nil {
		return "", err
	}
	defer f.Close()

	data, err := io.ReadAll(f)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// END readlog OMIT

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
