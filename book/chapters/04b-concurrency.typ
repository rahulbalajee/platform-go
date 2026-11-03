#import "../template/book.typ": *
#import "04-lib.typ": ts, needspace

#step(3, 7, "Bounded and streaming", label: <sec-stream>)

Step 2 starts a goroutine for every target at once. With five targets that is
fine. With 5,000 it means 5,000 simultaneous connections: you run out of file
descriptors (`ulimit -n` is often 1024 in containers), exhaust ephemeral
ports, and trip the rate limiter or WAF in front of the targets. The tool
meant to detect an outage can cause one. Step 2 also leaks every goroutine
that hasn't sent its result when the caller stops reading. This step fixes
both, and moves the concurrency into a small package that later chapters
reuse.

=== Bounded parallelism, three ways <sec-bounded>

Bounding concurrency means letting at most _N_ checks run at once while the
rest wait their turn. There are three standard shapes, and each one is right
somewhere.

*The worker pool.* A fixed set of _N_ long-lived workers pull jobs from a
channel. It is the oldest pattern and still the best when each worker holds
expensive state: a database connection, a gRPC stream, an authenticated SDK
client.

#code(file: "pool.go")[```go
func pool(ctx context.Context, targets []Target, n int) <-chan Result {
	jobs := make(chan Target)
	results := make(chan Result)
	go func() { // producer: the only sender on jobs, so it closes jobs
		defer close(jobs)
		for _, t := range targets {
			select {
			case jobs <- t:
			case <-ctx.Done():
				return
			}
		}
	}()
	var wg sync.WaitGroup
	for range n {
		wg.Go(func() {
			for t := range jobs { // ends when the producer closes jobs
				results <- check(ctx, t)
			}
		})
	}
	go func() { wg.Wait(); close(results) }() // the workers send on results
	return results
}
```]

The producer closes `jobs` because it is that channel's only sender, and a
separate goroutine closes `results` after every worker has returned. Like
step 2, it returns a channel, so it leaks when the caller stops reading.

*The semaphore.* One goroutine per item, with a buffered channel as a counting
semaphore, so at most _N_ run at once. Goroutines are cheap; what you limit is
how many are _active_.

#code(file: "semaphore.go")[```go
sem := make(chan struct{}, n)
var wg sync.WaitGroup
for _, t := range targets {
	select {
	case sem <- struct{}{}: // acquire a slot (blocks while n are active)
	case <-ctx.Done():
	}
	if ctx.Err() != nil {
		break
	}
	wg.Go(func() {
		defer func() { <-sem }() // release
		record(check(ctx, t))
	})
}
wg.Wait()
```]

Acquiring _before_ `go` matters: the loop itself blocks, so it can't race ahead
and create 5,000 parked goroutines. That is _backpressure_. For weighted
limits, such as "at most 2 GiB of downloads in flight", use
`golang.org/x/sync/semaphore`, whose `Acquire(ctx, n)` also takes a context.

*errgroup.* `golang.org/x/sync/errgroup` packages the semaphore with error
handling. `SetLimit(n)` bounds concurrency, `Go` blocks until a slot is free,
`WithContext` cancels the group's context on the first error, and `Wait`
returns that first error. It is the right default when one failure should
abort everything.

#table(
  columns: (auto, 1fr, 1fr),
  table.header([Shape], [Use when], [Watch out for]),
  [Worker pool], [Workers hold expensive state, or you want a fixed, long-lived set of goroutines], [Who closes which channel; a consumer that stops reading blocks every worker],
  [Semaphore], [One goroutine per item with a cap; you need context-aware waiting or weighted limits], [Acquire before `go`, not inside it, or you lose backpressure],
  [errgroup], [The first error should cancel the rest and be returned], [`Go` blocks _without_ watching the context],
)

`sweep` needs two of these. Package `conc` gets one function per failure
model: `Map` for "all results or an error", built on errgroup, and `Stream`
for "every result as soon as it is ready", built on a semaphore.

#goconcept(title: [Generics])[
  A function can take _type parameters_ in square brackets:
  `func Map[T, R any](items []T, fn func(T) R) []R`. `T` and `R` stand for
  whatever types the caller uses, and the compiler usually infers them, so a
  call reads `Map(ports, label)`. `any` is a _constraint_ that allows every
  type; `cmp.Ordered` allows types with `<`. Generics fit containers and
  algorithms that work the same way for any element type, such as the
  helpers in this step. Java and TypeScript generics look similar; unlike
  Java, Go generates code per shape of type, so there is no boxing. Don't
  reach for type parameters when an interface (step 4) says what you mean.
]

#goconcept(title: [Iterators and range over func])[
  Since Go 1.23, `for x := range seq` works on a function `seq` of type
  `iter.Seq[T]`, which is `func(yield func(T) bool)`. The function calls
  `yield` once per value; `yield` runs the loop body and returns `false` if the
  body executed `break` or `return`, at which point the iterator must stop and
  return. `slices.Values(s)` turns a slice into an `iter.Seq`. The iterator
  runs its own cleanup before the loop statement finishes, which is why it
  is a good home for goroutines: they can be shut down before the caller's
  next line runs. Python generators are the closest relative; the difference
  is that the iterator, not the caller, owns the loop.
]

=== Package `conc`

Create `conc/conc.go`. It starts with a package comment that states the
contract every helper keeps:

#src("workbook/ch04/step3/conc/conc.go", region: "head")

`Map` is the fail-fast helper:

#src("workbook/ch04/step3/conc/conc.go", region: "map")

Results are written by index into a slice allocated up front, so no mutex is
needed: each goroutine owns exactly one element, and `g.Wait` makes the writes
visible to the caller. The loop checks `ctx.Err()` before each `Go`, so after
a failure no new work starts. Later projects use `Map` to fetch state from
every cluster or every cloud account, where one missing answer makes the whole
result useless. `max(limit, 1)` guards against a limit of zero: the
troubleshooting table below shows what `SetLimit(0)` does.

`Stream` is the one `sweep` uses. Add it to the same file:

#src("workbook/ch04/step3/conc/conc.go", region: "stream")

All the concurrency hides behind `iter.Seq[R]`, and rule zero holds at the
loop boundary: when the caller's loop ends, by running out of results or by
`break`, every goroutine `Stream` started has exited. It is short, but each
decision is deliberate.

*Only one goroutine calls `yield`.* `yield` runs the caller's loop body, so it
is only ever called from the `for r := range results` loop inside the
iterator, never from a worker. Calling it from several goroutines would run
the caller's loop body concurrently, a data race the caller never agreed to.
Calling it again after it returned `false` makes the runtime panic; the
checkpoint shows that panic.

*Two different "stop" signals.* If the _consumer_ breaks out of the loop,
nobody will read another result, so workers must drop theirs
(`consumerGone`) and in-flight calls are cancelled. If the _parent context_ is
cancelled (#kbd("Ctrl-C")), the consumer is still listening and wants to know
what happened to every check that had started. Workers deliver those
results, which `sweep` reports as `cancelled`, and the producer stops starting
new ones. Mixing the two signals into one `ctx.Done()`, as an earlier draft of
this function did, makes partial reports random: `select` picks among ready
cases at random, so some cancelled results arrive and some vanish.

*An unbuffered results channel is backpressure.* If the consumer is slow (say
it writes to a pipe that `jq` reads slowly), workers block on send, their
slots stay taken, and the producer stops launching work. Memory stays bounded
by `limit` however many targets there are. A buffer would smooth bursts, but
it only delays the backpressure.

*A context-aware semaphore, not `errgroup.SetLimit`.* `errgroup.Group.Go`
blocks while the group is full, and it does not watch any context while it
waits. If cancellation happens while the producer is blocked inside `g.Go`,
the call returns when a slot frees up and launches one more task with an
already-cancelled context. The `select` on `sem` and `ctx.Done()` makes the
producer stop the moment the context is done.

#warning(title: [Iterators and blocking inputs])[
  `Stream` reads its input sequence on the producer goroutine. If that
  sequence blocks forever, for example a reader on a terminal that never sends
  EOF, an early `break` can't complete, because the producer is stuck inside
  the input iterator and never closes `results`. Inputs to concurrent
  iterators must be finite or must honour a context themselves. `sweep` parses
  its whole inventory into a slice first, which also gives it the target count
  it needs for the summary.
]

=== Tests for `conc`

Add the dependency, then create `conc/conc_test.go`. goleak guards this
package too:

#session(
  ("go get golang.org/x/sync@v0.24.0", "ch04/s3-goget.txt"),
  ("go mod tidy", "ch04/s3-tidy.txt"),
)
#src("workbook/ch04/step3/conc/conc_test.go", region: "head")

The `Map` tests check order, the limit, and that one failure cancels its
siblings. `time.Sleep` inside a bubble costs no real time, so the test can use
whole seconds and still finish at once:

#src("workbook/ch04/step3/conc/conc_test.go", region: "map")

The `Stream` tests pin down the three behaviours described above: results in
completion order, an early `break` that leaves nothing running, and a
cancelled parent that still reports every call that had started:

#src("workbook/ch04/step3/conc/conc_test.go", region: "stream")

=== The runner on top of `Stream`

`Run` becomes one line. Replace the imports at the top of `runner.go`:

#src("workbook/ch04/step3/internal/sweep/runner.go", region: "imports")

Then replace `Config`, `Runner` and `NewRunner` with a version that has a
concurrency limit and reports every invalid setting at once:

#src("workbook/ch04/step3/internal/sweep/runner.go", region: "config")

`errors.Join` (Go 1.20) builds one error out of several, and `errors.Is` sees
every one of them. A user who passes `-c 0 -timeout 0s` learns about both
mistakes in one run, the same courtesy `ParseTargets` extends to inventory
files. `errors.Join` of no errors is `nil`, which is what makes the `if`
work. Now replace `Run`:

#src("workbook/ch04/step3/internal/sweep/runner.go", region: "run")

`r.check` already has the shape `Stream` wants, `func(context.Context, Target) Result`, so the method value is passed directly. The `sync` import is
gone, and so is every channel `Run` used to manage.

`main.go` gets a `-c` flag. Replace `options` and `parseFlags`:

#src("workbook/ch04/step3/cmd/sweep/main.go", region: "flags")

and `newRunner`:

#src("workbook/ch04/step3/cmd/sweep/main.go", region: "newrunner")

`run` doesn't change: `for res := range runner.Run(ctx, targets)` ranges over
an `iter.Seq` exactly as it ranged over a channel. Add a case to the
usage-error test in `cmd/sweep/main_test.go`:

#src("workbook/ch04/step3/cmd/sweep/main_test.go", region: "usage")

In `runner_test.go`, `newRunner` needs a default concurrency for the tests
that don't set one:

#src("workbook/ch04/step3/internal/sweep/runner_test.go", region: "helpers")

The cancellation test now proves that the producer stops: with a limit of 2,
only two checks ever start before #kbd("Ctrl-C"), so only two results come
back. Replace it, and replace `TestRunnerChecksConcurrently` with a test of
the limit:

#src("workbook/ch04/step3/internal/sweep/runner_test.go", region: "cancel")
#src("workbook/ch04/step3/internal/sweep/runner_test.go", region: "limit")

=== Fail-fast or collect-all <sec-failures>

`Map` and `Stream` encode two answers to the question "what does an error
mean?" Getting this right is a product decision, and it is where many
platform tools go wrong.

#table(
  columns: (auto, 1fr, 1fr),
  table.header([], [Fail-fast (`Map`)], [Collect-all (`Stream`)]),
  [An error is], [a reason the _operation_ can't produce a useful answer], [_data_ about one item, to be reported],
  [On first error], [cancel siblings, return the error], [keep going; record the failure in that item's result],
  [Typical use], [load config from every cluster before computing a diff; apply a change to N accounts as a unit], [health checks, inventory scans, compliance audits, bulk reads],
  [Output], [`([]R, error)` in input order], [a stream of results in completion order],
)

In `sweep`, an unhealthy target is a _domain_ outcome. It belongs in the
report, and it decides the exit status. An _infrastructure_ error is
different: an unparseable inventory, a closed stdout pipe, an invalid flag. It
means the tool can't do its job and should stop. Keep the two apart in your
types. The checker's signature, `func(context.Context, Target) Result`, has no
`error` return at all, which makes them impossible to confuse.

#tip(title: [Choosing N])[
  For I/O-bound work, _N_ is a statement about the _target_, not your CPU
  count. Start from what the downstream system tolerates (its rate limits,
  connection limits, and how many replicas serve it) and make _N_ a flag with
  a conservative default. For CPU-bound work, _N_ near `GOMAXPROCS` is the
  ceiling; more only adds scheduling overhead (@sec-scheduler). Mixed
  workloads are best split into stages with separate limits.
]

#needspace(12em)
#checkpoint(step: 3, of: 7, title: [Bounded and streaming])[
  #output("ch04/s3-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch04/s3-test.txt", cmd: "go vet ./... && go test ./...")
  Make an inventory of eight slow targets and sweep it four at a time, with a
  one-second timeout:
  #session(
    ("for i in 1 2 3 4 5 6 7 8; do echo \"http://127.0.0.1:8099/slow?$i\"; done > many.txt", none),
    ("go run ./cmd/sweep -c 4 -timeout 1s many.txt", "ch04/s3-c4.txt"),
  )
  Two rounds of one second each. The fleet's log shows the rounds: four
  requests arrive together, then four more a second later.
  #output("ch04/s3-fleet.txt", cmd: "go run ./cmd/fleet", title: "terminal 2")
  With `-c 8` all eight run at once, and the sweep takes one second:
  #output("ch04/s3-c8.txt", cmd: "go run ./cmd/sweep -c 8 -timeout 1s many.txt 2>&1 | tail -2")
  Invalid settings are reported together:
  #output("ch04/s3-limits.txt", cmd: "go run ./cmd/sweep -c 0 -timeout 0s fleet.txt")
  #troubleshoot(
    ([#ts("s3-yield.txt")], [The iterator kept calling `yield` after it returned `false`: the `break` after `cancel()` is missing.], [Stop iterating as soon as `yield` returns `false`.]),
    ([#ts("s3-nodone.txt")], [`Stream` returned before its goroutines exited: `<-done` is missing.], [Wait for the producer before returning. See "Rule zero".]),
    ([#ts("s3-generic.txt")], [A `Map` call whose function doesn't fit the items: `T` was inferred as `string` from the slice, but `label` takes an `int`.], [Make the slice and the function agree; read "inferred type" as "what the compiler worked out from the other argument".]),
    ([#ts("s3-zero.txt")], [`g.SetLimit(0)` lets no goroutine start, so the first `g.Go` blocks forever.], [Clamp limits: `max(limit, 1)`. Validate flags in `NewRunner`.]),
  )
]

#step(4, 7, "One interface, four probers", label: <sec-probers>)

A fleet is more than HTTP endpoints. Databases and brokers answer on TCP
ports, public hostnames have TLS certificates that expire, and everything
depends on DNS. This step adds three more kinds of target. The runner learns
nothing about any of them: it talks to a one-method interface, and each
protocol lives behind it.

#goconcept(title: [Interfaces])[
  An interface type lists methods: `type Prober interface { Probe(ctx, t) (string, error) }`. Any type with those methods satisfies it automatically;
  there is no `implements` keyword, unlike Java or C\#. Code that accepts a
  `Prober` works with every prober, including fakes in tests. Keep interfaces
  small (one or two methods is normal) and define them where they are _used_,
  not next to an implementation. One rule catches newcomers: if a method has
  a pointer receiver, `func (p *TCPProber) Probe`, only `*TCPProber`
  satisfies the interface, not `TCPProber`. The troubleshooting table shows
  the compiler's message.
]

#goconcept(title: [Function types and adapters])[
  Functions are values with types, and a named function type can have
  methods. `type ProberFunc func(ctx, t) (string, error)` with a `Probe` method
  that calls the function itself turns any function of the right shape into a
  `Prober`: `ProberFunc(func(...) (string, error) { ... })`. This is the
  _adapter_ pattern, and the standard library uses it for
  `http.HandlerFunc`. It saves declaring a type for a one-off behaviour, which
  is what tests want most of the time.
]

=== Target kinds

Replace the head of `target.go`, from the package comment through `Kind`.
The package comment now says what the package really does:

#src("workbook/ch04/step4/internal/sweep/target.go", region: "head")

`parseTarget` accepts the new schemes. Replace it:

#src("workbook/ch04/step4/internal/sweep/target.go", region: "parse1")

TCP and TLS targets need a port, because "connect to `db.internal`" is
meaningless without one. DNS targets need only a name.

=== The probers

`probe.go` grows from one prober to four. Replace the import block, and add
the interface and its adapter above `HTTPProber`, which stays as it was:

#src("workbook/ch04/step4/internal/sweep/probe.go", region: "imports")
#src("workbook/ch04/step4/internal/sweep/probe.go", region: "prober")

A TCP check succeeds if a connection can be opened. Add it after
`HTTPProber`:

#src("workbook/ch04/step4/internal/sweep/probe.go", region: "tcp")

The prober doesn't dial by itself; it calls the `Dial` function it was given.
That one field lets `main` plug in a caching resolver, and lets tests plug in
anything. A TLS check goes further: it completes a handshake and fails if the
certificate expires within `MinValidity`. Expiring certificates are the most
common self-inflicted outage this tool can catch early:

#src("workbook/ch04/step4/internal/sweep/probe.go", region: "tlstype")
#src("workbook/ch04/step4/internal/sweep/probe.go", region: "tlsprobe")

`Now` is there for tests, which need "ten days before expiry" without waiting
for it. `Config` is cloned before `ServerName` is set, because the caller's
`*tls.Config` may be shared with other goroutines. A DNS check resolves a
name, and a small helper formats durations as days:

#src("workbook/ch04/step4/internal/sweep/probe.go", region: "dnstype")
#src("workbook/ch04/step4/internal/sweep/probe.go", region: "dnsprobe")
#src("workbook/ch04/step4/internal/sweep/probe.go", region: "humandays")

=== The runner picks a prober

`Config` replaces its `HTTP` field with a map from kind to prober. Replace the
`Config` type:

#src("workbook/ch04/step4/internal/sweep/runner.go", region: "cfgtype")

and `check`, which looks the prober up and reports a target as down if
nothing can check it:

#src("workbook/ch04/step4/internal/sweep/runner.go", region: "check")

=== Sharing DNS lookups <sec-singleflight>

HTTP, TCP and TLS targets all start with a DNS lookup. A sweep of 500 URLs on
20 hostnames resolves names 500 times unless you do something about it, and
the lookups for one hostname all happen in the same few milliseconds, because
the checks start together. Two tools solve this together: a small cache with
a time to live (TTL), and `golang.org/x/sync/singleflight`, which merges
concurrent calls with the same key into one execution whose result every
caller shares.

The cache is a map that many goroutines read and write, so it needs a lock.

#goconcept(title: [Mutexes and `sync/atomic`])[
  A `sync.Mutex` protects data that several goroutines touch. `mu.Lock()`
  waits until no other goroutine holds the lock; `defer mu.Unlock()` releases
  it when the function returns. Everything that reads or writes the guarded
  data must hold the lock, and the zero value is an unlocked mutex, ready to
  use. Keep critical sections tiny, and never block on I/O or a channel while
  holding one. For a lone counter or flag, the typed atomics in `sync/atomic`
  are simpler and faster: `var n atomic.Int64; n.Add(1); n.Load()`. The fake
  fleet counts `/flaky` calls that way. A Go map is _not_ safe for concurrent
  use; the race detector reports it, and the runtime may crash with
  `concurrent map writes`.
]

Create `internal/sweep/resolver.go`:

#src("workbook/ch04/step4/internal/sweep/resolver.go", region: "head")

`group`, `mu` and `cache` are unexported, and their zero values work, so a
`CachingResolver` is ready as soon as its exported fields are set. The lookup
is where it gets interesting:

#src("workbook/ch04/step4/internal/sweep/resolver.go", region: "lookup")

The naive version passes the caller's `ctx` into the shared function. That
couples everyone to the _first_ caller's context: if that check has 100 ms
left and gives up, the shared lookup is cancelled, and 40 other callers with
plenty of time all fail with "context canceled" for a host that was fine.
The fix has three parts. The shared work runs on
`context.WithoutCancel(ctx)` (step 2), so it is detached from any single
caller but keeps request-scoped values such as trace IDs. It gets its own
timeout, because detached work without a bound is a leak. And callers wait
with `DoChan` and a `select` on their _own_ `ctx.Done()`, so each one gives up
on its own schedule while the lookup carries on for the others.

The cache itself is two small methods that hold the lock only while they touch
the map:

#src("workbook/ch04/step4/internal/sweep/resolver.go", region: "cache")

`store` creates the map on first use, because writing to a nil map panics.
Finally, a dial function with the signature `http.Transport.DialContext`
expects:

#src("workbook/ch04/step4/internal/sweep/resolver.go", region: "dial")

#internals(title: [`singleflight` is not a cache])[
  `singleflight` only merges calls that overlap in time. The moment the shared
  call returns, the key is forgotten, and the next caller triggers a fresh
  execution. That is why the resolver pairs it with a TTL cache. The reverse
  holds too: a cache without singleflight suffers a _thundering herd_ whenever
  an entry expires under load, as every concurrent miss goes to the backend at
  once. Use both whenever an expensive lookup sits on a hot path.
  `Group.Forget(key)` evicts an in-flight key early, for example when you know
  its result is already stale.
]

=== Wiring

`main.go` builds one prober per kind. Replace the head of the file, which
adds `net` to the imports and the new schemes to the package comment:

#src("workbook/ch04/step4/cmd/sweep/main.go", region: "head")

Add the certificate threshold to the flags:

#src("workbook/ch04/step4/cmd/sweep/main.go", region: "flags")

`newRunner` hands the map to the runner:

#src("workbook/ch04/step4/cmd/sweep/main.go", region: "newrunner")

and a new function at the end of the file builds it:

#src("workbook/ch04/step4/cmd/sweep/main.go", region: "probers")

The HTTP client sets no `Client.Timeout`; deadlines come from the context. The
transport is cloned from `http.DefaultTransport`, which keeps its defaults
(proxy settings from the environment, HTTP/2, idle timeouts), and gets the
caching dialer. HTTP, TCP and TLS share one resolver. The DNS prober
deliberately does _not_ use it: the point of a DNS check is to exercise
resolution itself.

=== Tests

In `runner_test.go`, `newRunner` builds the map, and the parser test expects
the new error for a TCP target without a port:

#src("workbook/ch04/step4/internal/sweep/runner_test.go", region: "helpers")
#src("workbook/ch04/step4/internal/sweep/runner_test.go", region: "parse")

The probers get their own file, `internal/sweep/probe_test.go`. It starts
with a helper that parses one inventory line:

#src("workbook/ch04/step4/internal/sweep/probe_test.go", region: "head")
#src("workbook/ch04/step4/internal/sweep/probe_test.go", region: "parse1")

The TCP test opens a real listener, checks it, closes it, and checks again.
`errors.Is` finds `syscall.ECONNREFUSED` inside the dial error's wrapping:

#src("workbook/ch04/step4/internal/sweep/probe_test.go", region: "tcp")

The TLS test uses `httptest.NewTLSServer`, which comes with its own
certificate, and moves the clock with `Now` instead of waiting:

#src("workbook/ch04/step4/internal/sweep/probe_test.go", region: "tls")

The DNS test resolves `localhost`, the one name every machine can answer
without a network. The last test uses `ProberFunc` to fake two kinds and
leaves the third without a prober:

#src("workbook/ch04/step4/internal/sweep/probe_test.go", region: "dns")
#src("workbook/ch04/step4/internal/sweep/probe_test.go", region: "dispatch")

#needspace(12em)
#checkpoint(step: 4, of: 7, title: [One interface, four probers])[
  #output("ch04/s4-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch04/s4-test.txt", cmd: "go vet ./... && go test ./...")
  This inventory mixes the fleet with real hosts, so it needs network access:
  #output("ch04/s4-cat.txt", cmd: "cat mixed.txt")
  #output("ch04/s4-run.txt", cmd: "go run ./cmd/sweep mixed.txt", size: 6.8pt)
  Your addresses and certificate dates will differ. Port 9 (the old
  "discard" service) is closed on almost every machine. A typo in a scheme,
  or a TCP target without a port, is caught by the parser:
  #output("ch04/s4-typo.txt", cmd: "go run ./cmd/sweep typo.txt")
  #troubleshoot(
    ([#ts("s4-pointer.txt")], [`Probe` has a pointer receiver, so the value `TCPProber{...}` has no `Probe` method.], [Use a value receiver, or put `&TCPProber{...}` in the map.]),
    ([#ts("s4-signature.txt")], [The method's signature differs from the interface's; here `*Target` instead of `Target`.], [Match the interface exactly. The compiler shows _have_ and _want_.]),
    ([#ts("s4-nilmap.txt")], [`store` writes to a map that was never created.], [`make` the map before the first write, as `store` does.]),
  )
]

#step(5, 7, "Politeness and retries", label: <sec-limits>)

`-c 32` caps how many checks run at once across the whole sweep. It doesn't
stop all 32 from landing on the same host when 300 of the inventory's targets
live behind one ingress controller. And a single failed attempt makes a
target "down", although connection resets and 503s during a deploy are often
gone a second later. This step adds the three things that make `sweep` safe
to point at production: a per-host limit, a global rate limit, and retries
that don't make outages worse.

=== Per-host limits with a keyed semaphore

No more than `-per-host` concurrent checks against any single `host:port`,
however many targets it serves. This is politeness, and it also makes results
more trustworthy: forty simultaneous probes against one pod measure your own
load, not the service's health.

A map of semaphores, one per key, sounds like three lines of code. The details
are where it gets interesting. Create `conc/keyed.go`:

#src("workbook/ch04/step5/conc/keyed.go", region: "type")
#src("workbook/ch04/step5/conc/keyed.go", region: "acquire")
#src("workbook/ch04/step5/conc/keyed.go", region: "len")

- The map is guarded by a mutex, but waiting for a slot happens _outside_ the
  lock. Holding a mutex while blocking on a channel would serialize every key
  behind the slowest one.
- Each slot is reference-counted, and waiters count too. Without that, a key
  could be deleted while a goroutine waits on its channel. The next
  `Acquire` would create a fresh slot, and two goroutines would be running
  against a host that should allow one.
- Idle keys are deleted, so memory tracks active hosts rather than every host
  ever seen. In a long-running daemon (the monitoring agent in Chapter 25 uses
  the same type) that difference is a memory leak avoided.
- `release` is idempotent via `sync.Once`, because "release exactly once" is a
  rule humans break, usually in error paths.
- `Len` exists for tests and metrics. A `Len` that only grows means somebody
  lost a release function.

Add its tests to the end of `conc/conc_test.go`. `synctest.Wait` proves that
the third `Acquire` really _is_ waiting, without sleeping and hoping:

#src("workbook/ch04/step5/conc/conc_test.go", region: "keyed")

=== Retries that don't make outages worse <sec-retry>

Retries are the most dangerous few lines in a platform tool. Done naively
(immediately, at fixed intervals, without limit, for every error) they are
how one service's bad minute becomes everyone's bad hour. A production retry
policy answers five questions:

+ *Which failures are worth retrying?* Connection refused, resets, timeouts,
  HTTP 502, 503, 504 and 429 are usually transient. A 404, a 401, an invalid
  certificate, or a name that doesn't exist will not fix itself in 200
  milliseconds, so retrying them only wastes time and load.
+ *How long to wait?* Exponentially longer each time, capped.
+ *With how much randomness?* Enough that a thousand clients that failed
  together don't retry together.
+ *How many times, in total?* A fixed attempt budget, plus whatever overall
  deadline the context carries.
+ *Does the server have an opinion?* `Retry-After` on a 429 or 503 is the
  server telling you exactly how long to wait. Honour it.

The classic analysis of the third question is Marc Brooker's 2015 post on the
AWS Architecture Blog, "Exponential Backoff And Jitter". It simulated many
clients contending for one resource and compared strategies. The winner, for
both total work and completion time, was _full jitter_: compute the
exponential ceiling `min(cap, base × 2^attempt)`, then sleep a uniformly random
duration between zero and that ceiling. It looks wasteful, since some retries
fire almost at once, but it spreads clients evenly across the whole window,
and that is what a recovering server needs.

#goconcept(title: [`errors.Is`, `errors.As` and `errors.AsType`])[
  Errors are values, and code adds context by _wrapping_:
  `fmt.Errorf("dial %s: %w", addr, err)` keeps `err` inside, reachable through
  `Unwrap`. `errors.Is(err, target)` walks that chain looking for a value
  equal to `target`, such as `context.Canceled` or `syscall.ECONNREFUSED`.
  `errors.As(err, &p)` looks for a _type_ and stores the match in `p`. Go
  1.26 added the generic form, `p, ok := errors.AsType[*net.DNSError](err)`,
  which needs no variable declared in advance. Comparing with `==` misses
  wrapped errors; the `errorlint` linter flags it. A type with an `Unwrap`
  method takes part in the chain, which is how `retry.Permanent` marks an
  error without hiding it.
]

Create `retry/retry.go`. The package comment describes the strategy:

#src("workbook/ch04/step5/retry/retry.go", region: "head")

The policy's zero value is useful: three attempts, 100 ms base, 5 s cap,
everything retryable unless marked otherwise. Configuration that works when
left empty is a kindness to callers and a common Go idiom:

#src("workbook/ch04/step5/retry/retry.go", region: "policy")

The loop:

#src("workbook/ch04/step5/retry/retry.go", region: "do")

Two checks are easy to miss. `ctx.Err()` is tested right after a failed
attempt. When the run is cancelled, an in-flight request fails with a context
error that looks like a timeout; without the check, the loop would sleep and
"retry" a dead context, and the message would blame the target for something
the user did. And the sleep is a `select` on a timer and `ctx.Done()`, never a
bare `time.Sleep`: a tool that ignores #kbd("Ctrl-C") for five seconds of
backoff feels broken.

A version for operations that return a value:

#src("workbook/ch04/step5/retry/retry.go", region: "value")

#newingo("1.27", title: [Generic methods])[
  Go 1.27 lets methods declare their own type parameters. Before, a
  value-returning helper had to be a package-level function,
  `retry.DoValue[T](ctx, policy, op)`. Now it lives on the policy, and call
  sites infer `T`: `cfg, err := policy.Value(ctx, fetchConfig)`. Two limits
  remain. Interface methods still can't have type parameters, and a generic
  method can't satisfy an interface method, so keep generic methods for
  convenience APIs on concrete types.
]

The backoff and the classification:

#src("workbook/ch04/step5/retry/retry.go", region: "backoff")

The `//nolint:gosec` with a reason is the right way to silence a linter. gosec
flags every use of `math/rand`; here that is a false positive, because jitter
needs spread, not unpredictability. A suppression without a reason gets
deleted by the next person who doesn't understand it, or copied somewhere it
isn't safe.

