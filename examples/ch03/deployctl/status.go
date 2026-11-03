package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"

	"github.com/rahulbalajee/platform-go/examples/ch03/fakeapi"
)

// START status OMIT
// status prints what each target runs and what it ran before.
//
// BUG(ch03): status dereferences Previous without checking it, so it
// panics for a target that has only ever had one release. The bug is
// deliberate: Chapter 3 uses it to show what a panic looks like to a user
// when clierr.Program.Run is in charge.
func status(ctx context.Context, g globals, getenv func(string) string,
	log *slog.Logger, stdout io.Writer) error {

	cfg, err := loadConfig(g.config)
	if err != nil {
		return err
	}
	client := newClient(cfg, getenv, log)
	if err := client.checkAuth(ctx); err != nil {
		return err
	}
	var rows []fakeapi.TargetStatus
	if err := client.do(ctx, http.MethodGet, "/v1/status", nil, &rows); err != nil {
		return err
	}
	for _, r := range rows {
		fmt.Fprintf(stdout, "%-11s %s (previous %s since %s)\n", r.Target,
			r.Version, r.Previous.Version, r.Previous.DeployedAt)
	}
	return nil
}

// END status OMIT
