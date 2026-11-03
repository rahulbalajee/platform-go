// START imports OMIT

// Command reload is a minimal long-running service: it loads a JSON config
// file, reloads it on SIGHUP (keeping the old config if the new one is
// invalid), and shuts down on SIGINT or SIGTERM.
//
//	reload -config app.json &
//	kill -HUP %1
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

// END imports OMIT

// START config OMIT
// Config is the service's configuration.
type Config struct {
	Version int `json:"version"`
	Workers int `json:"workers"`
}

// load reads and validates a config file. Nothing uses the result until
// it has passed every check.
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
		return nil, fmt.Errorf("%s: workers must be at least 1, got %d",
			path, c.Workers)
	}
	return &c, nil
}

// END config OMIT

// START main OMIT
func logf(format string, args ...any) {
	fmt.Printf("%s reload: %s\n", time.Now().Format("15:04:05.000"),
		fmt.Sprintf(format, args...))
}

func main() {
	path := flag.String("config", "app.json", "config file")
	flag.Parse()
	if err := run(*path); err != nil {
		fmt.Fprintln(os.Stderr, "reload:", err)
		os.Exit(1)
	}
}

// END main OMIT

// START run OMIT
func run(path string) error {
	// Subscribe before anything slow: until Notify runs, SIGHUP kills us.
	hup := make(chan os.Signal, 1) // size 1: reload requests coalesce
	signal.Notify(hup, syscall.SIGHUP)
	defer signal.Stop(hup)
	ctx, stop := signal.NotifyContext(context.Background(),
		os.Interrupt, syscall.SIGTERM)
	defer stop()

	var cfg atomic.Pointer[Config] // request handlers would call cfg.Load()
	c, err := load(path)
	if err != nil {
		return err // a bad config at startup is fatal
	}
	cfg.Store(c)
	logf("pid %d serving with version %d, workers=%d",
		os.Getpid(), c.Version, c.Workers)
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
			logf("stopping: %v", context.Cause(ctx))
			return nil
		}
	}
}

// END run OMIT
