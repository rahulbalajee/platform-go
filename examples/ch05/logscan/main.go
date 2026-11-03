// START imports OMIT

// Command logscan summarises access logs of any size in constant memory:
// line and byte counts, responses by status class, and over-long lines.
// -mode selects deliberately naive implementations for comparison.
//
//	logscan access.log                              # one file, or - for stdin
//	logscan -dir /var/log/app -glob 'access.log*'   # .gz files included
package main

import (
	"crypto/sha256"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"text/tabwriter"
	"time"
)

// END imports OMIT

// START main OMIT
type options struct {
	mode, dir, glob string
	maxLine         int
	sum             bool
}

func main() {
	var o options
	flag.StringVar(&o.mode, "mode", "stream", "stream, or naive: readall or scanner")
	flag.IntVar(&o.maxLine, "max-line", 64<<10, "longest line kept in full, in bytes")
	flag.StringVar(&o.dir, "dir", "", "scan files in this directory that match -glob")
	flag.StringVar(&o.glob, "glob", "*.log*", "file pattern for -dir")
	flag.BoolVar(&o.sum, "sum", false, "also print the SHA-256 of the input")
	flag.Parse()

	start := time.Now()
	st, err := run(o, flag.Args())
	report(os.Stdout, st, time.Since(start))
	if err != nil {
		fmt.Fprintln(os.Stderr, "logscan:", err)
		os.Exit(1)
	}
}

// END main OMIT

// START run OMIT
func run(o options, args []string) (Stats, error) {
	if o.dir != "" {
		return scanFS(os.DirFS(o.dir), o.glob, o.maxLine)
	}
	if len(args) != 1 {
		return Stats{}, errors.New("usage: logscan [flags] FILE|-")
	}
	var r io.Reader = os.Stdin
	if args[0] != "-" {
		f, err := os.Open(args[0])
		if err != nil {
			return Stats{}, err
		}
		defer f.Close()
		r = f
	}
	sum := sha256.New()
	if o.sum {
		r = io.TeeReader(r, sum) // every byte read from r is also written to sum
	}
	st, err := scanWith(o, r)
	if o.sum {
		st.Sum = sum.Sum(nil)
	}
	return st, err
}

// scanWith scans r with the implementation -mode names.
func scanWith(o options, r io.Reader) (Stats, error) {
	switch o.mode {
	case "stream":
		return scan(r, o.maxLine)
	case "readall":
		return scanReadAll(r)
	case "scanner":
		return scanScanner(r)
	}
	return Stats{}, fmt.Errorf("unknown -mode %q", o.mode)
}

// END run OMIT

// START report OMIT
func report(out io.Writer, st Stats, elapsed time.Duration) {
	w := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	defer w.Flush()
	fmt.Fprintf(w, "lines\t%d\n", st.Lines)
	fmt.Fprintf(w, "status\t2xx=%d 3xx=%d 4xx=%d 5xx=%d\n",
		st.Status[2], st.Status[3], st.Status[4], st.Status[5])
	if st.Truncated > 0 || st.Malformed > 0 {
		fmt.Fprintf(w, "anomalies\t%d truncated, %d malformed\n",
			st.Truncated, st.Malformed)
	}
	mib := float64(st.Bytes) / (1 << 20)
	fmt.Fprintf(w, "read\t%.0f MiB in %.1fs (%.0f MiB/s)\n",
		mib, elapsed.Seconds(), mib/elapsed.Seconds())
	if st.Sum != nil {
		fmt.Fprintf(w, "sha256\t%x\n", st.Sum)
	}
	fmt.Fprintf(w, "peak RSS\t%.1f MiB\n", float64(peakRSS())/(1<<20))
}

// END report OMIT
