// START head OMIT

// Package wasmext runs pre-deploy checks that other teams write in any
// language and ship as WebAssembly modules. A check is a WASI command (a
// program compiled with GOOS=wasip1 GOARCH=wasm, or for wasm32-wasip1 in
// Rust): it reads the deployment as JSON (policy.Input) on stdin and exits
// 0 to allow it, or 1 to refuse it with a message on stdout.
//
// Checks run in wazero, a WebAssembly runtime written in Go with no
// dependencies, as sandboxes: no files, no network, no environment
// variables, a fixed amount of memory and a time limit. A check that
// breaks a limit or crashes blocks the deployment (fail closed).
package wasmext

// END head OMIT
// START imports OMIT

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
	"github.com/tetratelabs/wazero/sys"

	"github.com/rahulbalajee/platform-go/internal/plat/policy"
)

// END imports OMIT
// START limits OMIT

// Limits for one run of a check.
const (
	// MemoryPages caps linear memory: 1024 pages of 64 KiB, 64 MiB. A Go
	// module needs a few MiB to start.
	MemoryPages = 1024
	// Timeout stops a check that runs too long, an infinite loop included:
	// wazero checks the context while the module runs.
	Timeout = 2 * time.Second
	// outputLimit caps what a check may print; the rest is dropped.
	outputLimit = 4 << 10
)

// END limits OMIT
// START runner OMIT

// Runner holds the compiled checks and the runtime they run in.
type Runner struct {
	rt     wazero.Runtime
	checks []check
}

type check struct {
	name, source string
	mod          wazero.CompiledModule
}

// Load compiles every *.wasm file in dirs. Compiling a module to machine
// code takes most of a second for a Go module, so compiled code is kept in
// cacheDir (if not empty) and reused while the file is unchanged.
func Load(ctx context.Context, cacheDir string, dirs ...string) (*Runner, error) {
	cfg := wazero.NewRuntimeConfig().
		WithCloseOnContextDone(true). // so Timeout can stop a loop
		WithMemoryLimitPages(MemoryPages)
	if cacheDir != "" {
		cache, err := wazero.NewCompilationCacheWithDir(cacheDir)
		if err != nil {
			return nil, err
		}
		cfg = cfg.WithCompilationCache(cache)
	}
	r := &Runner{rt: wazero.NewRuntimeWithConfig(ctx, cfg)}
	// WASI preview 1: the system calls a command needs (stdin, stdout,
	// exit, clocks). Nothing else is imported, so nothing else exists.
	wasi_snapshot_preview1.MustInstantiate(ctx, r.rt)

	var errs []error
	for _, dir := range dirs {
		paths, _ := filepath.Glob(filepath.Join(dir, "*.wasm"))
		for _, path := range paths {
			b, err := os.ReadFile(path)
			if err != nil {
				errs = append(errs, err)
				continue
			}
			mod, err := r.rt.CompileModule(ctx, b)
			if err != nil {
				errs = append(errs, fmt.Errorf("%s: %w", path, err))
				continue
			}
			name := strings.TrimSuffix(filepath.Base(path), ".wasm")
			r.checks = append(r.checks, check{name: name, source: path, mod: mod})
		}
	}
	return r, errors.Join(errs...)
}

// Close releases the runtime and its compiled modules.
func (r *Runner) Close(ctx context.Context) error { return r.rt.Close(ctx) }

// Len reports how many checks were loaded.
func (r *Runner) Len() int { return len(r.checks) }

// Names lists the checks with the file each came from.
func (r *Runner) Names() []policy.Result {
	var out []policy.Result
	for _, c := range r.checks {
		out = append(out, policy.Result{Name: c.name, Kind: "wasm", Source: c.source})
	}
	return out
}

// END runner OMIT
// START check OMIT

// Check runs every check against in, one after another.
func (r *Runner) Check(ctx context.Context, in policy.Input) []policy.Result {
	input, err := json.Marshal(in)
	var out []policy.Result
	for _, c := range r.checks {
		res := policy.Result{Name: c.name, Kind: "wasm", Source: c.source}
		if err != nil {
			res.Status, res.Message = policy.Error, err.Error()
		} else {
			res.Status, res.Message = r.run(ctx, c, input)
		}
		out = append(out, res)
	}
	return out
}

// run instantiates the module, which runs its main function to the end:
// a fresh instance for every run, so no state leaks from one deployment's
// check into the next.
func (r *Runner) run(ctx context.Context, c check,
	input []byte,
) (policy.Status, string) {
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	stdout, stderr := &capped{max: outputLimit}, &capped{max: outputLimit}
	cfg := wazero.NewModuleConfig().
		WithName(""). // anonymous, so the same module can run again
		WithArgs(c.name).
		WithStdin(bytes.NewReader(input)).
		WithStdout(stdout).
		WithStderr(stderr)
	mod, err := r.rt.InstantiateModule(ctx, c.mod, cfg)
	if mod != nil {
		_ = mod.Close(ctx)
	}
	code := uint32(0)
	if ee, ok := errors.AsType[*sys.ExitError](err); ok {
		code, err = ee.ExitCode(), nil
	}
	msg := strings.TrimSpace(stdout.String())
	switch {
	case err != nil: // a trap: out of bounds, unreachable, a bad import
		return policy.Error, "crashed: " + err.Error()
	case code == 0:
		return policy.Pass, ""
	case code == 1:
		return policy.Fail, msg
	case code == sys.ExitCodeDeadlineExceeded:
		return policy.Error, fmt.Sprintf("stopped after %v", Timeout)
	case code == sys.ExitCodeContextCanceled:
		return policy.Error, "cancelled"
	}
	return policy.Error, fmt.Sprintf("exit status %d: %s", code,
		lastLine(stderr.String()))
}

// END check OMIT
// START capped OMIT

// capped is a buffer that keeps the first max bytes written to it. It never
// fails a write: a check that prints too much loses output, not its result.
type capped struct {
	bytes.Buffer
	max int
}

func (c *capped) Write(p []byte) (int, error) {
	if room := c.max - c.Len(); room > 0 {
		c.Buffer.Write(p[:min(len(p), room)])
	}
	return len(p), nil
}

// lastLine returns the last non-empty line of s: for a Go program that
// crashed, the panic message is near the end of the trace.
func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for _, l := range slices.Backward(lines) {
		if l = strings.TrimSpace(l); strings.HasPrefix(l, "panic:") ||
			strings.HasPrefix(l, "fatal error:") {
			return l
		}
	}
	return lines[len(lines)-1]
}

// END capped OMIT
