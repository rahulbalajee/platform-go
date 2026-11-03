// Command mkproxy turns a txtar archive into a file-system module proxy, so
// module behaviour (minimal version selection, retractions, replacements)
// can be demonstrated and tested offline with GOPROXY=file:///dir.
//
//	mkproxy -o dir universe.txtar
//
// Archive entries named "module@version/file" become module versions in
// dir/proxy, laid out as the GOPROXY protocol requires (@v/list, .info,
// .mod and .zip). Every other entry is written to dir as a plain file, which
// is how the archive carries the main module that uses the proxy.
package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stderr))
}

func run(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("mkproxy", flag.ContinueOnError)
	fs.SetOutput(stderr)
	out := fs.String("o", "", "output directory (required)")
	if err := fs.Parse(args); err != nil || *out == "" || fs.NArg() != 1 {
		fmt.Fprintln(stderr, "usage: mkproxy -o dir archive.txtar")
		return 2
	}
	data, err := os.ReadFile(fs.Arg(0))
	if err != nil {
		fmt.Fprintln(stderr, "mkproxy:", err)
		return 1
	}
	if err := build(*out, parseTxtar(data)); err != nil {
		fmt.Fprintln(stderr, "mkproxy:", err)
		return 1
	}
	return 0
}

// file is one entry of a txtar archive.
type file struct {
	name string
	data []byte
}

// parseTxtar reads the txtar format: an optional comment, then entries that
// each start with a "-- name --" line.
func parseTxtar(data []byte) []file {
	var files []file
	for line := range bytes.Lines(data) {
		s := strings.TrimSpace(string(line))
		if name, ok := strings.CutPrefix(s, "-- "); ok && strings.HasSuffix(name, " --") {
			files = append(files, file{name: strings.TrimSuffix(name, " --")})
			continue
		}
		if len(files) > 0 { // text before the first marker is a comment
			f := &files[len(files)-1]
			f.data = append(f.data, line...)
		}
	}
	return files
}

// modVersion identifies one version of one module.
type modVersion struct{ path, version string }

// build writes plain files under out and module versions under out/proxy.
func build(out string, files []file) error {
	mods := map[modVersion][]file{}
	for _, f := range files {
		if !filepath.IsLocal(filepath.FromSlash(f.name)) {
			return fmt.Errorf("%s: entry escapes the output directory", f.name)
		}
		mv, rel, ok := splitModuleFile(f.name)
		if !ok {
			plain := filepath.Join(out, filepath.FromSlash(f.name))
			if err := writeFile(plain, f.data); err != nil {
				return err
			}
			continue
		}
		if mv.path != strings.ToLower(mv.path) {
			return fmt.Errorf("%s: upper-case module paths need case-encoding", f.name)
		}
		mods[mv] = append(mods[mv], file{name: rel, data: f.data})
	}

	versions := map[string][]string{} // module path -> versions, for @v/list
	for mv, fs := range mods {
		dir := filepath.Join(out, "proxy", filepath.FromSlash(mv.path), "@v")
		gomod := slices.IndexFunc(fs, func(f file) bool { return f.name == "go.mod" })
		if gomod < 0 {
			return fmt.Errorf("%s@%s: no go.mod", mv.path, mv.version)
		}
		info, err := json.Marshal(struct {
			Version string
			Time    time.Time
		}{mv.version, time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)})
		if err != nil {
			return err
		}
		zipped, err := zipModule(mv, fs)
		if err != nil {
			return err
		}
		base := filepath.Join(dir, mv.version)
		for ext, data := range map[string][]byte{
			".info": info, ".mod": fs[gomod].data, ".zip": zipped,
		} {
			if err := writeFile(base+ext, data); err != nil {
				return err
			}
		}
		versions[mv.path] = append(versions[mv.path], mv.version)
	}
	for mod, vs := range versions {
		slices.Sort(vs) // semver order is not needed by the go command
		list := filepath.Join(out, "proxy", filepath.FromSlash(mod), "@v", "list")
		if err := writeFile(list, []byte(strings.Join(vs, "\n")+"\n")); err != nil {
			return err
		}
	}
	return nil
}

// splitModuleFile splits "example.com/m@v1.2.0/dir/f.go" into the module
// version and "dir/f.go".
func splitModuleFile(name string) (modVersion, string, bool) {
	modPath, rest, ok := strings.Cut(name, "@")
	if !ok {
		return modVersion{}, "", false
	}
	version, rel, ok := strings.Cut(rest, "/")
	if !ok || modPath == "" || !strings.HasPrefix(version, "v") || rel == "" {
		return modVersion{}, "", false
	}
	return modVersion{modPath, version}, rel, true
}

// zipModule builds a module zip: every file lives under "path@version/".
func zipModule(mv modVersion, files []file) ([]byte, error) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	prefix := mv.path + "@" + mv.version + "/"
	for _, f := range files {
		w, err := zw.Create(path.Join(prefix, f.name))
		if err != nil {
			return nil, err
		}
		if _, err := w.Write(f.data); err != nil {
			return nil, err
		}
	}
	if err := zw.Close(); err != nil {
		return nil, fmt.Errorf("zip %s@%s: %w", mv.path, mv.version, err)
	}
	return buf.Bytes(), nil
}

func writeFile(name string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(name), 0o750); err != nil {
		return err
	}
	return os.WriteFile(name, data, 0o600)
}
