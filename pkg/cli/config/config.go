// START head OMIT

// Package config reads and writes a command-line tool's configuration file:
// named contexts, each pointing at one server, and the current one, in the
// style of kubectl. It knows where the file lives on each OS and writes it
// atomically, so a crash or a full disk never leaves half a file behind.
// Secrets never go in it; package auth stores those.
package config

// END head OMIT
// START imports OMIT

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"slices"

	"sigs.k8s.io/yaml"

	"github.com/rahulbalajee/platform-go/pkg/fsx"
)

// END imports OMIT
// START types OMIT

// File is the configuration file.
type File struct {
	CurrentContext string    `json:"current-context,omitempty"`
	Contexts       []Context `json:"contexts,omitempty"`
}

// Context is one server and how to log in to it.
type Context struct {
	Name   string `json:"name"`
	Server string `json:"server"`
	// Provider is how to log in: "oidc" (the default) uses the OpenID
	// Connect provider at Issuer; "github" uses GitHub's device flow.
	Provider string `json:"provider,omitempty"`
	// Issuer is the OIDC issuer URL. Empty means the server itself.
	Issuer string `json:"issuer,omitempty"`
	// ClientID is the OAuth client ID the tool logs in as. Empty means
	// the tool's default.
	ClientID string `json:"client-id,omitempty"`
}

// END types OMIT
// START dir OMIT

// Dir returns the directory for app's configuration: $XDG_CONFIG_HOME/app
// if XDG_CONFIG_HOME is set, else ~/.config/app on Unix (macOS included:
// command-line users expect dotfiles there, not in ~/Library), and
// %AppData%\app on Windows.
func Dir(app string, getenv func(string) string) (string, error) {
	if x := getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, app), nil
	}
	if runtime.GOOS == "windows" {
		d, err := os.UserConfigDir()
		return filepath.Join(d, app), err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", app), nil
}

// END dir OMIT
// START load OMIT

// Load reads the file at path. A missing file is an empty configuration,
// so a fresh install works. Unknown keys are an error that names the key:
// a slip such as "current_context" (underscore for hyphen) would otherwise
// be silently ignored.
func Load(path string) (*File, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return &File{}, nil
	}
	if err != nil {
		return nil, err
	}
	var f File
	if err := yaml.UnmarshalStrict(data, &f); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &f, f.validate()
}

func (f *File) validate() error {
	seen := map[string]bool{}
	for _, c := range f.Contexts {
		if c.Name == "" {
			return errors.New("a context has no name")
		}
		if seen[c.Name] {
			return fmt.Errorf("context %q is defined twice", c.Name)
		}
		seen[c.Name] = true
	}
	return nil
}

// END load OMIT
// START save OMIT

// Save writes f to path atomically, creating the directory if needed. The
// file is private to the user (0600): it holds no secrets, but it does name
// servers and accounts.
func (f *File) Save(path string) error {
	data, err := yaml.Marshal(f)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return fsx.WriteFile(path, data, 0o600)
}

// END save OMIT
// START contexts OMIT

// Context returns the named context.
func (f *File) Context(name string) (Context, bool) {
	i := f.index(name)
	if i < 0 {
		return Context{}, false
	}
	return f.Contexts[i], true
}

// SetContext adds c, or replaces the context with the same name.
func (f *File) SetContext(c Context) {
	if i := f.index(c.Name); i >= 0 {
		f.Contexts[i] = c
		return
	}
	f.Contexts = append(f.Contexts, c)
}

// DeleteContext removes the named context, and unsets it as the current
// context if it was. It reports whether the context existed.
func (f *File) DeleteContext(name string) bool {
	i := f.index(name)
	if i < 0 {
		return false
	}
	f.Contexts = slices.Delete(f.Contexts, i, i+1)
	if f.CurrentContext == name {
		f.CurrentContext = ""
	}
	return true
}

// Names returns the context names, sorted.
func (f *File) Names() []string {
	var names []string
	for _, c := range f.Contexts {
		names = append(names, c.Name)
	}
	slices.Sort(names)
	return names
}

func (f *File) index(name string) int {
	return slices.IndexFunc(f.Contexts, func(c Context) bool {
		return c.Name == name
	})
}

// END contexts OMIT
// START resolve OMIT

// Resolved is the context a command will use, after flags and environment
// variables have had their say, with the origin of each value. Origins go
// into `status` output and error messages: "server from PLAT_SERVER" ends
// a debugging session that "wrong server" starts.
type Resolved struct {
	Context       Context
	ContextOrigin string // "--context", "PLAT_CONTEXT", "current-context", ""
	ServerOrigin  string // "--server", "PLAT_SERVER", "context", ""
}

// Resolve picks the context and server. For each, a flag beats an
// environment variable, which beats the file: the value closest to this
// one command invocation wins. env is the variable prefix ("PLAT").
func (f *File) Resolve(flagContext, flagServer, env string,
	getenv func(string) string,
) (Resolved, error) {
	var r Resolved
	name := flagContext
	switch {
	case name != "":
		r.ContextOrigin = "--context"
	case getenv(env+"_CONTEXT") != "":
		name, r.ContextOrigin = getenv(env+"_CONTEXT"), env+"_CONTEXT"
	case f.CurrentContext != "":
		name, r.ContextOrigin = f.CurrentContext, "current-context"
	}
	if name != "" {
		c, ok := f.Context(name)
		if !ok {
			return r, &NotFoundError{Name: name, Origin: r.ContextOrigin}
		}
		r.Context, r.ServerOrigin = c, "context"
	}
	switch {
	case flagServer != "":
		r.Context.Server, r.ServerOrigin = flagServer, "--server"
	case getenv(env+"_SERVER") != "":
		r.Context.Server, r.ServerOrigin = getenv(env+"_SERVER"), env+"_SERVER"
	}
	if r.Context.Server == "" {
		r.ServerOrigin = ""
	}
	return r, nil
}

// NotFoundError reports a context name that the file does not define.
type NotFoundError struct{ Name, Origin string }

func (e *NotFoundError) Error() string {
	return fmt.Sprintf("context %q (from %s) does not exist", e.Name, e.Origin)
}

// END resolve OMIT
