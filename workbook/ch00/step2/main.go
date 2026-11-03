// Command logq answers questions about log files. This version walks
// through a small log that is written into the program itself.
package main

import (
	"fmt"
	"strings"
)

// sample is a raw string literal: everything between the backquotes,
// line breaks included, is part of the string.
const sample = `2026-11-03T09:00:01Z INFO api listening on :8080
2026-11-03T09:01:12Z WARN db slow query took 1250ms
2026-11-03T09:02:40Z ERROR api GET /orders 500 timeout
2026-11-03T09:02:41Z ERROR db connection reset by peer
2026-11-03T09:04
2026-11-03T09:05:20Z DEBUG worker queue depth 3
`

func main() {
	lines := strings.Split(sample, "\n")
	fmt.Println("lines in sample:", len(lines))

	debug, info, warn, errorCount, skipped := 0, 0, 0, 0, 0
	for i, line := range lines {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			fmt.Println("skipping line", i+1, "because it is too short")
			skipped++
			continue
		}
		switch fields[1] {
		case "DEBUG":
			debug++
		case "INFO":
			info++
		case "WARN":
			warn++
		case "ERROR":
			errorCount++
			fmt.Println("error on line", i+1, "->", line)
		default:
			skipped++
		}
	}

	fmt.Println("debug:", debug, "info:", info, "warn:", warn,
		"error:", errorCount, "skipped:", skipped)
	if errorCount > 0 {
		fmt.Println("status: errors found")
	} else {
		fmt.Println("status: clean")
	}
}
