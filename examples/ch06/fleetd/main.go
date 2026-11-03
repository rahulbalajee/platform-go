// Command fleetd serves the fake fleet from internal/sweep/sweeptest on one
// port, for demos, coverage runs and container tests:
//
//	fleetd -addr 127.0.0.1:8080
//
// Paths: /ok (200), /flaky (502 twice, then 200), /down (503), /missing
// (404), /slow (no answer for a minute).
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/rahulbalajee/platform-go/internal/sweep/sweeptest"
	"github.com/rahulbalajee/platform-go/pkg/lifecycle"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8080", "listen address")
	flag.Parse()
	if err := run(*addr); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}

func run(addr string) error {
	ctx, stop := lifecycle.NotifyContext(context.Background(), lifecycle.Options{})
	defer stop()

	srv := &http.Server{
		Addr:              addr,
		Handler:           sweeptest.NewFleet(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	var wg sync.WaitGroup
	wg.Go(func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
		defer cancel()
		if err := srv.Shutdown(sctx); err != nil {
			_ = srv.Close() // /slow handlers outlived the grace period
		}
	})

	log.Printf("fleetd listening on %s", addr)
	err := srv.ListenAndServe()
	stop() // cancels ctx, so the shutdown goroutine finishes even on error
	wg.Wait()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
