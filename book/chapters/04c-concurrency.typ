#import "../template/book.typ": *

== Shared state: mutexes, atomics, and ownership <sec-shared>

"Don't communicate by sharing memory; share memory by communicating" is the
Go proverb everyone quotes. The standard library itself uses far more mutexes
than channels, and that is not a contradiction. Channels are for transferring
_ownership_ of data and for _coordination_ (start, stop, done, here is the
next item). Mutexes are for _protecting state_ that several goroutines touch.
Use the one that matches what you are doing:

#table(
  columns: (auto, 1fr),
  table.header([Tool], [Reach for it when]),
  [Ownership], [One goroutine owns the data and everyone else talks to it. No locks at all. `sweep`'s reporter is owned by the `range` loop, which is the only code that touches it.],
  [Channel], [Handing work or results between goroutines, signalling completion or cancellation, bounding concurrency (as a semaphore).],
  [`sync.Mutex`], [Several goroutines read and write a small piece of state: a map, a cache, a counter with invariants. Keep critical sections tiny and never block (I/O, channel sends, network calls) while holding the lock.],
  [`sync.RWMutex`], [Reads vastly outnumber writes _and_ the critical section is long enough to matter. Otherwise a plain mutex is as fast and simpler. Never acquire a read lock recursively: a waiting writer blocks new readers, so a nested `RLock` can deadlock.],
  [`sync/atomic` types], [Independent counters, gauges and flags: `atomic.Int64`, `atomic.Bool`, `atomic.Pointer[T]`. The typed API (Go 1.19) prevents mixing atomic and plain access to the same word, and Go 1.27's `go fix` includes an `atomictypes` modernizer that migrates the old function-style calls.],
  [`sync.OnceValue`], [Lazy, concurrency-safe initialisation of an expensive value, such as a parsed config or an SDK client (Go 1.21).],
  [`sync.Map`], [Mostly append-only caches, or goroutines working on disjoint keys. For anything else, a map plus a mutex is clearer and usually faster.],
)

The pattern to prefer whenever you can is the first row. Look at how `sweep`
consumes results:

#src("cmd/sweep/main.go", region: "run")

The summary and the reporter are mutated only inside the `for res := range`
loop, which runs on one goroutine. Dozens of workers produce results
concurrently, yet there is no lock anywhere in the reporting path, because the
iterator hands results across a channel and the consumer owns everything after
that. When you find yourself adding a mutex to an output formatter, ask
whether one goroutine could own it instead.

== Graceful shutdown in two stages <sec-shutdown>

Every long-running tool is eventually interrupted. A developer presses
#kbd("Ctrl-C") because they spotted a typo in the inventory. Kubernetes sends
`SIGTERM` to a pod and starts the `terminationGracePeriodSeconds` clock (30
seconds by default) before it sends `SIGKILL`. A CI system cancels a job and
sends `SIGINT`, then escalates to `SIGTERM` and `SIGKILL` a few seconds later.
Each of these is a request to stop _soon_, and a well-behaved tool does three
things in response:

+ Stop starting new work.
+ Cancel or finish in-flight work within a bounded time, and report what
  happened, including partial results.
+ Exit with a status that tells the caller it was interrupted (130 for
  `SIGINT`, by convention 128 + the signal number), not "success" and not a
  generic failure.

There is a fourth requirement that people forget until they have been burned
by it. If graceful shutdown itself hangs (a stuck write, a dependency that
never answers), the user must be able to force the issue. The convention
across Docker, kubectl, Terraform and most well-behaved CLIs is the same: the
first #kbd("Ctrl-C") asks politely, the second one means it.

#src("pkg/lifecycle/lifecycle.go", region: "notify")

The details that make this production-grade:

- The signal channel is buffered. `signal.Notify` never blocks when delivering
  a signal; if the channel is full, the signal is dropped. With a buffer of
  two, a fast double-tap is never lost.
- The cancellation cause is a typed `*SignalError`, so callers can tell
  "interrupted by the user" from "deadline exceeded" with
  `errors.AsType`. That is how `sweep` decides between exit status 130 and 1.
- `Exit` and `Stderr` are injectable, so the two-stage behaviour has a real
  test (@sec-testing), not a manual check.
- `stop` is idempotent, unregisters the handler (restoring the default
  "kill the process" behaviour for later signals), waits for the helper
  goroutine, and cancels the context. Rule zero again.

`main` stays tiny, and that is deliberate:

#src("cmd/sweep/main.go", region: "main")

`os.Exit` skips deferred functions, so `main` calls `stop()` explicitly before
exiting, and everything interesting lives in `run`, which returns an exit code
instead of calling `os.Exit`. Chapter 7 develops this pattern into a full
CLI architecture.

#production(title: [Shutdown in Kubernetes is a race])[
  When a pod is deleted, the kubelet sends `SIGTERM` _at the same time_ as the
  endpoints controller starts removing the pod from Service endpoints. For a
  few seconds your process is shutting down while load balancers and
  kube-proxy may still route new requests to it. Servers (Chapter 13) handle
  this by failing their readiness probe first, sleeping briefly in a
  `preStop` hook or in code, and only then draining. For batch-style tools
  like `sweep`, the lesson is simpler: make the grace period you need explicit
  in the Job spec, and make sure your shutdown path finishes well inside it.
]

