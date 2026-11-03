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

// scanFile scans the log file called name, or standard input if name
// is "-".
func (c config) scanFile(name string, st *logline.Stats) error {
	if name == "-" {
		return c.scan(os.Stdin, "stdin", st)
	}
	f, err := os.Open(name)
	if err != nil {
		return err
	}
	defer f.Close()
	return c.scan(f, name, st)
}

// scan reads log lines from r, prints the entries that pass the filters
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
			fmt.Fprintf(os.Stderr, "%s:%d: %v\n", name, lineNo, err)
			st.Bad++
			continue
		}
		if !c.keep(e) {
			continue
		}
		st.Add(e)
		if c.count {
			continue
		}
		if c.prefix {
			fmt.Print(name, ":")
		}
		fmt.Println(line)
	}
	return scanner.Err()
}
