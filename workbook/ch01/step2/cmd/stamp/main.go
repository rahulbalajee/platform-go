// START head OMIT

// Command stamp prints the build information the Go toolchain embedded in
// it: the main package, the main module and every build setting.
//
// Exit status: 0 on success, 1 if the binary has no build information, 2 on
// a usage error.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"runtime/debug"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// END head OMIT

// START run OMIT
func run(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("stamp", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	return printSettings(stdout, stderr)
}

// END run OMIT

// START settings OMIT

// printSettings shows the raw material: what the toolchain embedded.
func printSettings(stdout, stderr io.Writer) int {
	bi, ok := debug.ReadBuildInfo()
	if !ok {
		fmt.Fprintln(stderr, "stamp: binary has no build information")
		return 1
	}
	fmt.Fprintf(stdout, "%-14s %s\n", "path", bi.Path)
	fmt.Fprintf(stdout, "%-14s %s %s\n", "main module", bi.Main.Path, bi.Main.Version)
	for _, s := range bi.Settings {
		fmt.Fprintf(stdout, "%-14s %s\n", s.Key, s.Value)
	}
	return 0
}

// END settings OMIT