== Assembling `sweep` <sec-sweep>

Every piece is now in place. @fig-sweep shows how they fit together, and the
rest of this section walks the request path from the top.

#fig(placement: auto, caption: [The `sweep` architecture. Limits are applied in a fixed order: global concurrency, per-host slot, then a rate-limit token per attempt.])[
  #diagram(
    spacing: (34pt, 9pt),
    dnode((0, 0), [inventory file / stdin], kind: "muted"),
    dnode((0, 1), [`ParseTargets` · all errors, with line numbers], kind: "default"),
    dnode((0, 2), [`conc.Stream` · ≤ `-c` checks in flight], kind: "dark"),
    dnode((0, 3), [`KeyedSemaphore` · ≤ `--per-host` per host:port], kind: "accent"),
    dnode((0, 4), [`retry.Policy.Do` · full jitter, Permanent, After], kind: "accent"),
    dnode((0, 5), [`rate.Limiter.Wait` · every attempt], kind: "accent"),
    dnode((0, 6), [attempt context · `--timeout`, `errAttemptTimeout`], kind: "default"),
    dnode((0, 7), [Prober: HTTP · TCP · TLS · DNS], kind: "default"),
    dnode((1, 2), [`range` loop (single owner)\ → Summary + Reporter], kind: "dark"),
    dnode((1, 3), [stdout: table · wide · json · jsonl\ stderr: summary · exit code], kind: "muted"),
    dnode((1, 7), [`CachingResolver`\ TTL + singleflight], kind: "good"),
    dnode((1, 8), [network], kind: "muted"),
    dedge((0, 0), (0, 1), "-|>"),
    dedge((0, 1), (0, 2), "-|>"),
    dedge((0, 2), (0, 3), "-|>"),
    dedge((0, 3), (0, 4), "-|>"),
    dedge((0, 4), (0, 5), "-|>"),
    dedge((0, 5), (0, 6), "-|>"),
    dedge((0, 6), (0, 7), "-|>"),
    dedge((0, 2), (1, 2), "--|>", label: [results]),
    dedge((1, 2), (1, 3), "-|>"),
    dedge((0, 7), (1, 7), "-|>", label: [lookups]),
    dedge((1, 7), (1, 8), "-|>"),
  )
] <fig-sweep>

=== The checker

`Runner.Run` is a single line: a `conc.Stream` over the targets. The real work
is the per-target `check`, which applies the limits in order and turns every
outcome into a `Result`:

#src("internal/sweep/runner.go", region: "check")

A few choices are worth calling out. The attempt timeout uses
`WithTimeoutCause`, so a slow target reads "attempt timed out after 5s" in the
report, while a cancelled run reads `cancelled`. Latency and detail are
recorded for every attempt, so a target that eventually fails shows the
latency of its _last_ try, which is usually what you want when you
investigate. And the function never returns an error: whatever happens
becomes data in the `Result`.

=== The probers

Probers implement a one-method interface, which keeps the runner ignorant of
protocols and makes testing trivial. A `ProberFunc` adapter lets tests inject
behaviour without declaring a type, in the same style as `http.HandlerFunc`:

#src("internal/sweep/probe.go", region: "prober")

