package main

// START imports OMIT
import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"

	"logq/logline"
)

// END imports OMIT

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
	enc := json.NewEncoder(c.out)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Text()
		if line == "" {
			continue
		}
		e, err := logline.Parse(line)
		if err != nil {
			err = fmt.Errorf("%s:%d: %w", name, lineNo, err)
			if c.strict {
				return err
			}
			fmt.Fprintln(c.warn, err)
			st.Bad++
			continue
		}
		if !c.match.Match(e) {
			continue
		}
		st.Add(e)
		switch {
		case !c.showEntries():
			// only the summary is printed, at the end
		case c.json:
			if err := enc.Encode(e); err != nil {
				return err
			}
		case c.prefix:
			fmt.Fprintf(c.out, "%s:%s\n", name, line)
		default:
			fmt.Fprintln(c.out, line)
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("%s:%d: %w", name, lineNo+1, err)
	}
	return nil
}

// END scan OMIT
