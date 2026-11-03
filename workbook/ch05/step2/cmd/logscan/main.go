// Command logscan summarises an access log: how many lines, how many
// responses in each status class, how fast, and how much memory it took.
// -mode picks the implementation.
//
//	logscan -mode readall access.log   # or - for stdin
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"text/tabwriter"
	"time"
)

type options struct {
	mode string
}

func main() {
	var o options
	flag.StringVar(&o.mode, "mode", "readall", "readall or scanner")
	flag.Parse()

	start := time.Now()
	st, err := run(o, flag.Args())
	report(os.Stdout, st, time.Since(start))
	if err != nil {
		fmt.Fprintln(os.Stderr, "logscan:", err)
		os.Exit(1)
	}
}

// START run OMIT
func run(o options, args []string) (Stats, error) {
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
	return scanWith(o, r)
}

// scanWith scans r with the implementation -mode names.
func scanWith(o options, r io.Reader) (Stats, error) {
	switch o.mode {
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
	fmt.Fprintf(w, "peak RSS\t%.1f MiB\n", float64(peakRSS())/(1<<20))
}

// END report OMIT
