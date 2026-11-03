// START imports OMIT
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"time"
)

// END imports OMIT

// START deploy OMIT
func deploy(ctx context.Context, g globals, args []string,
	getenv func(string) string, stdout io.Writer) error {

	fs := flag.NewFlagSet("deploy", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("deploy needs one VERSION, got %d arguments", fs.NArg())
	}
	version := fs.Arg(0)

	cfg, err := loadConfig(g.config)
	if err != nil {
		return err
	}

	client := newClient(cfg, getenv)
	if err := client.checkAuth(ctx); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "deploying %s %s to %d targets\n",
		cfg.Service, version, len(cfg.Targets))
	for _, target := range cfg.Targets {
		start := time.Now()
		if err := client.Deploy(ctx, target, cfg.Service, version); err != nil {
			return fmt.Errorf("deploy %s to %s: %w", version, target, err)
		}
		fmt.Fprintf(stdout, "  %-11s %-8s %s\n", target, "deployed", elapsed(start))
	}
	return nil
}

// END deploy OMIT