The HTTP prober is where error classification lives:

#src("internal/sweep/probe.go", region: "http")

Read the switch as a policy table. Success is anything below 400, so redirects
count as healthy (the client follows up to five). 429 and 503 are retryable and
honour `Retry-After`. Other 5xx are retryable. Remaining 4xx are permanent.
Certificate verification failures are permanent too: an expired certificate
won't renew itself between attempts.

The response body is read up to 64 KiB before closing. HTTP/1.1 can only reuse
a connection whose body was fully consumed, and connection reuse matters when
you are checking 300 endpoints on one load balancer. Go 1.27 drains unread
bodies on `Close` automatically, up to a conservative limit. Draining
explicitly keeps the behaviour identical on older toolchains and makes the
intent visible.

=== Wiring

#src("cmd/sweep/main.go", region: "probers")

The HTTP client deliberately sets no `Client.Timeout`. Deadlines come from the
context, per attempt, and a second, competing timeout would only produce
confusing errors. The transport is cloned from `http.DefaultTransport`, which
keeps its sensible defaults (proxy from the environment, HTTP/2, idle
timeouts), and gets the caching dialer and a per-host idle pool sized to
match `--per-host`.

=== Running it

The repository ships a sample inventory of public endpoints chosen to exercise
every outcome: healthy sites, an endpoint that always returns 503, a 404, an
expired certificate (courtesy of `badssl.com`), a closed TCP port, and a name
that doesn't exist.

#output("sweep-table.txt", cmd: "sweep -timeout 3s fleet.txt")
#output("sweep-table.err", title: "stderr")

Read the `TRIES` column against the classification rules. The 503 was tried
three times. The 404, the bad certificate, and `NXDOMAIN` were tried once,
because retrying them would be pointless. The closed port was retried, since
"connection refused" is often a service mid-restart. In this run the expired
certificate on the HTTPS target took three attempts: the first two attempts
timed out (`badssl.com` is a shared public service and is sometimes slow),
which is retryable, and the third reached the server and got a definitive
certificate error. The output also shows why per-attempt timeouts and
error-specific retry rules both matter. The whole sweep took roughly as long as
its slowest target, not the sum of all of them, and the process exited with
status 1, so a CI step running `sweep` fails the pipeline.

For automation, `-o jsonl` streams one JSON object per result as soon as it
completes, which composes with `jq`:

#output("sweep-jq.txt", cmd: "sweep -o jsonl fleet.txt | jq -c 'select(.status==\"down\") | {target, attempts, error}'")

Exercise 3 at the end of the chapter turns `sweep` into a deploy gate for the
`ship` CLI in Chapter 23.

== Testing concurrent code deterministically <sec-testing>

Concurrent code earns its reputation for flaky tests in two ways: tests that
depend on timing (`time.Sleep(100 * time.Millisecond)` and hope), and tests
that pass while hiding races and leaks. Go now has good answers to both.

=== Always: `-race` and leak checks

The race detector instruments memory accesses and reports conflicting
unsynchronized accesses that actually happen during the run. It typically
costs several times more CPU and memory, so it doesn't belong in production
builds, but `go test -race ./...` belongs in CI for every module in this book.
It only finds races your tests exercise, so concurrent tests should really run
things concurrently.

Leaks need a separate check. `go.uber.org/goleak` compares the goroutines
alive at the end of a test, or of the whole package, with those alive at the
start, and fails if anything new is still running:

