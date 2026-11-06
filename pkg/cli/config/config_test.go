package config_test

// START imports OMIT

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/rahulbalajee/platform-go/pkg/cli/config"
)

// END imports OMIT
// START roundtrip OMIT

func TestSaveAndLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "plat", "config.yaml")
	f, err := config.Load(path)
	if err != nil || len(f.Contexts) != 0 {
		t.Fatalf("missing file: %+v, %v; want an empty config", f, err)
	}
	f.SetContext(config.Context{Name: "dev", Server: "http://127.0.0.1:8484"})
	f.SetContext(config.Context{Name: "prod", Server: "https://platform.acme.dev"})
	f.CurrentContext = "dev"
	if err := f.Save(path); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("stat: %v, %v; want mode 0600", info, err)
	}
	got, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.CurrentContext != "dev" ||
		strings.Join(got.Names(), ",") != "dev,prod" {
		t.Errorf("loaded %+v", got)
	}
}

// END roundtrip OMIT
// START strict OMIT

func TestUnknownKeyIsAnError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	err := os.WriteFile(path, []byte("current_context: dev\n"), 0o600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = config.Load(path)
	if err == nil || !strings.Contains(err.Error(), `"current_context"`) {
		t.Fatalf("err = %v, want one naming the misspelt key", err)
	}
}

// END strict OMIT
// START resolve OMIT

func TestResolvePrecedence(t *testing.T) {
	f := &config.File{CurrentContext: "dev", Contexts: []config.Context{
		{Name: "dev", Server: "http://dev"},
		{Name: "prod", Server: "https://prod"},
	}}
	for _, tc := range []struct {
		name                   string
		flagCtx, flagSrv       string
		env                    map[string]string
		wantCtx, wantSrv       string
		wantCtxFrom, wantSrvFr string
	}{
		{"file only", "", "", nil, "dev", "http://dev", "current-context", "context"},
		{"env context", "", "", map[string]string{"PLAT_CONTEXT": "prod"},
			"prod", "https://prod", "PLAT_CONTEXT", "context"},
		{"flag beats env", "dev", "", map[string]string{"PLAT_CONTEXT": "prod"},
			"dev", "http://dev", "--context", "context"},
		{"env server overrides the context's", "", "",
			map[string]string{"PLAT_SERVER": "http://other"},
			"dev", "http://other", "current-context", "PLAT_SERVER"},
		{"server flag beats everything", "prod", "http://x",
			map[string]string{"PLAT_SERVER": "http://other"},
			"prod", "http://x", "--context", "--server"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			getenv := func(k string) string { return tc.env[k] }
			r, err := f.Resolve(tc.flagCtx, tc.flagSrv, "PLAT", getenv)
			if err != nil {
				t.Fatal(err)
			}
			if r.Context.Name != tc.wantCtx || r.Context.Server != tc.wantSrv ||
				r.ContextOrigin != tc.wantCtxFrom || r.ServerOrigin != tc.wantSrvFr {
				t.Errorf("got %s %s (from %s, %s)", r.Context.Name,
					r.Context.Server, r.ContextOrigin, r.ServerOrigin)
			}
		})
	}
}

func TestResolveUnknownContextNamesItsOrigin(t *testing.T) {
	f := &config.File{}
	getenv := func(k string) string {
		return map[string]string{"PLAT_CONTEXT": "staging"}[k]
	}
	_, err := f.Resolve("", "", "PLAT", getenv)
	nf, ok := errors.AsType[*config.NotFoundError](err)
	if !ok || nf.Name != "staging" || nf.Origin != "PLAT_CONTEXT" {
		t.Fatalf("err = %v", err)
	}
}

// END resolve OMIT
