// Command platformd serves a development copy of the Acme platform API on
// localhost: an in-memory platform, seeded with three environments and five
// services, that plat can deploy to. Nothing is persisted; restart it for a
// clean platform.
//
//	platformd [--addr 127.0.0.1:8484] [--token TOKEN]
package main

// START imports OMIT

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/platformapi/platformapifake"
)

// END imports OMIT
// START main OMIT

func main() {
	p := &clierr.Program{Name: "platformd"}
	p.Main(run)
}

func run(ctx context.Context) error {
	fs := flag.NewFlagSet("platformd", flag.ContinueOnError)
	addr := fs.String("addr", "127.0.0.1:8484", "listen `ADDRESS`")
	token := fs.String("token", "", "require this bearer `TOKEN` (default: none)")
	if err := fs.Parse(os.Args[1:]); err != nil {
		return &clierr.Error{Code: clierr.ExitUsage, Message: err.Error(), Err: err}
	}

	api := platformapifake.New()
	if *token != "" {
		api.RequireToken(*token)
	}
	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp", *addr)
	if err != nil {
		return err
	}
	srv := &http.Server{
		Handler:           logRequests(api),
		ReadHeaderTimeout: 5 * time.Second,
	}
	fmt.Fprintf(os.Stderr, "platformd: serving the platform API on http://%s\n",
		ln.Addr())
	return serve(ctx, srv, ln)
}

// END main OMIT
// START serve OMIT

// serve runs srv until ctx is cancelled (Ctrl-C), then drains in-flight
// requests for up to five seconds.
func serve(ctx context.Context, srv *http.Server, ln net.Listener) error {
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdown); err != nil {
		return err
	}
	if err := <-errc; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// logRequests logs one line per request to stderr, so a reader running
// plat in one terminal sees in the other exactly which calls it made.
func logRequests(next http.Handler) http.Handler {
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Info("request", "method", r.Method, "path", r.URL.Path,
			"took", time.Since(start).Round(time.Microsecond))
	})
}

// END serve OMIT
