// START top OMIT
// START head OMIT

package sweepscript

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/rogpeppe/go-internal/testscript"

	"sweep/internal/sweep/sweeptest"
)

var update = flag.Bool("update", false, "rewrite cmp files inside the scripts")

// binDir holds the sweep binary under test.
var binDir string

// END head OMIT

// START main OMIT
// TestMain builds the real sweep binary once, before any script runs, and
// deletes it when they have all finished.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "sweep-e2e-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := buildSweep(dir); err != nil {
		fmt.Fprintln(os.Stderr, "building sweep:", err)
		os.Exit(1)
	}
	binDir = dir
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}

// END main OMIT
// END top OMIT

// START build OMIT
// buildSweep compiles cmd/sweep into dir. It builds inside the module that
// owns cmd/sweep, so that module's go.mod decides every dependency version.
// When GOCOVERDIR is set it builds with -cover, and every run of sweep in a
// script writes coverage data there (testscript passes GOCOVERDIR on).
func buildSweep(dir string) error {
	const pkg = "sweep/cmd/sweep"
	root, err := exec.Command("go", "list", "-f", "{{.Module.Dir}}", pkg).Output()
	if err != nil {
		return fmt.Errorf("locating %s: %w", pkg, err)
	}
	args := []string{"build", "-o", filepath.Join(dir, "sweep")}
	if os.Getenv("GOCOVERDIR") != "" {
		args = append(args, "-cover")
	}
	build := exec.Command("go", append(args, pkg)...)
	build.Dir = strings.TrimSpace(string(root))
	build.Stdout, build.Stderr = os.Stderr, os.Stderr
	return build.Run()
}

// END build OMIT

// START run OMIT
// TestScripts runs every testdata/script/*.txtar file as a subtest. Each
// script gets a fresh temporary directory and its own fake fleet: $FLEET
// is its base URL, $FLEET_ADDR its host:port, and $CLOSED is a TCP address
// that refuses connections.
func TestScripts(t *testing.T) {
	testscript.Run(t, testscript.Params{
		Dir:           "testdata/script",
		UpdateScripts: *update,
		Setup: func(env *testscript.Env) error {
			path := binDir + string(os.PathListSeparator) + env.Getenv("PATH")
			env.Setenv("PATH", path)
			fleet := sweeptest.NewFleet()
			srv := httptest.NewServer(fleet)
			env.Defer(func() {
				srv.CloseClientConnections() // unblock /slow handlers
				srv.Close()
			})
			env.Setenv("FLEET", srv.URL)
			env.Setenv("FLEET_ADDR", srv.Listener.Addr().String())
			env.Values[fleetKey{}] = fleet
			addr, err := refusedAddr()
			env.Setenv("CLOSED", addr)
			return err
		},
		Cmds: map[string]func(*testscript.TestScript, bool, []string){
			"envsubst": cmdEnvsubst,
			"exits":    cmdExits,
			"waitreq":  cmdWaitreq,
		},
	})
}

// fleetKey is the key under which Setup stores the script's fake fleet.
type fleetKey struct{}

// END run OMIT

// START exits OMIT
// cmdExits runs a program and asserts its exact exit status. The built-in
// "! exec" only knows "non-zero", and sweep's statuses mean different
// things to CI: 1 is "fleet unhealthy", 2 is "you called me wrong".
//
//	exits 2 sweep -o yaml targets.txt
func cmdExits(ts *testscript.TestScript, neg bool, args []string) {
	if neg || len(args) < 2 {
		ts.Fatalf("usage: exits status program [args...]")
	}
	want, err := strconv.Atoi(args[0])
	ts.Check(err)
	got := 0
	if err := ts.Exec(args[1], args[2:]...); err != nil {
		exitErr, ok := errors.AsType[*exec.ExitError](err)
		if !ok {
			ts.Fatalf("running %s: %v", args[1], err)
		}
		got = exitErr.ExitCode()
	}
	if got != want {
		ts.Fatalf("%s exited with status %d, want %d", args[1], got, want)
	}
}

// END exits OMIT

// START waitreq OMIT
// cmdWaitreq blocks until the fake fleet has served path at least n times,
// so a script can act at a known point instead of sleeping.
//
//	waitreq /slow 2
func cmdWaitreq(ts *testscript.TestScript, neg bool, args []string) {
	if neg || len(args) < 1 || len(args) > 2 {
		ts.Fatalf("usage: waitreq path [count]")
	}
	n := 1
	if len(args) == 2 {
		var err error
		n, err = strconv.Atoi(args[1])
		ts.Check(err)
	}
	fleet := ts.Value(fleetKey{}).(*sweeptest.Fleet)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ts.Check(fleet.WaitFor(ctx, args[0], n))
}

// END waitreq OMIT

// START envsubst OMIT
// cmdEnvsubst expands $VARIABLES in the named files in place, so inventory
// files inside a script can point at the per-script fake fleet.
//
//	envsubst targets.txt
func cmdEnvsubst(ts *testscript.TestScript, neg bool, args []string) {
	if neg || len(args) == 0 {
		ts.Fatalf("usage: envsubst file...")
	}
	for _, name := range args {
		data := os.Expand(ts.ReadFile(name), ts.Getenv)
		ts.Check(os.WriteFile(ts.MkAbs(name), []byte(data), 0o600))
	}
}

// END envsubst OMIT

// START refused OMIT
// refusedAddr returns a loopback address with nothing listening on it.
func refusedAddr() (string, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", fmt.Errorf("reserving a port: %w", err)
	}
	addr := l.Addr().String()
	return addr, l.Close()
}

// END refused OMIT
