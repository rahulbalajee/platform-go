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
	"os"
	"strings"

	"logq/logline"
)

// END head OMIT

// START run OMIT
func main() {
	os.Exit(run(os.Args[1:]))
}

// run is the whole program. It returns the exit status.
func run(args []string) int {
	flags := flag.NewFlagSet("logq", flag.ContinueOnError)
	flags.Usage = func() {
		fmt.Fprintln(flags.Output(), "usage: logq [flags] [file ...]")
		flags.PrintDefaults()
	}
	level := flags.String("level", "debug", "show entries at this `level` or above")
	grep := flags.String("grep", "", "show entries whose message contains `text`")
	count := flags.Bool("count", false, "print counts by level instead of entries")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2 // flags.Parse has already printed what went wrong
	}
	minLevel, err := logline.ParseLevel(*level)
	if err != nil {
		fmt.Fprintln(os.Stderr, "logq:", err)
		return 2
	}

	files := flags.Args()
	if len(files) == 0 {
		files = []string{"-"}
	}
	c := config{
		minLevel: minLevel,
		grep:     *grep,
		count:    *count,
		prefix:   len(files) > 1,
	}
	var st logline.Stats
	for _, name := range files {
		if err := c.scanFile(name, &st); err != nil {
			fmt.Fprintln(os.Stderr, "logq:", err)
			return 2
		}
	}
	if c.count {
		st.Print()
	}
	if st.Total == 0 {
		return 1
	}
	return 0
}

// END run OMIT

// START config OMIT

// config holds the settings that come from the command line.
type config struct {
	minLevel logline.Level // the least severe level to show
	grep     string        // text the message must contain
	count    bool          // print counts instead of entries
	prefix   bool          // print the file name before each entry
}

// keep reports whether e passes the filters in c.
func (c config) keep(e logline.Entry) bool {
	return e.Level >= c.minLevel && strings.Contains(e.Message, c.grep)
}

// END config OMIT