#code(file: "pkg/conc/conc_test.go")[```go
// TestMain fails the package if any test leaves a goroutine behind.
func TestMain(m *testing.M) { goleak.VerifyTestMain(m) }
```]

In `pkg/conc` this one line turns rule zero from a convention into an
enforced property.

=== Virtual time with `testing/synctest`

The retry policy sleeps between attempts, and the runner enforces timeouts of
several seconds. Testing them with real time is slow, and testing them with
short real timeouts is flaky. The traditional fix was to inject a fake clock
interface through every layer of the code, which is invasive and easy to get
wrong.

Go 1.25 made `testing/synctest` generally available, and it removes the need
for clock injection. `synctest.Test` runs a function in an isolated _bubble_.
Inside the bubble, the `time` package uses a fake clock that starts at
midnight UTC on 2000-01-01, and that clock only advances when every goroutine
in the bubble is _durably blocked_: waiting on a channel, timer, `select`,
`sync.Cond`, or `WaitGroup` that belongs to the bubble. Time then jumps
straight to the next timer that would unblock something. Production code
needs no changes at all.

#src("pkg/retry/retry_test.go", region: "test")

That test exercises three backoff sleeps and finishes in microseconds of real
time, with exact, deterministic timing assertions. `synctest.Wait()` blocks
until every other goroutine in the bubble is durably blocked, which is how
the keyed semaphore test asserts that a third `Acquire` really _is_ waiting
without sleeping and hoping.

#newingo("1.27", title: [In-memory networks for synctest])[
  Real sockets are not durably blocking, because a packet from outside the
  bubble could wake them, so `synctest` alone can't virtualize an HTTP
  round trip. Go 1.27 adds `httptest.NewTestServer`, which creates a test
  server on an in-memory fake network suitable for bubbles. Its `Client()`
  talks to that network. Server handlers that sleep for ten seconds, clients
  that time out after two, and retries with backoff all run in virtual time.
  Go 1.27 also adds `synctest.Sleep(d)`, shorthand for `time.Sleep(d)`
  followed by `synctest.Wait()`.
]

Here is the fixture for the runner's test: one fake service with a path per
behaviour.

#src("internal/sweep/runner_test.go", region: "fixture")

And the test that checks the classification rules end to end, with a
three-attempt timeout sequence that would take six real seconds:

#src("internal/sweep/runner_test.go", region: "test")

#output("synctest-run.txt", cmd: "go test -v -run 'TestRunnerOutcomes|TestDoRetriesUntilSuccess' ./internal/sweep ./pkg/retry")

`TestRunnerOutcomes` reports 0.00s. The six seconds of timeouts happened in
virtual time. The test asserts that the sweep took between 6 and 6.3 seconds
_of bubble time_, which is a precise statement about the retry and timeout
behaviour that no real-time test could make reliably.

#warning(title: [What synctest can't see])[
  Locking a `sync.Mutex`, blocking on real I/O, and system calls are _not_
  durably blocking, because something outside the bubble could unblock them.
  A goroutine stuck on a mutex inside a bubble stops the fake clock from
  advancing, and the test deadlocks. Keep mutex critical sections short (good
  advice anyway), use the in-memory network, and keep real sockets, files and
  subprocesses out of bubbles. Test those with the real clock, as
  `TestUntrustedCertificateIsNotRetried` and the end-to-end CLI test do.
]

=== Testing the binary's behaviour

The `run` function makes the CLI testable without building a binary:

#src("cmd/sweep/main_test.go", region: "e2e")

That test uses real sockets, a real temporary file and real retries, so it
also runs under `-race`. Usage errors and the interrupted path (exit 130) get
their own small tests. The two-stage signal handling is tested by sending a
real signal to the test process. It uses `SIGUSR1`, because a `SIGINT` would
reach `go test` itself:

#src("pkg/lifecycle/lifecycle_test.go", region: "test")

#output("test-all.txt", cmd: "go test -race ./...")

== Diagnosing concurrency in production <sec-diagnosing>

Tests catch most problems. The rest show up at 3 a.m. as a process that is
alive but stuck, or a memory graph that only goes up. Go gives you four tools
for those nights.

*Goroutine dumps.* Send `SIGQUIT` (`kill -QUIT <pid>`, or #kbd("Ctrl-\\") in a
terminal) and the runtime prints every goroutine's stack and exits.
`GOTRACEBACK=all` (or `system`, `crash`) controls how much detail appears.
Since Go 1.27, tracebacks include the goroutine's `runtime/pprof` labels in the
header line, so tag goroutines with labels such as the target or the request
ID and the dump shows which goroutine was doing what. A dump with 4,000
goroutines all parked on the same line is the classic signature of a leak.

*The goroutine profile.* In daemons, expose `net/http/pprof` on a localhost-only
admin port, never on the public listener, and fetch
`/debug/pprof/goroutine?debug=2` without killing the process. It aggregates
identical stacks, so you see the count for each blocked line.

*The goroutine leak profile.* Go 1.26 introduced a `goroutineleak` profile as
an experiment, and Go 1.27 made it generally available in `runtime/pprof` and
as `/debug/pprof/goroutineleak`. It uses the garbage collector to find
goroutines blocked on a channel, mutex or condition variable that is no longer
reachable from any goroutine that could unblock it. Those goroutines are
provably stuck forever. Running the leaky example from @sec-ownership shows it
pinpointing the bug:

#output("leak.txt", cmd: "go run ./examples/ch04/leak")

The profile reports three leaked goroutines, all at `main.go:20`: the send
inside the closure, after `checkAll` returned on the first error. The
detection relies on reachability, so leaks through channels held in global
variables or by runnable goroutines can escape it. It still catches a large
and common class of bugs with no false positives, which is exactly what you
want from a profile you check during an incident.

*The execution trace flight recorder.* Some problems are about _timing_:
a reconcile loop that stalls for two seconds once an hour, or GC pauses that
line up with timeouts. `runtime/trace.FlightRecorder` (Go 1.25) keeps the
last few seconds of execution trace in a ring buffer at low overhead, and
`WriteTo` snapshots it when your code notices something wrong, for instance a
request that exceeded its latency SLO. You get a trace of the moments _before_
the anomaly, which is what you need. Chapter 30 uses it alongside CPU and
heap profiles and PGO.

For dashboards, `runtime/metrics` exposes scheduler metrics (Go 1.26 added
counts of goroutines by state under `/sched/goroutines`, OS thread counts, and
total goroutines created). Chapter 17 wires them into OpenTelemetry and
Prometheus alongside the application's own metrics.

#takeaways(
  [Goroutines are cheap; what they hold is not. Bound concurrency according to what the _downstream_ tolerates, and make the bound a flag.],
  [Rule zero: a function that starts goroutines doesn't return until they finish. `WaitGroup.Go`, `errgroup`, and iterators that wait before returning make this easy to keep.],
  [Contexts form a tree. Derive, don't replace; always call `cancel`; use causes so users and exit codes can tell #kbd("Ctrl-C") from a deadline from a slow target.],
  [Pick failure semantics deliberately: fail-fast (`conc.Map`) when one error invalidates the result, collect-all (`conc.Stream`) when failures are data.],
  [Retries need classification, exponential backoff with full jitter, a cap, a total deadline, `Retry-After`, and a shared rate budget. Anything less can amplify an outage.],
  [Shared lookups via singleflight must not inherit one caller's cancellation: detach with `WithoutCancel`, bound with a timeout, and let callers wait on their own contexts.],
  [Graceful shutdown has two stages: the first signal cancels and reports, the second exits immediately with status 130.],
  [`-race`, goleak and `testing/synctest` (plus Go 1.27's `httptest.NewTestServer`) make concurrent tests fast and deterministic. The `goroutineleak` profile finds what tests miss.],
)

#exercises(
  [*Ordered streaming.* Add `--ordered` to `sweep` so that `jsonl` output is in input order while still streaming. Implement a reorder buffer that emits result _i_ as soon as results 0 to _i_ have arrived, and bound its memory. What happens to the buffer if target 0 is the slowest? Write a `synctest` test that proves the bound holds.],
  [*Adaptive concurrency.* Replace the fixed per-host limit with an AIMD limiter (additive increase, multiplicative decrease, the TCP congestion-control rule): raise a host's limit by one after each success, and halve it on a timeout or 503. Compare total sweep time against fixed limits using a fake fleet in a `synctest` bubble.],
  [*A deploy gate.* Add `--require` flags (for example `--require 'up>=99%'` and `--require 'p95<800ms'`) that set the exit status from aggregate thresholds instead of "any target down". This is the health gate that the `ship` CLI in Chapter 23 calls between promotion stages.],
  [*Retry budget.* Implement a retry budget in `pkg/retry`: a token bucket shared by all callers that permits retries only up to 10% of recent first attempts. Show with a `synctest` simulation of 500 failing targets that the total attempt count stays bounded.],
  [*Find the leak.* Introduce a deliberate bug into `conc.Stream` (remove the `consumerGone` case from the worker's `select`). Which test catches it, and how? Then compile the leak example with Go 1.26 and Go 1.27 and compare what you need to do to get the `goroutineleak` profile.],
)