Last, the error types. Operations classify their own failures with two small
wrappers:

#src("workbook/ch04/step5/retry/retry.go", region: "errors")

`Permanent` and `After` are _transparent_: `Error` returns the wrapped
message, and `Unwrap` exposes it to `errors.Is` and `errors.As`, so callers can
mark an error without changing what users see. `ExhaustedError` wraps the
last attempt's error, so a caller can still ask `errors.Is(err, syscall.ECONNREFUSED)` after three attempts.

=== Tests for `retry`

Create `retry/retry_test.go`. Backoff is random, so the first test asserts a
range: three sleeps with full jitter take more than zero and at most
1 + 2 + 4 seconds. In a bubble, that range is checked exactly and instantly:

#src("workbook/ch04/step5/retry/retry_test.go", region: "head")
#src("workbook/ch04/step5/retry/retry_test.go", region: "backoff")

Then classification and exhaustion:

#src("workbook/ch04/step5/retry/retry_test.go", region: "classify")

`Retry-After` must win over the computed backoff, and a context deadline must
win over everything:

#src("workbook/ch04/step5/retry/retry_test.go", region: "after")
#src("workbook/ch04/step5/retry/retry_test.go", region: "value")

=== Classifying failures in the probers

The probers decide what is permanent, because only they know the protocol.
Replace the imports of `probe.go` and the comment on `Prober`:

