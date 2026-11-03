// START head OMIT

// Command inventory lists the Go binaries under one or more directories
// with the build information each one carries: main module version, Go
// version, platform, whether the tree was modified, and optionally the
// version of one module, to answer "which binaries contain x/net older than
// v0.60.0" from artifacts alone.
//
//	inventory [-module path [-older version]] dir...
//
// Files that are not Go binaries are skipped. Exit status: 0 on success,
// 1 if a directory cannot be read, 2 on a usage error.
package main

import (
	"debug/buildinfo"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"text/tabwriter"

	"golang.org/x/mod/semver"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// END head OMIT

// START run OMIT
func run(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("inventory", flag.ContinueOnError)
	flags.SetOutput(stderr)
	module := flags.String("module", "", "show the version of this module")
	older := flags.String("older", "",
		"with -module: list only binaries with a lower version")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	switch {
	case flags.NArg() == 0:
		fmt.Fprintln(stderr,
			"usage: inventory [-module path [-older version]] dir...")
		return 2
	case *older != "" && *module == "":
		fmt.Fprintln(stderr, "inventory: -older needs -module")
		return 2
	case *older != "" && !semver.IsValid(*older):
		fmt.Fprintf(stderr,
			"inventory: -older %q is not a semantic version\n", *older)
		return 2
	}

	var rows []row
	skipped := 0
	for _, dir := range flags.Args() {
		rs, n, err := scan(dir, *module)
		if err != nil {
			fmt.Fprintln(stderr, "inventory:", err)
			return 1
		}
		rows, skipped = append(rows, rs...), skipped+n
	}
	if *older != "" {
		rows = slices.DeleteFunc(rows, func(r row) bool {
			return r.module == "-" || semver.Compare(r.module, *older) >= 0
		})
	}
	slices.SortFunc(rows, func(a, b row) int {
		return strings.Compare(a.file, b.file)
	})
	if skipped > 0 {
		fmt.Fprintf(stderr,
			"inventory: skipped %d file(s) without Go build information\n", skipped)
	}
	return write(stdout, rows, *module != "")
}

// END run OMIT

// START scan OMIT
// row is one binary in the inventory.
type row struct {
	file, version, goVersion, platform, modified string
	module                                       string // version of -module, or "-"
}

// scan reads the build information of every regular file under dir. It
// returns the rows and the number of files that are not Go binaries.
func scan(dir, module string) ([]row, int, error) {
	var rows []row
	skipped := 0
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || !d.Type().IsRegular() {
			return err
		}
		bi, ok := readBuildInfo(p)
		if !ok {
			skipped++
			return nil
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return err
		}
		r := row{file: filepath.ToSlash(rel), version: bi.Main.Version,
			goVersion: bi.GoVersion, modified: "-", module: "-"}
		var goos, goarch string
		for _, s := range bi.Settings {
			switch s.Key {
			case "GOOS":
				goos = s.Value
			case "GOARCH":
				goarch = s.Value
			case "vcs.modified":
				r.modified = s.Value
			}
		}
		r.platform = goos + "/" + goarch
		if module != "" {
			r.module = moduleVersion(bi, module)
		}
		rows = append(rows, r)
		return nil
	})
	return rows, skipped, err
}

// readBuildInfo reads the build information of the file at p. It returns
// false for files that are not Go binaries or carry no build information.
func readBuildInfo(p string) (*buildinfo.BuildInfo, bool) {
	bi, err := buildinfo.ReadFile(p)
	return bi, err == nil
}

// moduleVersion returns the version of module path in the binary, or "-".
// A replaced dependency reports the replacement's version, which is the
// code that was actually linked.
func moduleVersion(bi *buildinfo.BuildInfo, path string) string {
	if bi.Main.Path == path {
		return bi.Main.Version
	}
	for _, m := range bi.Deps {
		if m.Path != path {
			continue
		}
		if m.Replace != nil && m.Replace.Version != "" {
			return m.Replace.Version
		}
		return m.Version
	}
	return "-"
}

// END scan OMIT

// START write OMIT
func write(w io.Writer, rows []row, withModule bool) int {
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	header := "BINARY\tVERSION\tGO\tPLATFORM\tMODIFIED"
	if withModule {
		header += "\tMODULE"
	}
	fmt.Fprintln(tw, header)
	for _, r := range rows {
		cols := []string{r.file, r.version, r.goVersion, r.platform, r.modified}
		line := strings.Join(cols, "\t")
		if withModule {
			line += "\t" + r.module
		}
		fmt.Fprintln(tw, line)
	}
	if err := tw.Flush(); err != nil {
		return 1
	}
	return 0
}

// END write OMIT
