#import "../template/book.typ": *

== Streaming results behind an iterator <sec-stream>

`conc.Map` waits for everything and returns a slice. A fleet checker wants
the opposite: print each result the moment it is ready, keep memory flat no
matter how many targets there are, and let the caller stop early. Since
Go 1.23, range-over-func iterators give that a natural shape. The caller
writes an ordinary loop:

#code(file: "caller.go")[```go
for res := range conc.Stream(ctx, slices.Values(targets), 32, check) {
	report(res)
	if res.Fatal {
		break // stops in-flight work; no goroutine outlives the loop
	}
}
```]

All the concurrency is hidden behind `iter.Seq[R]`, and rule zero holds at the
loop boundary: when the loop ends, by exhaustion or by `break`, every
goroutine `Stream` started has exited. Here is the implementation:

#src("pkg/conc/conc.go", region: "stream")

It is short, but each decision is deliberate.

*Only one goroutine calls `yield`.* `yield` runs the caller's loop body, so
it is only ever called from the `for r := range results` loop inside the
iterator function, never from a worker. Calling it from several goroutines at
once would run the caller's loop body concurrently, a data race the caller
never agreed to. Calling it again after it has returned `false` makes the
runtime panic. Workers hand their results over a channel, and a single
goroutine does the yielding.

*Two different "stop" signals.* There are two reasons to stop, and they need
different behaviour. If the _consumer_ breaks out of the loop,
nobody will read another result, so workers must drop theirs (`consumerGone`)
and in-flight calls should be cancelled. If the _parent context_ is cancelled
(the user pressed #kbd("Ctrl-C")), the consumer is still listening and wants to
know what happened to every check that had already started. Workers deliver
those results, which `sweep` reports as `cancelled`, and the producer simply
stops starting new ones. Mixing the two signals into one `ctx.Done()`, as an
earlier draft of this function did, makes partial reports nondeterministic:
`select` picks randomly among ready cases, so some cancelled results arrive
and some vanish.

*An unbuffered results channel is backpressure.* If the consumer is slow (say
it is writing to a pipe that `jq` reads slowly), workers block on send, slots
stay occupied, and the producer stops launching new work. Memory stays bounded
by `limit` no matter how many targets there are. A buffered channel is a
legitimate optimization to smooth bursts, but it only delays the backpressure.
It doesn't remove the need for it.

*A context-aware semaphore, not `errgroup.SetLimit`.* This is the bug that the
first version of `Stream` shipped with, and it's worth understanding.
`errgroup.Group.Go` blocks while the group is at its limit, and it does not
watch any context while it waits. If cancellation happens while the producer
is blocked inside `g.Go`, the call returns as soon as a slot frees, and then
launches one more task with an already-cancelled context. It usually does no
harm, because the task returns immediately, but it means "cancelled" doesn't
quite mean "no new work". The `select` on `sem <- struct{}{}` and
`ctx.Done()` makes the producer stop the moment the context is done. A test in
`pkg/conc` pins this behaviour: after cancellation at 1.5 seconds, exactly the
four calls that had started are reported and nothing else starts.

#warning(title: [Iterators and blocking inputs])[
  `Stream` consumes its input sequence on the producer goroutine. If that
  sequence blocks forever, for example a reader on a terminal that never sends
  EOF, an early `break` cannot complete, because the producer is stuck inside
  the input iterator and never closes `results`. Inputs to concurrent
  iterators must be finite or must themselves honour a context. `sweep` parses
  its whole inventory into a slice first, which also gives it the target count
  it needs for the summary.
]

== Failure semantics: fail-fast or collect-all <sec-failures>

`conc.Map` and `conc.Stream` encode two different answers to the question
"what does an error mean?" Getting this right is a product decision, and it is
where many platform tools go wrong.

#table(
  columns: (auto, 1fr, 1fr),
  table.header([], [Fail-fast (`Map`)], [Collect-all (`Stream`)]),
  [An error is], [a reason the _operation_ cannot produce a useful answer], [_data_ about one item, to be reported],
  [On first error], [cancel siblings, return the error], [keep going; record the failure in that item's result],
  [Typical use], [load config from every cluster before computing a diff; apply a change to N accounts transactionally], [health checks, inventory scans, compliance audits, bulk reads],
  [Output], [`([]R, error)` in input order], [a stream of results in completion order],
)

In `sweep`, an unhealthy target is a _domain_ outcome. It belongs in the
report, and it decides the exit code. An _infrastructure_ error is different:
an unparseable inventory, a closed stdout pipe, an invalid flag. It means the
tool can't do its job and should stop. Keep the two apart in your types. In
`sweep` the checker's signature is `func(context.Context, Target) Result`,
with no `error` return at all, and that makes it impossible to confuse them.

When you do need to report several errors from one operation, `errors.Join`
(Go 1.20) builds an error that wraps all of them. `errors.Is` and `errors.As`
search every branch. `sweep.NewRunner` uses it to report every invalid setting
at once rather than making the user fix them one per run:

#src("internal/sweep/runner.go", region: "config")

The same idea appears in `ParseTargets`, which collects syntax errors from the
whole inventory with their line numbers. A user fixing a 400-line inventory
file should get one error report, not 17 runs.

== Being a good citizen: rate limits and per-host limits <sec-limits>

`-c 32` caps how many checks run at once across the whole sweep. It doesn't
stop all 32 from landing on the same host when 300 of the inventory's targets
live behind one ingress controller. Real fleet tools need two more limits.

=== A global rate limit with a token bucket

`golang.org/x/time/rate` implements a token bucket: tokens refill at `r` per
second up to a burst size `b`, and each operation spends one. `Wait(ctx)`
blocks until a token is available or the context ends. If the context's
deadline would expire before a token arrives, it returns an error immediately
rather than sleeping uselessly.

`sweep` calls `limiter.Wait` before _every attempt_, retries included. That is
the important part. A retry budget that sits outside the rate limiter turns a
partial outage into a retry storm: every failing target retries at once,
exactly when the service is least able to cope. When retries spend from the
same budget as first attempts, the total load the tool generates has a hard
ceiling that holds regardless of how many failures it sees.

Burst deserves a moment. A burst of 1 spaces operations evenly; a larger burst
lets a quiet tool start quickly and then settle to the steady rate. `sweep`
uses a tenth of the per-second rate as its burst (at least 1). If your
target publishes a rate limit, set the steady rate below it, because other
clients are spending from the same allowance.

=== Per-host limits with a keyed semaphore

The second limit is per host: no more than `--per-host` concurrent checks
against any single `host:port`, however many targets it serves. This is
politeness, and it also makes results more trustworthy. Forty simultaneous
probes against one pod measure your own load, not the service's health.

A map of semaphores, one per key, sounds like three lines of code. The details
are where it gets interesting:

#src("pkg/conc/keyed.go", region: "keyed")

- The map is guarded by a mutex, but waiting for a slot happens _outside_ the
  lock. Holding a mutex while blocking on a channel would serialize every key
  behind the slowest one.
- Each slot is reference-counted, and waiters count too. Without that, a key
  could be deleted while a goroutine is waiting on its channel. The next
  `Acquire` would then create a fresh slot, and two goroutines would be
  running against a host that should allow one.
- Idle keys are deleted, so memory tracks active hosts rather than every host
  ever seen. In a long-running daemon (the monitoring agent in Chapter 25 uses
  the same type) that difference is a memory leak avoided.
- `release` is idempotent via `sync.Once`, because "release exactly once" is a
  rule humans break, usually in error paths.
- `Len` exists for tests and metrics. A `Len` that only ever grows means
  somebody lost a release function.

The order of operations in `sweep`'s checker is _host slot, then retry loop,
then rate-limit token per attempt_. Holding the host slot across retries keeps
backoff sleeps from letting another check sneak in against a host that is
already struggling. Taking the rate token per attempt keeps the global
budget honest.

== Retries that don't make outages worse <sec-retry>

Retries are the most dangerous few lines in a platform tool. Done naively
(immediate, fixed-interval, unlimited, everything retryable), they are how one
service's bad minute becomes everyone's bad hour. A production retry policy
answers five questions.

+ *Which failures are worth retrying?* Connection refused, resets, timeouts,
  HTTP 502/503/504 and 429 are usually transient. A 404, a 401, an invalid
  certificate, or `NXDOMAIN` will not fix itself in 200 milliseconds, so
  retrying them only wastes time and load.
+ *How long to wait?* Exponentially longer each time, capped.
+ *With how much randomness?* Enough that a thousand clients that failed
  together don't retry together.
+ *How many times, in total?* A fixed attempt budget, plus whatever overall
  deadline the context carries.
+ *Does the server have an opinion?* `Retry-After` on a 429 or 503 is the
  server telling you exactly how long to wait. Honour it.

=== Full jitter

The classic analysis of backoff strategies is Marc Brooker's 2015 post on the
AWS Architecture Blog, "Exponential Backoff And Jitter". It compared
strategies by simulating many clients contending for one resource. The winner
for total work and completion time was _full jitter_: compute the exponential
ceiling `min(cap, base × 2^attempt)` and then sleep a uniformly random
duration between zero and that ceiling. It looks wasteful, since some retries
fire almost immediately, but it spreads clients evenly across the whole
window, and that is what a recovering server needs.

#src("pkg/retry/retry.go", region: "backoff")

The `//nolint:gosec` with a reason is the right way to silence a linter. gosec
flags every use of `math/rand`; here it is a false positive, because jitter
needs spread, not unpredictability. A suppression without a reason will get
deleted by the next person who doesn't understand it, or copied somewhere it
isn't safe.

