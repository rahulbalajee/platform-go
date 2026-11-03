// Command logq answers questions about log files. This first version
// knows about a single log line, written into the program itself.
package main

import "fmt"

// version is a constant: its value is fixed when the program is built.
const version = "0.1.0"

func main() {
	tool := "logq"
	line := "2026-11-03T09:02:40Z ERROR api GET /orders 500"
	size := len(line) // len counts the bytes in a string
	total := 18
	errorCount := 4
	var warnCount int // declared without a value, so it starts at 0
	share := float64(errorCount) / float64(total) * 100
	healthy := errorCount == 0

	fmt.Println(tool, "version", version)
	fmt.Println("sample line:", line)
	fmt.Println("sample size:", size, "bytes")
	fmt.Printf("%d of %d lines are errors (%.1f%%)\n", errorCount, total, share)
	fmt.Println("warnings counted so far:", warnCount)
	fmt.Println("healthy:", healthy)
}
