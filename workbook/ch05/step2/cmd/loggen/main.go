// START imports OMIT

// Command loggen writes a synthetic access log for the logscan examples.
// The log is deterministic, about 80 bytes a line, and can contain one
// pathological line (a 1 MiB URL) of the kind that breaks naive readers.
//
//	loggen -lines 5                        # five lines to stdout
//	loggen -lines 0 -bytes 300             # an endless log, cut at 300 bytes
//	loggen -lines 1000000 -o access.log    # to a file, with a summary
package main

import (
	"crypto/sha256"
	"flag"
	"fmt"
	"io"
	"os"
)

// END imports OMIT

// START main OMIT
func main() {
	lines := flag.Int("lines", 1000, "number of lines; 0 means no end (use -bytes)")
	longAt := flag.Int("long-at", -1, "make line N (counting from 0) 1 MiB long")
	limit := flag.Int64("bytes", 0, "stop after this many bytes; 0 means no limit")
	out := flag.String("o", "", "write to this file and print a summary")
	flag.Parse()
	err := run(os.Stdout, os.Stderr, *lines, *longAt, *limit, *out)
	if err != nil {
		fmt.Fprintln(os.Stderr, "loggen:", err)
		os.Exit(1)
	}
}

// END main OMIT

// START run OMIT
// run copies the generated log to stdout, or to the file out. Either way it
// is one io.Copy from a reader to a writer; only the writer changes.
func run(stdout, stderr io.Writer, lines, longAt int, limit int64, out string) error {
	var src io.Reader = newLogReader(lines, longAt)
	if limit > 0 {
		src = io.LimitReader(src, limit) // EOF after limit bytes
	}
	if out == "" {
		_, err := io.Copy(stdout, src)
		return err
	}
	f, err := os.Create(out)
	if err != nil {
		return err
	}
	sum := sha256.New() // a hash is an io.Writer too
	var count countWriter
	_, err = io.Copy(io.MultiWriter(f, sum, &count), src) // one pass, three writers
	if cerr := f.Close(); err == nil {
		err = cerr // a failed Close can mean the data never reached the file
	}
	if err != nil {
		return err
	}
	fmt.Fprintf(stderr, "%s: %d lines, %d bytes, sha256 %x\n",
		out, count.Lines, count.Bytes, sum.Sum(nil))
	return nil
}

// END run OMIT
