package containers

import (
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"

	"github.com/rahulbalajee/platform-go/internal/sweep"
)

// START skip OMIT
// requireDocker skips the test in -short mode and when no Docker daemon is
// reachable, so the suite degrades to "skipped", never to "failed".
func requireDocker(t *testing.T) {
	t.Helper()
	if testing.Short() {
		t.Skip("needs Docker; skipped in -short mode")
	}
	testcontainers.SkipIfProviderIsNotHealthy(t)
}

// END skip OMIT

// START image OMIT
// fleetImage cross-compiles fleetd for Linux on the host and returns a
// build context holding the binary and a FROM scratch Dockerfile. Building
// it needs no base image, so no registry pull can time out.
func fleetImage(t *testing.T) testcontainers.FromDockerfile {
	t.Helper()
	dir := t.TempDir()
	build := exec.CommandContext(t.Context(), "go", "build", "-trimpath",
		"-o", filepath.Join(dir, "fleetd"), "./examples/ch06/fleetd")
	build.Dir = "../../.." // the root module
	build.Env = append(os.Environ(),
		"CGO_ENABLED=0", "GOOS=linux", "GOARCH="+runtime.GOARCH)
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("building fleetd: %v\n%s", err, out)
	}
	dockerfile := strings.Join([]string{
		"FROM scratch",
		"COPY fleetd /fleetd",
		"USER 65532:65532",
		"EXPOSE 8080",
		`ENTRYPOINT ["/fleetd", "-addr", ":8080"]`,
	}, "\n")
	err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte(dockerfile), 0o600)
	if err != nil {
		t.Fatal(err)
	}
	return testcontainers.FromDockerfile{Context: dir}
}

// END image OMIT

// sweepOnce checks targets with sweep's real HTTP and TCP probers.
func sweepOnce(t *testing.T, targets ...string) map[string]sweep.Result {
	t.Helper()
	inv, err := sweep.ParseTargets(strings.NewReader(strings.Join(targets, "\n")))
	if err != nil {
		t.Fatal(err)
	}
	var d net.Dialer
	runner, err := sweep.NewRunner(sweep.Config{
		Concurrency: 4, PerHost: 4, Timeout: 2 * time.Second,
		Probers: map[sweep.Kind]sweep.Prober{
			sweep.KindHTTP: sweep.HTTPProber{Client: &http.Client{}},
			sweep.KindTCP:  sweep.TCPProber{Dial: d.DialContext},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]sweep.Result{}
	for r := range runner.Run(t.Context(), inv) {
		got[r.Target] = r
	}
	return got
}

// START fleet OMIT
func TestSweepAgainstFleetContainer(t *testing.T) {
	requireDocker(t)
	ctx := t.Context()
	ctr, err := testcontainers.Run(ctx, "",
		testcontainers.WithDockerfile(fleetImage(t)),
		testcontainers.WithExposedPorts("8080/tcp"),
		testcontainers.WithWaitStrategy(wait.ForHTTP("/ok").WithPort("8080/tcp").
			WithStartupTimeout(30*time.Second)),
	)
	testcontainers.CleanupContainer(t, ctr) // registered even if Run failed
	if err != nil {
		t.Fatal(err)
	}
	base, err := ctr.PortEndpoint(ctx, "8080/tcp", "http")
	if err != nil {
		t.Fatal(err)
	}

	got := sweepOnce(t, base+"/ok", base+"/down", base+"/missing")
	for path, want := range map[string]sweep.Status{
		"/ok":      sweep.StatusUp,
		"/down":    sweep.StatusDown,
		"/missing": sweep.StatusDown,
	} {
		if r := got[base+path]; r.Status != want {
			t.Errorf("%s: %s (%s), want %s", path, r.Status, r.Error, want)
		}
	}
}

// END fleet OMIT

// START postgres OMIT
// TestTCPProbeSeesPostgresStop checks a real PostgreSQL, stops it, and
// checks again: the kind of state change a fake can only imitate.
func TestTCPProbeSeesPostgresStop(t *testing.T) {
	requireDocker(t)
	ctx := t.Context()
	ctr, err := testcontainers.Run(ctx, "postgres:17-alpine",
		testcontainers.WithEnv(map[string]string{"POSTGRES_PASSWORD": "test"}),
		testcontainers.WithExposedPorts("5432/tcp"),
		// The entrypoint starts postgres once for initdb, stops it, and starts
		// it for real: ready means the second "ready" line, not the first.
		testcontainers.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).WithStartupTimeout(60*time.Second)),
	)
	testcontainers.CleanupContainer(t, ctr)
	if err != nil {
		t.Fatal(err)
	}
	addr, err := ctr.PortEndpoint(ctx, "5432/tcp", "")
	if err != nil {
		t.Fatal(err)
	}
	target := "tcp://" + addr

	if r := sweepOnce(t, target)[target]; r.Status != sweep.StatusUp {
		t.Fatalf("running postgres: %s (%s), want up", r.Status, r.Error)
	}
	timeout := 10 * time.Second
	if err := ctr.Stop(ctx, &timeout); err != nil {
		t.Fatal(err)
	}
	r := sweepOnce(t, target)[target]
	if r.Status != sweep.StatusDown || r.Attempts != 3 {
		t.Fatalf("stopped postgres: %s after %d attempts (%s), want down after 3",
			r.Status, r.Attempts, r.Error)
	}
	t.Log(r.Error)
}

// END postgres OMIT
