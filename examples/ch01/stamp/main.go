// Command stamp prints how it was built. It is the smallest real user of
// pkg/buildinfo and the subject of the build-stamping demos in Chapter 1.
//
//	stamp -version          one line for humans
//	stamp -version -json    the same information as JSON
//	stamp                   every build setting the toolchain embedded
//
// Exit status: 0 on success, 1 if the information cannot be printed, 2 on a
// usage error.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"runtime/debug"

	"github.com/rahulbalajee/platform-go/pkg/buildinfo"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("stamp", flag.ContinueOnError)
	fs.SetOutput(stderr)
	showVersion := fs.Bool("version", false, "print version information and exit")
	asJSON := fs.Bool("json", false, "with -version: print JSON")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}

	info := buildinfo.Get()
	if *showVersion {
		format := "text"
		if *asJSON {
			format = "json"
		}
		if err := info.Write(stdout, format); err != nil {
			fmt.Fprintln(stderr, "stamp:", err)
			return 1
		}
		return 0
	}

	// Without -version, show the raw material: what the toolchain embedded.
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
