package main

import (
	"bufio"
	"fmt"
	"io"
	"os"

	"logq/logline"
)

// maxLine is the longest line logq accepts, in bytes.
const maxLine = 1024 * 1024

// START scan OMIT

// scanFile scans the log file called name, or c.stdin if name is "-".
func (c config) scanFile(name string, st *logline.Stats) error {
	if name == "-" {
		return c.scan(c.stdin, "stdin", st)
	}
	f, err := os.Open(name)
	if err != nil {
		return err
	}
	defer f.Close()
	return c.scan(f, name, st)
}

// scan reads log lines from r, writes the entries that match to c.out
// and counts them in st. name is used in messages about bad lines.
func (c config) scan(r io.Reader, name string, st *logline.Stats) error {
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
			fmt.Fprintf(c.warn, "%s:%d: %v\n", name, lineNo, err)
			st.Bad++
			continue
		}
		if !c.match.Match(e) {
			continue
		}
		st.Add(e)
		if c.count {
			continue
		}
		if c.prefix {
			fmt.Fprint(c.out, name, ":")
		}
		fmt.Fprintln(c.out, line)
	}
	return scanner.Err()
}

// END scan OMIT