#src("workbook/ch04/step5/internal/sweep/probe.go", region: "imports")
#src("workbook/ch04/step5/internal/sweep/probe.go", region: "prober")

Replace `HTTPProber`, and add a parser for `Retry-After` after it:

#src("workbook/ch04/step5/internal/sweep/probe.go", region: "http")
#src("workbook/ch04/step5/internal/sweep/probe.go", region: "retryafter")

Read the `switch` as a policy table. Anything below 400 is healthy, so
redirects count (the client follows up to five). 429 and 503 are retryable and
honour `Retry-After`. Other 5xx are retryable. The remaining 4xx are
permanent. A request that can't even be built is permanent, and so is a
certificate that fails verification: an expired certificate won't renew
itself between attempts. `Retry-After` comes in two forms, a number of
seconds or an HTTP date, and the parser clamps huge values before
multiplying, because `time.Duration` overflows past about 292 years and a
negative delay would mean "retry now". Chapter 6 shows the fuzz test that
found that bug.

The TLS prober marks certificate failures and near-expiry as permanent:

#src("workbook/ch04/step5/internal/sweep/probe.go", region: "tlstype")
#src("workbook/ch04/step5/internal/sweep/probe.go", region: "tlsprobe")

and the DNS prober treats "no such host" as an answer, not a blip:

