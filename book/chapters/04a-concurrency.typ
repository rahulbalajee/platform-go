#import "../template/book.typ": *

#chapter(4, "Concurrency Patterns for Production Tooling", label: <ch-concurrency>,
  abstract: [
    Platform tools spend most of their lives waiting on APIs, sockets, disks,
    and other people's clusters. Go makes it trivial to wait on a thousand
    things at once. It makes it just as easy to leak goroutines, take down a
    dependency with your own retries, or turn #kbd("Ctrl-C") into a
    half-finished deploy. This chapter builds a small, strict concurrency
    toolkit and then uses it to build a fleet checker you can put in front of
    every release.
  ],
  learn: (
    [How the scheduler really runs goroutines, and why Go 1.25 changed the defaults inside containers],
    [Structured concurrency: every goroutine has an owner and an exit],
    [Context trees, deadlines, and cancellation _causes_],
    [Bounded parallelism three ways, and streaming results behind an iterator],
    [Rate limits, per-host limits, retries with full jitter, and singleflight],
    [Two-stage graceful shutdown],
    [Deterministic tests with `testing/synctest`, and finding leaks in production],
  ),
  build: [
    *`sweep`*, a CLI that checks hundreds of HTTP, TCP, TLS, and DNS targets
    concurrently with global and per-host limits, rate limiting, retries,
    streaming output, and clean #kbd("Ctrl-C") handling.

    #v(4pt)
    Three reusable packages that later chapters build on: *`pkg/conc`*,
    *`pkg/retry`*, and *`pkg/lifecycle`*.
  ],
)

== Tools are mostly waiting <sec-waiting>

It is release day. Before the pipeline promotes a build to production, someone
wants proof that the staging fleet is healthy: 340 HTTP health endpoints, the
TLS certificates on 60 public hostnames, TCP reachability for a dozen
databases and brokers, and DNS for the service names everything else depends
on. A sequential shell loop over that list takes several minutes on a good day
and much longer when a few targets time out. Engineers stop running it, which
is worse than not having it.

The work is almost entirely _waiting_. Each check spends microseconds of CPU
and hundreds of milliseconds blocked on the network. That is the shape of most
platform tooling: cloud API calls, Kubernetes list-and-watch, artifact
uploads, log tailing, health gates. Concurrency is the default for this kind of
program.

The first version every Go programmer writes looks like this:

#code(file: "naive.go", caption: "don't ship this")[```go
func checkAll(targets []string) {
	for _, t := range targets {
		go check(t) // fire and forget
	}
	time.Sleep(10 * time.Second) // "should be enough"
}
```]

It is fast in a demo. In production, every line is a bug:

- *Unbounded fan-out.* 5,000 targets means 5,000 simultaneous connections. You
  will run out of file descriptors (`ulimit -n` is often 1024 in containers),
  exhaust ephemeral ports, and trip the rate limiter or WAF of whatever sits in
  front of the targets. The tool that was meant to detect an outage can cause
  one.
- *No ownership.* Nothing waits for the goroutines. The `Sleep` is a guess. If
  a check hangs, its goroutine outlives the function and the results are lost.
- *No cancellation.* #kbd("Ctrl-C") kills the process mid-flight. There is no
  partial report and no exit status that tells CI what happened.
- *No failure policy.* Is one slow target a failure? Should it be retried? How
  many times, and how far apart, so that 300 copies of this tool don't hammer a
  recovering service in lockstep?
- *Untestable.* Any test that involves timeouts either sleeps (slow) or races
  (flaky).

The rest of this chapter fixes each of these. Along the way it builds the
pieces as reusable packages, because every project later in the book (the
deployment CLI, the operator, the monitoring agent, the AI investigator) has
the same needs.

== How Go runs your goroutines <sec-scheduler>

You can write correct concurrent Go without knowing how the runtime schedules
goroutines. Knowing it helps you predict performance, explain what you see in
a profile, and answer the interview question that comes up in almost every
senior Go loop.

The runtime multiplexes many goroutines (*G*) onto a few OS threads (*M*,
for machine) through a fixed number of logical processors (*P*). A thread
must hold a P to run Go code, and the number of Ps is `GOMAXPROCS`. Each P
owns a local run queue of runnable goroutines. An idle P steals half of
another P's queue, and there is a global queue for overflow and fairness.

#fig(caption: [The G-M-P scheduler. Goroutines blocked on the network don't hold a thread; goroutines in a blocking syscall do, so the runtime hands their P to another thread.])[
  #diagram(
    spacing: (22pt, 16pt),
    dnode((0, 0), [global run queue\ overflow & fairness], kind: "muted"),
    dnode((0, 1), [*P0* · local queue\ G4 G5 G6], kind: "accent"),
    dnode((1, 1), [*M0* · OS thread\ running G1], kind: "dark"),
    dnode((2, 1), [CPU core], kind: "muted"),
    dnode((0, 2), [*P1* · local queue\ G7], kind: "accent"),
    dnode((1, 2), [*M1* · OS thread\ running G2], kind: "dark"),
    dnode((2, 2), [CPU core], kind: "muted"),
    dnode((0, 3), [netpoller\ G8 G9 parked on sockets], kind: "good"),
    dnode((1, 3), [*M2* · blocked in a syscall with G3\ (its P was handed to another M)], kind: "warn"),
    dedge((0, 0), (0, 1), "--|>"),
    dedge((0, 1), (1, 1), "-"),
    dedge((1, 1), (2, 1), "-|>"),
    dedge((0, 2), (1, 2), "-"),
    dedge((1, 2), (2, 2), "-|>"),
    dedge((0, 3), (0, 2), "--|>", label: text(size: 6.5pt)[ready], label-side: left),
    dedge((0, 2), (0, 1), "--|>", label: text(size: 6.5pt)[steal], label-side: left, bend: 60deg),
  )
] <fig-gmp>

Three properties of this design matter for tool authors.

*Network waits are nearly free.* When a goroutine reads from a socket that has
no data, the runtime parks it and registers the file descriptor with the OS
poller (epoll on Linux, kqueue on macOS). No thread is blocked. When data
arrives, the goroutine goes back on a run queue. This is why ten thousand
goroutines each waiting on an HTTP response is unremarkable: they cost memory
(stacks start at a few kilobytes and grow on demand), not threads.

*Blocking syscalls and cgo are not free.* A goroutine making a blocking system
call, such as a read from a slow NFS mount or a cgo call into a C library,
holds its thread. The runtime notices and hands the P to another thread so
other goroutines keep running, but the stuck thread still exists. Thousands of
goroutines blocked in syscalls means thousands of OS threads. The runtime
aborts the program at 10,000 threads by default (`debug.SetMaxThreads`).

*Goroutines are preempted.* Since Go 1.14 the scheduler can interrupt a
goroutine in a tight loop with an asynchronous signal, so one CPU-bound
goroutine can't starve the others. You don't need `runtime.Gosched` calls
sprinkled through loops.

#newingo("1.25", title: [`GOMAXPROCS` respects container CPU limits])[
  Before Go 1.25, `GOMAXPROCS` defaulted to the number of CPUs on the _node_.
  A pod limited to 2 CPUs on a 64-core node ran with 64 Ps, burned its CFS
  quota in a fraction of each period, and got throttled, which showed up as
  mysterious latency spikes. Teams imported `go.uber.org/automaxprocs` to
  fix it. Since Go 1.25 the runtime reads the cgroup CPU _limit_ on Linux and
  updates `GOMAXPROCS` if the limit changes. It does not consider CPU
  _requests_, so a pod with requests but no limit still sees every core. You
  can opt out with `GODEBUG=containermaxprocs=0`, and setting `GOMAXPROCS`
  explicitly disables both behaviours.
]

#interview(title: [“How are goroutines different from threads?”])[
  Give the mechanism, not the slogan. Goroutines are scheduled by the Go
  runtime onto a small pool of OS threads (M:N scheduling) through
  `GOMAXPROCS` logical processors. They start with small, growable stacks, so
  creating one costs about as much as a small allocation. Network I/O parks
  goroutines on the netpoller without holding a thread, while blocking
  syscalls do hold one, which is why a program doing slow file I/O can still
  grow its thread count. Then close with the practical point: goroutines are
  cheap, but the resources they hold (connections, file descriptors, memory,
  load on a downstream service) are not. That is why you bound them.
]

== Rule zero: every goroutine has an owner and an exit <sec-ownership>

The single most useful discipline in concurrent Go is borrowed from
_structured concurrency_: a function that starts goroutines must not return
until those goroutines have finished. Callers then never have to wonder what
is still running in the background. Every helper built in this chapter keeps
that contract, and it is the first thing to check in code review.

Two habits make the contract easy to keep.

*Pair every `go` with a wait.* `sync.WaitGroup` is the primitive. Go 1.25
added `WaitGroup.Go`, which does the `Add(1)` and the deferred `Done()` for
you and removes the classic bug of calling `Add` inside the goroutine:

#code(file: "waitgroup.go")[```go
var wg sync.WaitGroup
for _, t := range targets {
	wg.Go(func() { // Go 1.25+: Add(1), go, defer Done()
		check(ctx, t)
	})
}
wg.Wait() // nothing outlives this line
```]

Since Go 1.22 each loop iteration has its own `t`, so capturing the loop
variable in the closure is correct. If you maintain code with a `go` directive
older than 1.22 in `go.mod`, the old per-loop semantics still apply to it and
`t := t` copies are still needed.

*The sender closes the channel.* A channel should have exactly one owner that
closes it, and that owner is the side that sends. Receivers never close. If
several goroutines send, none of them can close it safely, so the
coordinating goroutine waits for all of them and then closes. You will see that
shape in every pipeline in this chapter: a producer goroutine, a `WaitGroup`
for the workers, and `close` after `Wait`.

#warning(title: [The early-return leak])[
  The most common goroutine leak in production Go looks innocent. Here is the
  version from the `goroutineleak` example in the repository:
  #src("examples/ch04/leak/main.go", region: "leak")
  When the first error arrives, the function returns and nobody will ever
  read from `errc` again. Every goroutine that hasn't sent yet blocks forever,
  holding its stack and anything it references. Run it a thousand times in a
  long-lived process and you have a slow memory leak that no heap profile
  explains. The fixes are a buffered channel sized to the number of senders,
  or a context that senders `select` on. @sec-diagnosing shows how Go 1.27
  finds this bug for you.
]

== Context: the cancellation tree <sec-context>

A `context.Context` carries three things across API boundaries: a cancellation
signal, an optional deadline, and request-scoped values. Contexts form a tree.
Cancelling a node cancels everything below it and nothing above it. Each
operation can therefore have its own limits while still responding to the
global ones.

Here is the tree `sweep` builds by the end of the chapter:

#fig(caption: [The context tree in `sweep`. Each layer adds one reason to stop. The shared DNS lookup is deliberately detached from any single caller.])[
  #diagram(
    spacing: (14pt, 14pt),
    dnode((1, 0), [`lifecycle.NotifyContext`\ cancelled on SIGINT / SIGTERM · cause `*SignalError`], kind: "dark"),
    dnode((1, 1), [`WithTimeoutCause(--deadline)`\ cause: "sweep deadline exceeded"], kind: "accent"),
    dnode((1, 2), [`conc.Stream`\ cancelled when the consumer stops early], kind: "accent"),
    dnode((0, 3), [target A\ host slot → retry loop], kind: "default"),
    dnode((2, 3), [target B\ host slot → retry loop], kind: "default"),
    dnode((0, 4), [attempt 1 · 5s\ cause `errAttemptTimeout`], kind: "muted"),
    dnode((1, 4), [attempt 2 · 5s], kind: "muted"),
    dnode((2, 4), [shared DNS lookup\ `WithoutCancel` + own timeout], kind: "warn"),
    dedge((1, 0), (1, 1), "-|>"),
    dedge((1, 1), (1, 2), "-|>"),
    dedge((1, 2), (0, 3), "-|>"),
    dedge((1, 2), (2, 3), "-|>"),
    dedge((0, 3), (0, 4), "-|>"),
    dedge((0, 3), (1, 4), "-|>"),
    dedge((2, 3), (2, 4), "--|>", label: text(size: 6.5pt)[detached], label-side: left),
  )
] <fig-context-tree>

The rules that keep context trees sane are short:

+ Pass `ctx` as the first parameter of anything that blocks, does I/O, or
  starts goroutines. Don't store it in structs, because the struct outlives
  the operation the context describes. (Long-lived components such as a
  Kubernetes controller manager take a context in `Start(ctx)` and keep the
  lifetime explicit.)
+ Derive, don't replace. A function that needs a tighter deadline wraps the
  context it was given. It never creates a fresh `context.Background()` in
  the middle of a call chain, because that silently disconnects #kbd("Ctrl-C").
+ Always call the `cancel` function, usually with `defer`. It releases the
  timer and the child's registration in its parent, so a missing `cancel` in a
  loop is a leak.
+ Check `ctx.Err()` before starting expensive work, and `select` on
  `ctx.Done()` wherever you block on something that doesn't take a context.

=== Causes: saying _why_ you stopped

`ctx.Err()` only ever returns `context.Canceled` or
`context.DeadlineExceeded`. For a tool, that loses the most important
information. Did the user press #kbd("Ctrl-C")? Did the overall `--deadline`
fire? Did this one attempt exceed its own timeout? The `Cause` family (Go 1.20
and 1.21) answers that:

#code(file: "causes.go")[```go
var errAttemptTimeout = errors.New("attempt timed out")

