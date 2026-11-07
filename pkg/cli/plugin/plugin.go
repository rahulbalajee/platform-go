// START head OMIT

// Package plugin finds and runs a tool's executable plugins, the way
// kubectl and gh do: `plat hello world` runs the first `plat-hello` on PATH
// with the argument "world", when plat has no built-in `hello` command.
// A plugin is any executable, in any language; it gets plat's environment,
// plus PLAT_BIN, the path of the plat that started it, so it can call back
// with `"$PLAT_BIN" auth token` or `"$PLAT_BIN" services list -o json`.
package plugin

// END head OMIT
// START imports OMIT

import (
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
)

// END imports OMIT
// START find OMIT

// Plugin is an executable named prefix-name in a PATH directory.
type Plugin struct {
	Name string `json:"name"` // "db-backup" for plat-db-backup
	Path string `json:"path"`
	// Shadows lists the plugins of the same name later on PATH, which
	// never run: the first one on PATH wins, as for any command.
	Shadows []string `json:"shadows,omitempty"`
}

// Find lists the plugins of the tool called prefix on the given PATH, in
// PATH order. It skips PATH entries that are not absolute: "." or an empty
// entry would run whatever plat-* file is in the current directory, which
// is how a cloned repository could run code. os/exec refuses those for the
// same reason (exec.ErrDot).
func Find(prefix, path string) []Plugin {
	var found []Plugin
	index := map[string]int{}
	for _, dir := range filepath.SplitList(path) {
		if !filepath.IsAbs(dir) {
			continue
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue // a missing PATH directory is common, and harmless
		}
		for _, e := range entries {
			name, ok := pluginName(prefix, e.Name())
			if !ok || !executable(dir, e) {
				continue
			}
			p := filepath.Join(dir, e.Name())
			if i, seen := index[name]; seen {
				found[i].Shadows = append(found[i].Shadows, p)
				continue
			}
			index[name] = len(found)
			found = append(found, Plugin{Name: name, Path: p})
		}
	}
	return found
}

// pluginName returns "hello" for "plat-hello" (and "plat-hello.exe" on
// Windows).
func pluginName(prefix, file string) (string, bool) {
	if runtime.GOOS == "windows" {
		file = strings.TrimSuffix(file, filepath.Ext(file))
	}
	name, ok := strings.CutPrefix(file, prefix+"-")
	return name, ok && name != ""
}

// executable reports whether the directory entry is a file someone may
// run. On Windows that is decided by the extension, elsewhere by the mode
// bits; a symlink counts by what it points to.
func executable(dir string, e fs.DirEntry) bool {
	info, err := os.Stat(filepath.Join(dir, e.Name()))
	if err != nil || info.IsDir() {
		return false
	}
	if runtime.GOOS == "windows" {
		ext := strings.ToLower(filepath.Ext(e.Name()))
		return slices.Contains([]string{".exe", ".bat", ".cmd", ".com"}, ext)
	}
	return info.Mode().Perm()&0o111 != 0
}

// END find OMIT
// START lookup OMIT

// Lookup finds the plugin for a command line. Plugin names may contain
// dashes, so `plat db backup now` tries plat-db-backup-now, then
// plat-db-backup, then plat-db: the longest name wins and the remaining
// words become the plugin's arguments. Words after the first flag are
// never part of the name.
func Lookup(plugins []Plugin, args []string) (p Plugin, rest []string, ok bool) {
	words := 0
	for words < len(args) && !strings.HasPrefix(args[words], "-") {
		words++
	}
	for n := words; n > 0; n-- {
		name := strings.Join(args[:n], "-")
		i := slices.IndexFunc(plugins, func(p Plugin) bool { return p.Name == name })
		if i >= 0 {
			return plugins[i], args[n:], true
		}
	}
	return Plugin{}, nil, false
}

// END lookup OMIT
// START env OMIT

// Env returns the environment for a plugin: the tool's own, plus
// PREFIX_BIN, the absolute path of the running binary.
func Env(prefix string) ([]string, error) {
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	key := strings.ToUpper(prefix) + "_BIN="
	env := slices.DeleteFunc(os.Environ(), func(kv string) bool {
		return strings.HasPrefix(kv, key)
	})
	return append(env, key+self), nil
}

// END env OMIT
