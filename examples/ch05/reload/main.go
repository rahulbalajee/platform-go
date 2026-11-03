// Command reload is a minimal long-running service: it loads a JSON config
// file, reloads it on SIGHUP (keeping the old config if the new one is
// invalid), and shuts down on SIGINT or SIGTERM through pkg/lifecycle.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/lifecycle"
)

// Config is the service's configuration.
type Config struct {
	Version int `json:"version"`
	Workers int `json:"workers"`
}

func load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if c.Workers < 1 {
		return nil, fmt.Errorf("%s: workers must be at least 1, got %d", path, c.Workers)
	}
	return &c, nil
}

func logf(format string, args ...any) {
	fmt.Printf("%s reload: %s\n", time.Now().Format("15:04:05.000"), fmt.Sprintf(format, args...))
}

func main() {
	path := flag.String("config", "app.json", "config file")
	flag.Parse()
	if err := run(*path); err != nil {
		fmt.Fprintln(os.Stderr, "reload:", err)
		os.Exit(1)
	}
}

func run(path string) error {
	ctx, stop := lifecycle.NotifyContext(context.Background(), lifecycle.Options{})
	defer stop()

	var cfg atomic.Pointer[Config] // request handlers would Load() this
	c, err := load(path)
	if err != nil {
		return err // a bad config at startup is fatal
	}
	cfg.Store(c)
	logf("pid %d serving with version %d, workers=%d",
		os.Getpid(), c.Version, c.Workers)

	// START run OMIT
	hup := make(chan os.Signal, 1) // size 1: reload requests coalesce
	signal.Notify(hup, syscall.SIGHUP)
	defer signal.Stop(hup)
	for {
		select {
		case <-hup:
			next, err := load(path)
			if err != nil { // a bad config at reload is not: keep serving
				logf("SIGHUP: keeping version %d: %v", cfg.Load().Version, err)
				continue
			}
			prev := cfg.Swap(next)
			logf("SIGHUP: version %d -> %d, workers=%d",
				prev.Version, next.Version, next.Workers)
		case <-ctx.Done():
			cause := context.Cause(ctx)
			if _, ok := errors.AsType[*lifecycle.SignalError](cause); ok {
				logf("stopped cleanly")
				return nil
			}
			return cause
		}
	}
	// END run OMIT
}