ctx, cancel := context.WithTimeoutCause(parent, 5*time.Second, errAttemptTimeout)
defer cancel()

_, err := client.Do(req.WithContext(ctx))
switch {
case errors.Is(context.Cause(ctx), errAttemptTimeout):
	// this attempt was slow: retryable, report "timed out after 5s"
case parent.Err() != nil:
	// the whole run is being cancelled: stop retrying, report why
	log.Printf("stopping: %v", context.Cause(parent))
}
```]

`context.Cause(ctx)` returns the cause attached to the first cancellation in
the chain, or `ctx.Err()` if none was given. `sweep` uses causes at three
levels: a `*lifecycle.SignalError` from the signal handler, a "sweep deadline
exceeded" error from `--deadline`, and `errAttemptTimeout` for individual
attempts. The output can then tell the user exactly what happened, and the
exit code can tell CI.

#newingo("1.26", title: [Signal contexts carry the signal])[
  `signal.NotifyContext` now cancels its context with a cause that names the
  signal received, so `context.Cause(ctx)` reports `interrupt` or
  `terminated` rather than a bare `context canceled`. We still write our own
  wrapper in @sec-shutdown, because production CLIs also need a second-signal
  escape hatch and a typed cause.
]

=== Three context functions worth knowing

`context.WithoutCancel(ctx)` (Go 1.21) returns a child that keeps the parent's
values but is never cancelled by it. Use it for work that must finish even if
the request that triggered it goes away: writing an audit record after a
deployment request is cancelled, or a lookup shared by many callers
(@sec-singleflight). Always give the detached work its own timeout, or you
have built a leak.

`context.AfterFunc(ctx, f)` (Go 1.21) runs `f` in its own goroutine when `ctx`
is done. It is the clean way to make a blocking call that doesn't support
contexts respond to cancellation, for example by closing a connection to
unblock a `Read`:

#code(file: "afterfunc.go")[```go
stop := context.AfterFunc(ctx, func() { conn.Close() }) // unblocks Read on cancel
defer stop()
n, err := conn.Read(buf)
```]

`t.Context()` (Go 1.24) gives every test a context that is cancelled just
before the test's cleanup functions run. Use it instead of
`context.Background()` in tests so goroutines started by the code under test
get a stop signal.

== Bounded parallelism, three ways <sec-bounded>

Bounding concurrency is the first fix to the naive loop. There are three
standard shapes. Each one is right somewhere.

=== Shape 1: the worker pool

A fixed set of N long-lived workers pull jobs from a channel. It is the
oldest pattern and still the best when workers hold expensive per-worker
state: a database connection, a gRPC stream, a scratch buffer, an
authenticated SDK client.

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
	go func() { wg.Wait(); close(results) }() // workers are the senders on results
	return results
}
```]

