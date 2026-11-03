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
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"logq/logline"
	"logq/match"
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

	files := flags.Args()
	if len(files) == 0 {
		files = []string{"-"}
	}
	c := config{
		match:  m,
		count:  *count,
		prefix: len(files) > 1,
		stdin:  stdin,
		out:    stdout,
		warn:   stderr,
	}
	var st logline.Stats
	for _, name := range files {
		if err := c.scanFile(name, &st); err != nil {
			fmt.Fprintln(stderr, "logq:", err)
			return 2
		}
	}
	if c.count {
		fmt.Fprintln(stdout, "query:", match.Describe(c.match))
		st.Print(stdout)
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
	prefix bool          // print the file name before each entry
	stdin  io.Reader     // read when the file name is "-"
	out    io.Writer     // matching entries and counts go here
	warn   io.Writer     // messages about bad lines go here
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
