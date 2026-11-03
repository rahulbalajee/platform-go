// START head OMIT

// Command logq prints the entries of log files that match a query.
//
// Usage:
//
//	logq [flags] [file ...]
//
// With no files, or with the file name "-", logq reads standard input.
// The exit status is 0 if any entry matched, 1 if none did, and 2 if
// something went wrong.
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"

	"logq/logline"
	"logq/match"
	"logq/rank"
)

// END head OMIT

// START run OMIT
func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

// run is the whole program. It reads from stdin, writes to stdout and
// stderr, and returns the exit status, so tests can call it directly.
func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("logq", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		fmt.Fprintln(flags.Output(), "usage: logq [flags] [file ...]")
		flags.PrintDefaults()
	}
	level := flags.String("level", "debug", "show entries at this `level` or above")
	grep := flags.String("grep", "", "show entries whose message contains `text`")
	expr := flags.String("regexp", "", "show entries whose message matches `re`")
	count := flags.Bool("count", false, "print counts by level instead of entries")
	asJSON := flags.Bool("json", false, "print entries as JSON, one object per line")
	top := flags.Int("top", 0, "print the `n` services with the most entries")
	strict := flags.Bool("strict", false, "stop at the first line that is not valid")
	jobs := flags.Int("j", 4, "scan up to `n` files at the same time")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2 // flags.Parse has already printed what went wrong
	}
	m, err := buildMatcher(*level, *grep, *expr)
	if err != nil {
		fmt.Fprintln(stderr, "logq:", err)
		return 2
	}
	if *jobs < 1 {
		fmt.Fprintln(stderr, "logq: -j must be at least 1")
		return 2
	}

	files := flags.Args()
	if len(files) == 0 {
		files = []string{"-"}
	}
	c := config{
		match:  m,
		count:  *count,
		json:   *asJSON,
		top:    *top,
		strict: *strict,
		jobs:   *jobs,
		prefix: len(files) > 1,
		stdin:  stdin,
		out:    stdout,
		warn:   stderr,
	}
	var st logline.Stats
	for _, r := range c.scanAll(files) {
		fmt.Fprint(stdout, r.out.String())
		fmt.Fprint(stderr, r.warn.String())
		if r.err != nil {
			explain(stderr, r.err)
			return 2
		}
		st.Merge(r.stats)
	}
	if c.count {
		fmt.Fprintln(stdout, "query:", match.Describe(c.match))
		st.Print(stdout)
	}
	for _, sc := range rank.Top(st.Services, c.top) {
		fmt.Fprintf(stdout, "%-8s %d\n", sc.Key, sc.N)
	}
	if st.Total == 0 {
		return 1
	}
	return 0
}

// END run OMIT

// START config OMIT

// config holds the settings that come from the command line, and says
// where input comes from and where output goes.
type config struct {
	match  match.Matcher // selects the entries to show
	count  bool          // print counts instead of entries
	json   bool          // print entries as JSON
	top    int           // print the busiest services instead of entries
	strict bool          // treat a bad line as an error
	jobs   int           // how many files to scan at the same time
	prefix bool          // print the file name before each entry
	stdin  io.Reader     // read when the file name is "-"
	out    io.Writer     // matching entries and counts go here
	warn   io.Writer     // messages about bad lines go here
}

// showEntries reports whether c prints entries, rather than only
// a summary of them.
func (c config) showEntries() bool {
	return !c.count && c.top == 0
}

// buildMatcher turns the filter flags into a single Matcher.
func buildMatcher(level, grep, expr string) (match.Matcher, error) {
	minLevel, err := logline.ParseLevel(level)
	if err != nil {
		return nil, err
	}
	all := match.All{match.MinLevel(minLevel)}
	if grep != "" {
		all = append(all, match.Contains(grep))
	}
	if expr != "" {
		re, err := match.NewRegexp(expr)
		if err != nil {
			return nil, err
		}
		all = append(all, re)
	}
	return all, nil
}

// END config OMIT

// START explain OMIT

// parseHints says what a valid value looks like for each field that
// a logline.ParseError can name.
var parseHints = map[string]string{
	"line":  "lines look like TIME LEVEL SERVICE MESSAGE",
	"time":  "times look like 2026-11-03T09:00:01Z (RFC 3339)",
	"level": "levels are DEBUG, INFO, WARN and ERROR",
}

// explain prints err and, for the kinds of error logq knows about, a
// hint on how to fix the problem.
func explain(w io.Writer, err error) {
	fmt.Fprintln(w, "logq:", err)
	var perr *logline.ParseError
	switch {
	case errors.Is(err, fs.ErrNotExist):
		fmt.Fprintln(w, "logq: hint: check the path; with no files, logq reads stdin")
	case errors.Is(err, bufio.ErrTooLong):
		fmt.Fprintf(w, "logq: hint: lines can be at most %d bytes long\n", maxLine)
	case errors.As(err, &perr):
		fmt.Fprintln(w, "logq: hint:", parseHints[perr.Field])
	}
}

// END explain OMIT
