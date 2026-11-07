package wasmext_test

// START imports OMIT

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rahulbalajee/platform-go/internal/plat/policy"
	"github.com/rahulbalajee/platform-go/internal/plat/wasmext"
)

// END imports OMIT
// START build OMIT

// wasmDir holds every test module, built once in TestMain; cacheDir holds
// wazero's compiled code for them, shared by the tests.
var wasmDir, cacheDir string

// modules maps a check's name to the package that becomes it.
var modules = map[string]string{
	"nodowngrade": "../../../examples/ch10/nodowngrade",
	"spin":        "./testdata/spin",
	"hog":         "./testdata/hog",
	"crash":       "./testdata/crash",
	"snoop":       "./testdata/snoop",
	"chatty":      "./testdata/chatty",
}

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "wasmext")
	if err != nil {
		panic(err)
	}
	wasmDir, cacheDir = dir, filepath.Join(dir, "cache")
	var wg sync.WaitGroup
	errs := make(chan error, len(modules))
	for name, pkg := range modules {
		wg.Go(func() {
			out := filepath.Join(dir, name, name+".wasm")
			cmd := exec.Command("go", "build", "-o", out, pkg)
			cmd.Env = append(os.Environ(), "GOOS=wasip1", "GOARCH=wasm")
			if b, err := cmd.CombinedOutput(); err != nil {
				errs <- err
				os.Stderr.Write(b)
			}
		})
	}
	wg.Wait()
	close(errs)
	if err := <-errs; err != nil {
		panic(err)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// load returns a Runner with the named checks only.
func load(t *testing.T, names ...string) *wasmext.Runner {
	t.Helper()
	var dirs []string
	for _, n := range names {
		dirs = append(dirs, filepath.Join(wasmDir, n))
	}
	r, err := wasmext.Load(context.Background(), cacheDir, dirs...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = r.Close(context.Background()) })
	return r
}

// END build OMIT
// START check OMIT

func deployment(version, reason string) policy.Input {
	return policy.Input{
		Request: policy.Request{Service: "checkout", Environment: "prod",
			Version: version, Reason: reason},
		History: []policy.Deployment{
			{ID: "d-7", Environment: "staging", Version: "v1.5.0",
				State: "succeeded"},
			{ID: "d-6", Environment: "prod", Version: "v1.4.1",
				State: "succeeded"},
		},
	}
}

func TestNoDowngrade(t *testing.T) {
	r := load(t, "nodowngrade")
	for _, tc := range []struct {
		version, reason string
		want            policy.Status
		msg             string
	}{
		{"v1.5.0", "", policy.Pass, ""},
		{"v1.4.0", "", policy.Fail,
			"v1.4.0 is older than v1.4.1, which is live in prod"},
		{"v1.4.0", "rollback: INC-412", policy.Pass, ""},
	} {
		res := r.Check(context.Background(), deployment(tc.version, tc.reason))[0]
		if res.Status != tc.want || !strings.HasPrefix(res.Message, tc.msg) {
			t.Errorf("%s %q: got %s %q, want %s %q", tc.version, tc.reason,
				res.Status, res.Message, tc.want, tc.msg)
		}
	}
}

// END check OMIT
// START sandbox OMIT

// A check that breaks the rules blocks the deployment, with a reason, and
// never takes plat down with it.
func TestMisbehavingChecks(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status policy.Status
		msg    string
	}{
		{"spin", policy.Error, "stopped after 2s"},
		{"hog", policy.Error, "out of memory"},
		{"crash", policy.Error, "panic: assignment to entry in nil map"},
		// The sandbox: no files, no directory listing, no network, no
		// environment. snoop prints true for each failed attempt.
		{"snoop", policy.Fail, `file: true; dir: true; net: true; HOME=""`},
	} {
		r := load(t, tc.name)
		start := time.Now()
		res := r.Check(context.Background(), deployment("v1", ""))[0]
		if res.Status != tc.status || !strings.Contains(res.Message, tc.msg) {
			t.Errorf("%s: got %s %q, want %s containing %q",
				tc.name, res.Status, res.Message, tc.status, tc.msg)
		}
		if d := time.Since(start); d > wasmext.Timeout+time.Second {
			t.Errorf("%s took %v", tc.name, d)
		}
	}
}

func TestOutputIsCapped(t *testing.T) {
	res := load(t, "chatty").Check(context.Background(), deployment("v1", ""))[0]
	if res.Status != policy.Fail || len(res.Message) > 4<<10 {
		t.Errorf("got %s with %d bytes of message", res.Status, len(res.Message))
	}
}

// The compilation cache: the second Load of a module reads machine code
// from cacheDir instead of compiling it again.
func TestCompilationCache(t *testing.T) {
	dir := t.TempDir()
	timeLoad := func() time.Duration {
		start := time.Now()
		r, err := wasmext.Load(context.Background(), dir,
			filepath.Join(wasmDir, "nodowngrade"))
		if err != nil {
			t.Fatal(err)
		}
		_ = r.Close(context.Background())
		return time.Since(start)
	}
	cold, warm := timeLoad(), timeLoad()
	t.Logf("compile: %v cold, %v from the cache", cold, warm)
	if warm*4 > cold {
		t.Errorf("cached load took %v, cold %v: the cache is not used", warm, cold)
	}
}

// END sandbox OMIT