#src("workbook/ch04/step5/internal/sweep/probe.go", region: "dnsprobe")

=== The global rate limit

`golang.org/x/time/rate` implements a _token bucket_: tokens refill at _r_ per
second up to a burst size _b_, and each operation spends one. `Wait(ctx)`
blocks until a token is available or the context ends; if the context's
deadline would pass before a token arrives, it returns an error at once rather
than sleeping uselessly.

`sweep` calls `Wait` before _every attempt_, retries included. That is the
important part. Retries that bypass the rate limiter turn a partial outage
into a retry storm: every failing target retries at once, exactly when the
service is least able to cope. When retries spend from the same budget as
first attempts, the load the tool generates has a hard ceiling, however many
failures it sees. The burst is a tenth of the per-second rate (at least 1):
enough to start quickly, then settle to the steady rate. If your targets
publish a rate limit, set `-rate` below it, because other clients spend from
the same allowance.

=== The runner, in full

Fetch the rate limiter:

#session(
  ("go get golang.org/x/time@v0.16.0", "ch04/s5-goget.txt"),
  ("go mod tidy", "ch04/s5-tidy.txt"),
)

`runner.go` changes in most places. Replace the imports:

#src("workbook/ch04/step5/internal/sweep/runner.go", region: "imports")

`Result` gains an attempt count. Replace it:

