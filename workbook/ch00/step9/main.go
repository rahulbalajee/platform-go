// START head OMIT

// Command logq answers questions about log files. This version keeps
// the parsing code in a package of its own, logline.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"

	"logq/logline"
)

// END head OMIT

// maxLine is the longest line logq accepts, in bytes.
const maxLine = 1024 * 1024

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

// START summarize OMIT

// summarize reads log lines from r and returns their statistics.
func summarize(r io.Reader) (logline.Stats, error) {
	var st logline.Stats
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), maxLine)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Text()
		if line == "" {
			continue
		}
		e, err := logline.Parse(line)
		if err != nil {
			fmt.Fprintf(os.Stderr, "line %d: %v\n", lineNo, err)
			st.Bad++
			continue
		}
		st.Add(e)
	}
	return st, scanner.Err()
}

// END summarize OMIT
