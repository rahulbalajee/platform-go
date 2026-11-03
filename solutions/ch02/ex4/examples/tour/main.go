// START head OMIT

// Command tour drives the platformapi SDK against an in-process fake of
// the platform API and prints what happens. Each scenario starts from a
// fresh fake:
//
//	tour pages|deploy|flaky|errors
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"
	"time"

	"platformapi"
	"platformapi/platformapifake"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	code := 0
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: tour pages|deploy|flaky|errors")
		code = 2
	} else if err := run(ctx, os.Args[1], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "tour:", err)
		code = 1
	}
	stop()
	os.Exit(code)
}

// END head OMIT

// START run OMIT
func run(ctx context.Context, scenario string, out io.Writer) error {
	fake := platformapifake.New()
	fake.RequireToken("tour-token")
	srv := httptest.NewServer(fake)
	defer srv.Close()

	level := slog.LevelWarn
	if scenario == "pages" {
		level = slog.LevelDebug // show every request
	}
	logger := slog.New(slog.NewTextHandler(out, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			if a.Key == slog.TimeKey || a.Key == "took" || a.Key == "request_id" {
				return slog.Attr{} // keep the demo's log lines short
			}
			return a
		},
	}))
	// START setup OMIT
	client, err := platformapi.New(srv.URL,
		platformapi.WithToken("tour-token"),
		platformapi.WithUserAgent("tour/1.0"),
		platformapi.WithLogger(logger),
		platformapi.WithPollInterval(100*time.Millisecond),
	)
	// END setup OMIT
	if err != nil {
		return err
	}
	switch scenario {
	case "pages":
		return pages(ctx, client, fake, out)
	case "deploy":
		return deploy(ctx, client, out)
	case "flaky":
		return flaky(ctx, client, fake, out)
	case "errors":
		return failures(ctx, client, fake, out)
	}
	return fmt.Errorf("unknown scenario %q", scenario)
}

// END run OMIT

// START pages OMIT
func pages(ctx context.Context, client *platformapi.Client,
	fake *platformapifake.Server, out io.Writer) error {

	fmt.Fprintln(out, "five most recent deployments, three per page:")
	n := 0
	for d, err := range client.ListDeployments(ctx,
		platformapi.DeploymentFilter{}, platformapi.PageSize(3)) {
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "  %-4s %-9s %-8s %-7s %s\n",
			d.ID, d.Service, d.Environment, d.Version, d.State)
		if n++; n == 5 {
			break
		}
	}
	fmt.Fprintf(out, "requests sent: %d\n", len(fake.Requests()))
	return nil
}

// END pages OMIT

// START deploy OMIT
func deploy(ctx context.Context, client *platformapi.Client, out io.Writer) error {
	op, err := client.CreateDeployment(ctx, platformapi.CreateDeploymentRequest{
		Service: "checkout", Environment: "staging", Version: "v1.5.0",
		Reason: "release train 2026-11-03",
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "%s started: deployment %s is %s\n",
		op.ID, op.Result.ID, op.Result.State)
	for snap, err := range client.Poll(ctx, op) {
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "  %s %s\n", snap.ID, snap.Message)
	}

	logs, err := client.DeploymentLogs(ctx, op.Result.ID)
	if err != nil {
		return err
	}
	defer logs.Close()
	sc := bufio.NewScanner(logs) // any io.Reader composes with the stdlib
	for sc.Scan() {
		fmt.Fprintf(out, "  | %s\n", sc.Text())
	}
	return sc.Err()
}

// END deploy OMIT

// START short OMIT
func short(id string) string {
	if len(id) > 13 {
		return id[:13] + "…"
	}
	return id
}

// END short OMIT

// START flaky OMIT
func flaky(ctx context.Context, client *platformapi.Client,
	fake *platformapifake.Server, out io.Writer) error {

	fake.FailNext(2, http.StatusServiceUnavailable, 0)
	fake.FailNext(1, http.StatusTooManyRequests, time.Second)
	op, err := client.CreateDeployment(ctx, platformapi.CreateDeploymentRequest{
		Service: "checkout", Environment: "staging", Version: "v1.5.0",
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "created %s after %d attempts; the server saw:\n",
		op.ID, len(fake.Requests()))
	for _, r := range fake.Requests() {
		fmt.Fprintf(out, "  %s %s  request %s  key %s\n",
			r.Method, r.Path, short(r.RequestID), short(r.IdempotencyKey))
	}

	// A CI job retried after a crash: same key, same operation.
	key := platformapi.IdempotencyKey("pipeline-981-ledger-dev")
	req := platformapi.CreateDeploymentRequest{
		Service: "ledger", Environment: "dev", Version: "v2.0.1",
	}
	first, err := client.CreateDeployment(ctx, req, key)
	if err != nil {
		return err
	}
	again, err := client.CreateDeployment(ctx, req, key)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "create with key twice: %s, then %s\n", first.ID, again.ID)
	return nil
}

// END flaky OMIT

// START errors OMIT
func failures(ctx context.Context, client *platformapi.Client,
	fake *platformapifake.Server, out io.Writer) error {

	_, err := client.GetDeployment(ctx, "d-404")
	fmt.Fprintf(out, "not found: errors.Is(err, ErrNotFound)=%t\n",
		errors.Is(err, platformapi.ErrNotFound))
	if apiErr, ok := errors.AsType[*platformapi.APIError](err); ok {
		fmt.Fprintf(out, "  op=%q status=%d code=%s\n  message=%q\n  request=%s\n",
			apiErr.Op, apiErr.StatusCode, apiErr.Code, apiErr.Message,
			apiErr.RequestID)
	}

	req := platformapi.CreateDeploymentRequest{
		Service: "search", Environment: "staging", Version: "v3.1.0",
	}
	op, err := client.CreateDeployment(ctx, req)
	if err != nil {
		return err
	}
	_, err = client.CreateDeployment(ctx, req)
	fmt.Fprintf(out, "conflict: errors.Is(err, ErrConflict)=%t\n",
		errors.Is(err, platformapi.ErrConflict))

	// Stop waiting after 250ms. The rollout needs six polls, 500ms.
	short, cancel := context.WithTimeout(ctx, 250*time.Millisecond)
	defer cancel()
	_, err = client.Wait(short, op)
	d, _ := client.GetDeployment(ctx, op.Result.ID)
	fmt.Fprintf(out, "timeout: %v\n  %s is still %s on the server\n",
		err, d.ID, d.State)

	fake.BreakVersion("v1.6.0-rc.1")
	op, err = client.CreateDeployment(ctx, platformapi.CreateDeploymentRequest{
		Service: "checkout", Environment: "dev", Version: "v1.6.0-rc.1",
	})
	if err != nil {
		return err
	}
	d, err = client.Wait(ctx, op)
	opErr, _ := errors.AsType[*platformapi.OperationError](err)
	fmt.Fprintf(out, "rollout: %v\n  code=%s; %s ended %s at %d/%d replicas\n", err,
		opErr.Code, d.ID, d.State, d.UpdatedReplicas, d.Replicas)
	return nil
}

// END errors OMIT