Note who closes what: the producer closes `jobs` because it is the only
sender, and a separate goroutine closes `results` after every worker, the
senders on that channel, has returned. The function returns a channel, so it
breaks rule zero by design: the goroutines outlive the call until the caller
drains `results`. If the caller stops reading early, the workers block on
`results <- ...` forever. Keep that in mind, because the iterator in
@sec-stream fixes exactly this.

=== Shape 2: the semaphore

One goroutine per item, with a buffered channel as a counting semaphore so at
most N run at once. Goroutines are cheap, so creating one per item is fine;
what you limit is how many are _active_.

#code(file: "semaphore.go")[```go
sem := make(chan struct{}, n)
var wg sync.WaitGroup
for _, t := range targets {
	select {
	case sem <- struct{}{}: // acquire a slot (blocks when n are active)
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

Acquiring _before_ `go` matters: the loop itself blocks, so the producer can't
race ahead and create 5,000 parked goroutines. That is backpressure. For
weighted limits, such as "at most 2 GiB of downloads in flight", use
`golang.org/x/sync/semaphore`, whose `Acquire(ctx, n)` also takes a context.

=== Shape 3: errgroup

`golang.org/x/sync/errgroup` packages the semaphore with error propagation.
`SetLimit(n)` bounds concurrency, `Go` blocks until a slot is free,
`WithContext` cancels the group's context on the first error, and `Wait`
returns that first error. It is the right default when one failure should
abort everything. Here is `conc.Map`, the fail-fast helper the later projects
use to fetch state from N clusters or N cloud accounts:

#src("pkg/conc/conc.go", region: "map")

Two details deserve attention. Results are written by index into a slice
allocated up front, so no mutex is needed: each goroutine owns exactly one
element, and the `Wait` call establishes the happens-before edge that makes
the writes visible to the caller. And the loop checks `ctx.Err()` before each
`Go`, so after a failure no new work starts.

#table(
  columns: (auto, 1fr, 1fr),
  align: (left, left, left),
  table.header([Shape], [Use when], [Watch out for]),
  [Worker pool], [Workers hold expensive state (connections, streams, clients), or you want a fixed, long-lived set of goroutines], [Who closes which channel; a consumer that stops reading blocks every worker],
  [Semaphore], [One goroutine per item with a cap; you need context-aware acquisition or weighted limits], [Acquire before `go`, not inside it, or you lose backpressure],
  [errgroup], [Fail-fast semantics: the first error should cancel the rest and be returned], [`Go` blocks _without_ watching the context (see @sec-stream)],
)

#tip(title: [Choosing N])[
  For I/O-bound work, N is a statement about the _target_, not your CPU count.
  Start from what the downstream system tolerates (its rate limits,
  connection limits, and how many replicas serve it) and make N a flag with a
  conservative default. For CPU-bound work, N near `GOMAXPROCS` is the ceiling;
  more just adds scheduling overhead. Mixed workloads are best split into
  stages with separate limits, which is where pipelines come in.
]
