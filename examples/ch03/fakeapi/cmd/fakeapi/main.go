// Command fakeapi serves the fake deployment API on a local address so the
// deployctl example can be run by hand:
//
//	go run ./examples/ch03/fakeapi/cmd/fakeapi -addr 127.0.0.1:8787
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/rahulbalajee/platform-go/examples/ch03/fakeapi"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8787", "listen address")
	flag.Parse()
	if err := serve(*addr); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}

func serve(addr string) error {
	ctx, stop := signal.NotifyContext(context.Background(),
		syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	srv := &http.Server{
		Addr:              addr,
		Handler:           fakeapi.New(fakeapi.Options{}),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()
	log.Printf("fake deploy API on http://%s", addr)
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