#src("workbook/ch04/step5/internal/sweep/runner.go", region: "result")

Replace `Config`, `Runner` and `NewRunner`. The runner now owns a limiter and
a keyed semaphore, created once and shared by every check:

#src("workbook/ch04/step5/internal/sweep/runner.go", region: "config")

And `check`, from `errAttemptTimeout` to the end of the file:

#src("workbook/ch04/step5/internal/sweep/runner.go", region: "check")

The order of operations is _host slot, then retry loop, then a rate-limit
token per attempt_. Holding the host slot across retries keeps backoff sleeps
from letting another check sneak in against a host that is already
struggling. Taking the token per attempt keeps the global budget honest. The
attempt timeout uses `WithTimeoutCause` as in step 2, but the message is now
returned as the attempt's error, so the retry loop sees it and tries again.
If `limiter.Wait` fails, the context is done or its deadline is too near, so
there is nothing to retry: `retry.Permanent` stops the loop. And `rootMessage`
keeps reports to one line: "unhealthy status 503 (after 3 attempts)" instead
of the retry package's full wrapping.

=== Flags and output

In `main.go`, the package comment gains a word and the imports gain `retry`:

#src("workbook/ch04/step5/cmd/sweep/main.go", region: "head")

Add three flags, and reword `-timeout`, which is now per attempt:

#src("workbook/ch04/step5/cmd/sweep/main.go", region: "flags")

`printResult` shows the attempt count:

#src("workbook/ch04/step5/cmd/sweep/main.go", region: "print")

`newRunner` passes the new settings and a retry policy. The base delay is
200 ms and the cap 2 s, so three attempts finish well inside a CI job's
patience:

#src("workbook/ch04/step5/cmd/sweep/main.go", region: "newrunner")

Too many redirects won't fix themselves either:

#src("workbook/ch04/step5/cmd/sweep/main.go", region: "probers")

=== Tests

`runner_test.go` imports `retry`:

#src("workbook/ch04/step5/internal/sweep/runner_test.go", region: "imports")

`newRunner` defaults the per-host limit to the global one, so older tests keep
their meaning:

#src("workbook/ch04/step5/internal/sweep/runner_test.go", region: "helpers")

The outcome test now has a retry policy, and it checks the attempt counts:
`/flaky` comes up on its third try, `/slow` times out three times, and the
404 is tried once. The elapsed time is three two-second timeouts plus up to
300 ms of jittered backoff:

#src("workbook/ch04/step5/internal/sweep/runner_test.go", region: "outcomes")

Add a test for the per-host limit after the concurrency test, and one that
proves certificate errors aren't retried. That one uses a real TLS server
outside a bubble:

#src("workbook/ch04/step5/internal/sweep/runner_test.go", region: "perhost")
#src("workbook/ch04/step5/internal/sweep/runner_test.go", region: "cert")

In `probe_test.go`, the fake DNS failure is now retried, so its message gains
the attempt count, and the test sets `PerHost`:

#src("workbook/ch04/step5/internal/sweep/probe_test.go", region: "dispatch")

#production(title: [Retry budgets across a fleet])[
  Per-call retry limits don't bound _aggregate_ load. If a service with a
  hundred callers starts failing, each caller retrying three times turns 100
  QPS into 400 QPS against a service that is already struggling. Large
  platforms add a _retry budget_: a token bucket, often per client process,
  that allows retries only up to, say, 10% of recent successful requests.
  When the budget is empty, failures are returned at once. gRPC's
  `retryThrottling` service config implements this idea. For CLIs that run
  once and exit, the global rate limiter in this step is usually enough. For
  daemons and controllers, add a budget.
]

#interview(title: [“Design a retry policy for calling a flaky internal API.”])[
  Walk through the five questions in order: classify errors (retry transient
  failures, never 4xx or validation errors), back off exponentially with full
  jitter and a cap, bound attempts _and_ total time with a context deadline,
  honour `Retry-After`, and retry only idempotent operations, or make them
  idempotent with request IDs. Then talk about the fleet: retry budgets or
  circuit breakers so retries can't amplify an outage, and metrics on attempt
  counts so you can see when retries quietly hide a degrading dependency.
  Chapter 15 builds the circuit breaker.
]