=== The policy

#src("pkg/retry/retry.go", region: "policy")

The zero value is useful: three attempts, 100 ms base, 5 s cap, everything
retryable unless marked otherwise. Configuration that works when left empty is
a kindness to callers and a common Go idiom. Operations classify their own
failures with two small wrappers:

#src("pkg/retry/retry.go", region: "errors")

`Permanent` and `After` are _transparent_ wrappers: their `Error` returns the
wrapped message, and `Unwrap` exposes it to `errors.Is` and `errors.As`.
Callers can mark an error without changing what users see. `ExhaustedError`
wraps the last attempt's error, so a caller can still ask
`errors.Is(err, syscall.ECONNREFUSED)` after three attempts.

=== The loop

#src("pkg/retry/retry.go", region: "do")

Two checks are easy to miss. First, `ctx.Err()` is tested right after a
failed attempt. When the run is cancelled, an in-flight HTTP request fails
with a context error that looks exactly like a timeout. Without the check, the
loop would sleep and "retry" a dead context, and the error message would blame
the target for something the user did. Second, the sleep is a `select` on a
timer and `ctx.Done()`, never a bare `time.Sleep`. A tool that ignores
#kbd("Ctrl-C") for up to five seconds of backoff feels broken.

#newingo("1.27", title: [Generic methods])[
  Go 1.27 lets methods declare their own type parameters. Before, a
  value-returning retry helper had to be a package-level function,
  `retry.DoValue[T](ctx, policy, op)`. Now it can live on the policy itself:
  #src("pkg/retry/retry.go", region: "value")
  Call sites infer `T`: `cfg, err := policy.Value(ctx, fetchConfig)`. Two
  limits remain. Interface methods still cannot have type parameters, and a
  generic method cannot satisfy an interface method, so keep generic methods
  for convenience APIs on concrete types.
]

