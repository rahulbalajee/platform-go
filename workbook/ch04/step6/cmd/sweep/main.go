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

// START imports OMIT
import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"sweep/internal/sweep"
	"sweep/retry"
)

// END imports OMIT

// version is stamped at build time: -ldflags "-X main.version=v1.2.3".
var version = "dev"

// Exit statuses are sweep's contract with scripts and CI.
const (
	exitOK    = 0 // every target is up
	exitDown  = 1 // at least one target is down, or the run was cut short
	exitUsage = 2 // bad flags, bad inventory, or output that can't be written
)

// exitInterrupted is the conventional status of a process stopped by
// Ctrl-C: 128 plus the number of SIGINT, which is 2.
const exitInterrupted = 130

func main() {
	// The context is cancelled on the first SIGINT (Ctrl-C) or SIGTERM.
	ctx, stop := signal.NotifyContext(context.Background(),
		os.Interrupt, syscall.SIGTERM)
	code := run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr)
	stop()
	os.Exit(code)
}

// START flags OMIT
// options is the parsed command line.
type options struct {
	concurrency int
	perHost     int
	rate        float64
	timeout     time.Duration
	attempts    int
	minCert     time.Duration
	output      string
	files       []string // inventory files; none means stdin
}

// parseFlags parses the command line. On a usage error the flag package
// has already printed the problem and the usage text to stderr.
func parseFlags(args []string, stderr io.Writer) (options, error) {
	var o options
	fs := flag.NewFlagSet("sweep", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.IntVar(&o.concurrency, "c", 32, "max targets checked concurrently")
	fs.IntVar(&o.perHost, "per-host", 4, "max concurrent checks per host")
	fs.Float64Var(&o.rate, "rate", 50, "max attempts per second (0 = no limit)")
	fs.DurationVar(&o.timeout, "timeout", 5*time.Second, "timeout per attempt")
	fs.IntVar(&o.attempts, "attempts", 3, "attempts per target incl. the first")
	fs.DurationVar(&o.minCert, "min-cert-validity", 14*24*time.Hour,
		"fail TLS targets whose certificate expires sooner")
	fs.StringVar(&o.output, "o", "table", "output: table, wide, json, jsonl")
	err := fs.Parse(args)
	o.files = fs.Args()
	return o, err
}

// END flags OMIT

// START run OMIT
// run is main without the process-global side effects, so tests can call it
// directly with fake arguments, streams and a cancellable context. It
// returns the exit status.
func run(ctx context.Context, args []string, stdin io.Reader,
	stdout, stderr io.Writer) int {

	opts, err := parseFlags(args, stderr)
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK // -h asked for the usage text; it was printed
		}
		return exitUsage
	}
	targets, err := readTargets(opts.files, stdin)
	if err != nil {
		fmt.Fprintln(stderr, "sweep:", err)
		return exitUsage
	}
	reporter, err := sweep.NewReporter(opts.output, stdout)
	if err != nil {
		fmt.Fprintln(stderr, "sweep:", err)
		return exitUsage
	}
	runner, err := newRunner(opts)
	if err != nil {
		fmt.Fprintln(stderr, "sweep:", err)
		return exitUsage
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
	case sum.Interrupted:
		return exitInterrupted
	case sum.Healthy():
		return exitOK
	default:
		return exitDown
	}
}

// END run OMIT

// readTargets parses the inventory from the named files, in order, or from
// stdin when there are none.
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

// newRunner turns the command line into a validated sweep.Runner.
func newRunner(o options) (*sweep.Runner, error) {
	return sweep.NewRunner(sweep.Config{
		Concurrency: o.concurrency,
		PerHost:     o.perHost,
		Rate:        o.rate,
		Timeout:     o.timeout,
		Retry: retry.Policy{
			MaxAttempts: o.attempts,
			BaseDelay:   200 * time.Millisecond,
			MaxDelay:    2 * time.Second,
		},
		Probers: defaultProbers(o.minCert),
	})
}

// defaultProbers wires one prober per target kind. HTTP, TCP and TLS share
// a resolver that caches lookups and merges concurrent ones.
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
