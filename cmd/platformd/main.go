// Command platformd serves a development copy of the Acme platform on
// localhost: the in-memory platform API, seeded with three environments and
// five services, and an OpenID Connect provider that plat logs in with.
// Nothing is persisted; restart it for a clean platform.
//
//	platformd [--addr 127.0.0.1:8484] [--auto-approve EMAIL] [--github]
//	platformd --auth token --token TOKEN
//	platformd --auth none
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

	"github.com/rahulbalajee/platform-go/internal/platformd"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
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
	var o platformd.Options
	fs.StringVar(&o.Issuer, "issuer", "", "public `URL` (default http://ADDRESS)")
	fs.StringVar(&o.Auth, "auth", "oidc", "authentication: oidc, token or none")
	fs.StringVar(&o.Token, "token", "", "the static `TOKEN` for --auth token")
	fs.StringVar(&o.AutoApprove, "auto-approve", "",
		"approve every login as `EMAIL`, without the browser")
	fs.IntVar(&o.Interval, "interval", 5, "device login polling interval, `SECONDS`")
	fs.DurationVar(&o.TokenTTL, "token-ttl", 10*time.Minute, "access token lifetime")
	fs.BoolVar(&o.GitHub, "github", false, "also accept GitHub user tokens")
	if err := fs.Parse(os.Args[1:]); err != nil {
		return &clierr.Error{Code: clierr.ExitUsage, Message: err.Error(), Err: err}
	}

	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp", *addr)
	if err != nil {
		return err
	}
	if o.Issuer == "" {
		o.Issuer = "http://" + ln.Addr().String()
	}
	o.Log = slog.New(slog.NewTextHandler(os.Stderr, nil))
	srv, err := platformd.New(o)
	if err != nil {
		return &clierr.Error{Code: clierr.ExitUsage, Message: err.Error(), Err: err}
	}
	fmt.Fprintf(os.Stderr, "platformd: serving the platform API and the login "+
		"provider on %s (auth %s)\n", o.Issuer, o.Auth)
	hs := &http.Server{Handler: srv, ReadHeaderTimeout: 5 * time.Second}
	return serve(ctx, hs, ln)
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

// END serve OMIT
