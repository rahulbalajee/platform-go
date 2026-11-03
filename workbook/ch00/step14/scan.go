package main

// START imports OMIT
import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"

	"logq/logline"
)

// END imports OMIT

// maxLine is the longest line logq accepts, in bytes.
const maxLine = 1024 * 1024

// START result OMIT

// result is what scanning one file produces. The output is kept in
// buffers so that files scanned at the same time cannot mix their lines.
type result struct {
	index int           // position of the file on the command line
	out   bytes.Buffer  // matching entries
	warn  bytes.Buffer  // messages about bad lines
	stats logline.Stats // counts of the matching entries
	err   error         // what stopped the scan, if anything
}

// scanOne scans one file and returns what it found. It gives the file
// its own copy of c, which writes into the result's buffers.
func (c config) scanOne(name string) *result {
	r := &result{}
	fc := c
	fc.out, fc.warn = &r.out, &r.warn
	r.err = fc.scanFile(name, &r.stats)
	return r
}

// END result OMIT

// START scanall OMIT

// scanAll scans every file, at most c.jobs at a time, and returns the
// results in the same order as files.
func (c config) scanAll(files []string) []*result {
	results := make(chan *result)
	slots := make(chan struct{}, c.jobs) // holds one token per running scan

	var wg sync.WaitGroup
	for i, name := range files {
		wg.Go(func() {
			slots <- struct{}{}        // take a slot; blocks while all are in use
			defer func() { <-slots }() // give the slot back when done
			r := c.scanOne(name)
			r.index = i
			results <- r
		})
	}
	go func() {
		wg.Wait()      // once every scan has sent its result,
		close(results) // tell the loop below that no more are coming
	}()

	ordered := make([]*result, len(files))
	for r := range results {
		ordered[r.index] = r
	}
	return ordered
}

// END scanall OMIT

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