#needspace(12em)
#checkpoint(step: 5, of: 7, title: [Politeness and retries])[
  #output("ch04/s5-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch04/s5-test.txt", cmd: "go vet ./... && go test ./...")
  Restart the fleet, so `/flaky` starts its cycle from the beginning, and
  sweep the paths that exercise retries:
  #output("ch04/s5-cat.txt", cmd: "cat retry.txt")
  #output("ch04/s5-run.txt", cmd: "go run ./cmd/sweep -timeout 1s retry.txt", size: 6.6pt)
  Read the attempt counts against the rules: `/flaky` needed three tries,
  the 404 one, and everything transient used all three. In the fleet's log,
  `/busy` was retried exactly one second apart, as its `Retry-After: 1`
  asked, while `/flaky`'s retries came after short, random delays:
  #output("ch04/s5-fleet.txt", cmd: "go run ./cmd/fleet", title: "terminal 2 (busy and flaky only)")
  #troubleshoot(
    ([#ts("s5-defaults.txt")], [`Do` skipped `withDefaults`, so a zero `MaxDelay` reached `rand.N`, which panics on 0.], [Apply defaults first; zero values must work.]),
    ([#ts("s5-permanent.txt")], [A 4xx was returned without `retry.Permanent`, so the 404 was retried.], [Wrap non-transient failures in `retry.Permanent`.]),
    ([#ts("s5-errorlint.txt")], [Comparing errors with `==`. It works today and breaks as soon as anyone wraps the error.], [`errors.Is(context.Cause(actx), errAttemptTimeout)`.]),
    ([#ts("s5-gosec.txt")], [The `//nolint:gosec` comment is missing, so gosec objects to `math/rand`.], [Keep the comment, with its reason, on the line above.]),
  )
]
