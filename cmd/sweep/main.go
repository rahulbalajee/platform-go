// Command sweep checks a fleet of endpoints concurrently and politely.
//
//	sweep [flags] [file ...]
//
// Targets are read one per line from the named files, or stdin if none:
//
//	https://api.example.com/healthz   HTTP GET, 2xx/3xx is healthy
//	tcp://db.internal:5432            TCP connect
//	tls://example.com:443             TLS handshake + certificate expiry
//	dns://example.com                 DNS resolution
//
// Exit status: 0 all targets up, 1 some down, 2 usage or input error,
// 130 interrupted.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/rahulbalajee/platform-go/internal/sweep"
	"github.com/rahulbalajee/platform-go/pkg/lifecycle"
	"github.com/rahulbalajee/platform-go/pkg/retry"
)

// version is stamped at build time: -ldflags "-X main.version=v1.2.3".
var version = "dev"

const (
	exitOK    = 0
	exitDown  = 1
	exitUsage = 2
)

// START main OMIT
func main() {
	ctx, stop := lifecycle.NotifyContext(context.Background(), lifecycle.Options{})
	code := run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr)
	stop()
	os.Exit(code)
}

// END main OMIT

// START run OMIT
// run is main without the process-global side effects, so tests can call it
// directly with fake arguments, streams and a cancellable context.
func run(ctx context.Context, args []string, stdin io.Reader,
	stdout, stderr io.Writer) int {

	fs := flag.NewFlagSet("sweep", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var (
		concurrency = fs.Int("c", 32, "max targets checked concurrently")
		perHost     = fs.Int("per-host", 4, "max concurrent checks per host")
		qps         = fs.Float64("rate", 50, "max attempts per second (0 = no limit)")
		timeout     = fs.Duration("timeout", 5*time.Second, "timeout per attempt")
		deadline    = fs.Duration("deadline", 0, "overall deadline (0 = none)")
		attempts    = fs.Int("attempts", 3, "attempts per target incl. the first")
		minCert     = fs.Duration("min-cert-validity", 14*24*time.Hour,
			"fail TLS targets whose certificate expires sooner")
		output      = fs.String("o", "table", "output: table, wide, json, jsonl")
		showVersion = fs.Bool("version", false, "print version and exit")
	)
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		return exitUsage
	}
	if *showVersion {
		fmt.Fprintln(stdout, "sweep", version)
		return exitOK
	}

	targets, err := readTargets(fs.Args(), stdin)
	if err != nil {
		fmt.Fprintln(stderr, "sweep:", err)
		return exitUsage
	}
	reporter, err := sweep.NewReporter(*output, stdout)
	if err != nil {
		fmt.Fprintln(stderr, "sweep:", err)
		return exitUsage
	}
	runner, err := sweep.NewRunner(sweep.Config{
		Concurrency: *concurrency,
		PerHost:     *perHost,
		Rate:        *qps,
		Timeout:     *timeout,
		Retry: retry.Policy{
			MaxAttempts: *attempts,
			BaseDelay:   200 * time.Millisecond,
			MaxDelay:    2 * time.Second,
		},
		Probers: defaultProbers(*minCert),
	})
	if err != nil {
		fmt.Fprintln(stderr, "sweep:", err)
		return exitUsage
	}

	if *deadline > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeoutCause(ctx, *deadline,
			fmt.Errorf("sweep deadline of %s exceeded", *deadline))
		defer cancel()
	}

	start := time.Now()
	sum := sweep.Summary{Total: len(targets)}
	for res := range runner.Run(ctx, targets) {
		sum.Tally(res)
		if err := reporter.Add(res); err != nil {
			fmt.Fprintln(stderr, "sweep: writing output:", err)
			return exitUsage // e.g. stdout is a closed pipe; stop early
		}
	}
	sum.Elapsed = time.Since(start)
	sum.Interrupted = ctx.Err() != nil
	if err := reporter.Close(sum); err != nil {
		fmt.Fprintln(stderr, "sweep: writing output:", err)
		return exitUsage
	}
	fmt.Fprintln(stderr, sum)

	switch {
	case sum.Interrupted && isSignal(ctx):
		return lifecycle.ExitInterrupted
	case sum.Healthy():
		return exitOK
	default:
		return exitDown
	}
}

// END run OMIT

func isSignal(ctx context.Context) bool {
	_, ok := errors.AsType[*lifecycle.SignalError](context.Cause(ctx))
	return ok
}

func readTargets(paths []string, stdin io.Reader) ([]sweep.Target, error) {
	if len(paths) == 0 {
		return sweep.ParseTargets(stdin)
	}
	var readers []io.Reader
	for _, p := range paths {
		f, err := os.Open(p)
		if err != nil {
			return nil, err
		}
		defer f.Close()
		readers = append(readers, f)
	}
	return sweep.ParseTargets(io.MultiReader(readers...))
}

// START probers OMIT
func defaultProbers(minCert time.Duration) map[sweep.Kind]sweep.Prober {
	resolver := &sweep.CachingResolver{
		Resolver: net.DefaultResolver,
		TTL:      30 * time.Second,
		Timeout:  5 * time.Second,
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = resolver.DialContext
	transport.MaxIdleConnsPerHost = 8 // keep-alive pool sized for per-host limit
	client := &http.Client{
		Transport: transport,
		// No Client.Timeout: per-attempt deadlines come from the context.
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return retry.Permanent(errors.New("stopped after 5 redirects"))
			}
			return nil
		},
	}
	return map[sweep.Kind]sweep.Prober{
		sweep.KindHTTP: sweep.HTTPProber{
			Client:    client,
			UserAgent: "sweep/" + version,
		},
		sweep.KindTCP: sweep.TCPProber{Dial: resolver.DialContext},
		sweep.KindTLS: sweep.TLSProber{
			Dial:        resolver.DialContext,
			MinValidity: minCert,
		},
		sweep.KindDNS: sweep.DNSProber{Resolver: net.DefaultResolver},
	}
}

// END probers OMIT
