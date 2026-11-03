// Command logscan summarises access logs of any size in constant memory:
// line and byte counts, responses by status class, and over-long lines.
// The -mode flag selects deliberately naive implementations for comparison.
//
//	logscan access.log            # stream one file (or "-" for stdin)
//	logscan -dir /var/log/app -glob 'access.log*'   # .gz files included
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

func main() {
	mode := flag.String("mode", "stream", "stream, scanner (naive) or readall (naive)")
	maxLine := flag.Int("max-line", 64<<10, "longest line kept in full, in bytes")
	dir := flag.String("dir", "", "scan files in this directory matching -glob")
	glob := flag.String("glob", "*.log*", "file pattern for -dir")
	flag.Parse()

	start := time.Now()
	st, err := run(*mode, *maxLine, *dir, *glob, flag.Args())
	elapsed := time.Since(start)
	report(os.Stdout, st, elapsed)
	if err != nil {
		fmt.Fprintln(os.Stderr, "logscan:", err)
		os.Exit(1)
	}
}

func run(mode string, maxLine int, dir, glob string, args []string) (Stats, error) {
	if dir != "" {
		return scanFS(os.DirFS(dir), glob, maxLine)
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
	switch mode {
	case "stream":
		return scan(r, maxLine)
	case "scanner":
		return scanScanner(r)
	case "readall":
		return scanReadAll(r)
	}
	return Stats{}, fmt.Errorf("unknown -mode %q", mode)
}

func report(out io.Writer, st Stats, elapsed time.Duration) {
	w := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	defer w.Flush()
	fmt.Fprintf(w, "lines\t%d\n", st.Lines)
	fmt.Fprintf(w, "status\t2xx=%d 3xx=%d 4xx=%d 5xx=%d\n",
		st.Status[2], st.Status[3], st.Status[4], st.Status[5])
	if st.Truncated > 0 || st.Malformed > 0 {
		fmt.Fprintf(w, "anomalies\t%d truncated, %d malformed\n", st.Truncated, st.Malformed)
	}
	mib := float64(st.Bytes) / (1 << 20)
	fmt.Fprintf(w, "read\t%.0f MiB in %.1fs (%.0f MiB/s)\n",
		mib, elapsed.Seconds(), mib/elapsed.Seconds())
	fmt.Fprintf(w, "peak RSS\t%.1f MiB\n", float64(peakRSS())/(1<<20))
}