#production(title: [Retry budgets across a fleet])[
  Per-call retry limits don't bound _aggregate_ load. If a service with a
  hundred callers starts failing, each caller retrying three times turns 100
  QPS into 400 QPS against a service that is already struggling. Large
  platforms add a _retry budget_: a token bucket, often per client process,
  that allows retries only up to, say, 10% of recent successful requests. When
  the budget is empty, failures are returned immediately. gRPC's
  `retryThrottling` service config implements this idea. For CLIs that run
  once and exit, the global rate limiter in this chapter is usually enough.
  For daemons and controllers, add a budget.
]

#interview(title: [“Design a retry policy for calling a flaky internal API.”])[
  Walk through the five questions in order: classify errors (retry transient
  failures, never retry 4xx or validation errors), back off exponentially
  with full jitter and a cap, bound attempts _and_ total time with a context
  deadline, honour `Retry-After`, and only retry idempotent operations, or
  make them idempotent with request IDs. Then talk about the fleet: retry
  budgets or circuit breakers so retries can't amplify an outage, and metrics
  on attempt counts so you can see when retries are quietly hiding a
  degrading dependency. Chapter 15 builds the circuit breaker.
]

== Deduplicating work with singleflight <sec-singleflight>

A sweep of 500 URLs spread across 20 hostnames resolves DNS 500 times unless
you do something about it. Worse, the lookups for one hostname all happen in
the same few milliseconds, because the checks start together. Two tools solve
this together: a small TTL cache, and `golang.org/x/sync/singleflight`, which
merges concurrent calls with the same key into one execution whose result
every caller shares.

The interesting part is the context:

#src("internal/sweep/resolver.go", region: "resolver")

The naive version passes the caller's `ctx` into the shared function. That
introduces a nasty coupling: the _first_ caller's context now governs the
lookup for _everyone_. If that first check has a 100 ms budget left and gives
up, the shared lookup is cancelled, and 40 other callers with plenty of time
left all fail with "context canceled" for a target that was perfectly fine.

The fix has three parts. The shared work runs on
`context.WithoutCancel(ctx)`, so it is detached from any single caller but
keeps request-scoped values such as trace IDs. It also gets its own timeout,
because detached work without a bound is a leak. And callers wait with
`DoChan` plus `select` on their _own_ `ctx.Done()`, so each one gives up on its
own schedule while the shared lookup carries on for the others.

#internals(title: [`singleflight` is not a cache])[
  `singleflight` only merges calls that overlap in time. The moment the shared
  call returns, the key is forgotten, and the next caller triggers a fresh
  execution. That's why the resolver pairs it with a TTL cache. The reverse
  is also true: a cache without singleflight suffers a _thundering herd_
  whenever an entry expires under load, as every concurrent miss goes to the
  backend at once. Use both, as here, whenever an expensive lookup sits on a
  hot path. `Group.Forget(key)` lets you evict an in-flight key early, for
  example after detecting that its result is already stale.
]

`CachingResolver.DialContext` has exactly the signature of
`http.Transport.DialContext`, so plugging the cache into every HTTP, TCP and
TLS check is one line of wiring. The `dns://` prober deliberately does _not_
use the cache, because the point of a DNS check is to exercise resolution
itself.
