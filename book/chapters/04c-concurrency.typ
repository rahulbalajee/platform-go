#import "../template/book.typ": *
#import "04-lib.typ": ts, needspace

#step(6, 7, "Reports", label: <sec-shared>)

So far `sweep` prints one line per result, in whatever order the checks
finish. That's fine for a person watching a terminal and wrong for everything
else. Someone scanning a table expects it to follow the inventory file. A CI
job wants a JSON document it can parse. A log shipper or `jq` wants one JSON
object per line, written the moment each result exists. This step adds four
output formats behind one interface, and a summary type that replaces the
counting `run` does by hand.

=== Who owns the output?

The reporter receives results from dozens of concurrent checks, so the first
question is how to keep its state safe. "Don't communicate by sharing memory;
share memory by communicating" is the Go proverb everyone quotes. The standard
library uses far more mutexes than channels, and that isn't a contradiction.
Channels are for transferring _ownership_ of data and for _coordination_
(start, stop, done, here is the next item). Mutexes are for _protecting state_
that several goroutines touch. Pick the tool that matches what you're doing:

#table(
  columns: (auto, 1fr),
  table.header([Tool], [Reach for it when]),
  [Ownership], [One goroutine owns the data and everyone else talks to it. No locks at all. `sweep`'s reporter is owned by the `range` loop, the only code that touches it.],
  [Channel], [Handing work or results between goroutines, signalling completion or cancellation, bounding concurrency (as a semaphore).],
  [`sync.Mutex`], [Several goroutines read and write a small piece of state: a map, a cache, a counter with invariants. Keep critical sections tiny and never block while holding the lock.],
  [`sync.RWMutex`], [Reads vastly outnumber writes _and_ the critical section is long enough to matter. Otherwise a plain mutex is as fast and simpler. Never take a read lock recursively: a waiting writer blocks new readers, so a nested `RLock` can deadlock.],
  [`sync/atomic` types], [Independent counters, gauges and flags: `atomic.Int64`, `atomic.Bool`, `atomic.Pointer[T]`. The typed API (Go 1.19) prevents mixing atomic and plain access to the same word, and Go 1.27's `go fix` includes an `atomictypes` modernizer that migrates the old function-style calls.],
  [`sync.OnceValue`], [Lazy, concurrency-safe initialisation of an expensive value, such as a parsed config or an SDK client (Go 1.21).],
  [`sync.Map`], [Mostly append-only caches, or goroutines working on disjoint keys. For anything else, a map plus a mutex is clearer and usually faster.],
)

Prefer the first row whenever you can. `Stream` hands each result across a
channel to the caller's loop, and that loop runs on one goroutine. If the
summary and the reporter are touched only inside the loop, dozens of workers
produce results concurrently and there is still no lock anywhere in the
reporting path. When you find yourself adding a mutex to an output formatter,
ask whether one goroutine could own it instead.

#goconcept(title: [Struct tags and `encoding/json`])[
  A struct field can carry a _tag_, a string literal after its type that
  libraries read at run time:
  #raw("Latency time.Duration `json:\"latency_ns\"`").
  `encoding/json` uses the tag as the key name; `omitempty` leaves the field
  out when it holds its zero value, and `json:"-"` skips it. Only exported
  (capitalized) fields are encoded. The tag syntax is strict: `key:"value"`
  with no spaces around the colon, and `go vet` reports malformed tags. Keys in
  snake_case are the convention for tools that other teams script against.
  `json.NewEncoder(w).Encode(v)` writes `v` plus a newline, which makes JSON
  Lines trivial.
]

=== The report package

Results become JSON, so `Result` gets tags. Replace it in `runner.go`:

#src("workbook/ch04/step6/internal/sweep/runner.go", region: "result")

`Latency` is a `time.Duration`, which encodes as an integer number of
nanoseconds; the key name says so, because a consumer guessing the unit wrong
is a classic dashboard bug. Create `internal/sweep/report.go`, starting with
the interface every format implements:

#src("workbook/ch04/step6/internal/sweep/report.go", region: "head")

The summary used to be three local variables in `run`. It becomes a type with
a `Tally` method for the loop, a `Healthy` method for the exit status, and a
`String` method for the last line on standard error:

#src("workbook/ch04/step6/internal/sweep/report.go", region: "summary")

`Tally` has a pointer receiver, `(s *Summary)`, because it changes the
summary. With a value receiver it would increment a copy, the caller would
never see the counts, and the program would still compile. The troubleshooting
table shows how that looks. The constructor picks a format by name:

#src("workbook/ch04/step6/internal/sweep/report.go", region: "new")

The table formats buffer results and sort them back into inventory order,
because a human scanning a table expects it to match the file.
`text/tabwriter` aligns the columns:

#src("workbook/ch04/step6/internal/sweep/report.go", region: "table")

`Close` returns `tw.Flush()`. The tabwriter buffers everything until it is
flushed, and the flush is also where a write error to a closed pipe finally
shows up. Last, the two JSON formats:

#src("workbook/ch04/step6/internal/sweep/report.go", region: "json")

`jsonl` is the only format that writes during the sweep: each result goes out
the moment it arrives, so `jq` downstream sees it at once. `json` waits and
writes one document with the summary and every result in input order, for
tools that want a single blob to parse.

=== `run` with a reporter

In `main.go`, `strings` is no longer needed. Replace the imports:

#src("workbook/ch04/step6/cmd/sweep/main.go", region: "imports")

Add the `-o` flag:

#src("workbook/ch04/step6/cmd/sweep/main.go", region: "flags")

Replace `run`, and delete `printResult`, which the reporters replace:

#src("workbook/ch04/step6/cmd/sweep/main.go", region: "run")

The reporter is created before the runner, so `-o yaml` is rejected before a
single target is contacted. The loop is the single owner of `sum` and
`reporter`. A failed write stops the sweep with status 2: if `stdout` is a pipe
whose reader has gone away (`sweep -o jsonl | head -3`), there is no point in
checking the remaining targets. Breaking out of the loop is safe, because
`Stream` cancels and waits for its workers before the loop statement ends.

=== Tests

Create `internal/sweep/summary_test.go`. The first test pins down the summary
line, including a target that never got checked:

#src("workbook/ch04/step6/internal/sweep/summary_test.go", region: "head")
#src("workbook/ch04/step6/internal/sweep/summary_test.go", region: "summary")

The JSON Lines test proves that a result is written _before_ `Close`, which
is the whole point of the format. It also pins every key name, because those
names are an API other people's scripts depend on:

#src("workbook/ch04/step6/internal/sweep/summary_test.go", region: "jsonl")

The table test feeds results in completion order and expects input order:

#src("workbook/ch04/step6/internal/sweep/summary_test.go", region: "table")

The end-to-end test in `cmd/sweep/main_test.go` switches to `-o json` and
decodes the output instead of searching it for words. It adds a TCP target on
a closed port, so the sweep covers two kinds. Replace the imports and the
test:

#src("workbook/ch04/step6/cmd/sweep/main_test.go", region: "imports")
#src("workbook/ch04/step6/cmd/sweep/main_test.go", region: "e2e")

Add a case for an unknown format to the usage test, and the `closedPort`
helper at the end of the file:

#src("workbook/ch04/step6/cmd/sweep/main_test.go", region: "usage")
#src("workbook/ch04/step6/cmd/sweep/main_test.go", region: "closedport")

#needspace(12em)
#checkpoint(step: 6, of: 7, title: [Reports])[
  #output("ch04/s6-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch04/s6-test.txt", cmd: "go vet ./... && go test ./...")
  Restart the fleet before each of the next three runs, so `/flaky` behaves
  the same way every time. The default table is in inventory order:
  #output("ch04/s6-table.txt", cmd: "go run ./cmd/sweep -timeout 1s retry.txt", size: 6.6pt)
  The JSON document starts with the summary:
  #output("ch04/s6-json.txt", cmd: "go run ./cmd/sweep -o json -timeout 1s retry.txt 2>/dev/null | head -22")
  JSON Lines composes with `jq`, here keeping only the targets that are down:
  #output("ch04/s6-jq.txt", cmd: "go run ./cmd/sweep -o jsonl -timeout 1s retry.txt 2>/dev/null | jq -c 'select(.status==\"down\") | {target, attempts, error}'", size: 6.2pt)
  An unknown format is a usage error, reported before any work starts:
  #output("ch04/s6-format.txt", cmd: "go run ./cmd/sweep -o yaml retry.txt")
  #troubleshoot(
    ([#ts("s6-tag.txt")], [A malformed struct tag: the value must be quoted, `json:"latency_ns"`.], [Fix the tag. `go vet` checks every tag.]),
    ([#ts("s6-receiver.txt")], [`Tally` has a value receiver, so it counts on a copy.], [Methods that modify their receiver need `*Summary`.]),
    ([#ts("s6-receiver-lint.txt")], [The same mistake, as staticcheck reports it.], [As above.]),
    ([#ts("s6-flush.txt")], [`Close` returned without flushing the tabwriter, so nothing was printed.], [`return tw.Flush()`.]),
  )
]

#step(7, 7, "Shutdown in two stages", label: <sec-shutdown>)

Every long-running tool is eventually interrupted. A developer presses
#kbd("Ctrl-C") because they spotted a typo in the inventory. Kubernetes sends
`SIGTERM` to a pod and starts the `terminationGracePeriodSeconds` clock (30
seconds by default) before it sends `SIGKILL`. A CI system cancels a job and
sends `SIGINT`, then escalates to `SIGTERM` and `SIGKILL` a few seconds later.
Each is a request to stop _soon_, and a well-behaved tool does three things:

+ Stop starting new work.
+ Cancel or finish in-flight work within a bounded time, and report what
  happened, including partial results.
+ Exit with a status that says it was interrupted (130 for `SIGINT`), not
  "success" and not a generic failure.

Step 2 already does all three. There is a fourth requirement that people
forget until they've been burned by it. If shutdown itself hangs (a stuck
write, a dependency that never answers), the user must be able to force the
issue. The convention across Docker, kubectl, Terraform and most well-behaved
CLIs is the same: the first #kbd("Ctrl-C") asks politely, the second one means
it. `signal.NotifyContext` can't do that: after the first signal it cancels
its context and quietly swallows every later one until `stop` is called, so a
second #kbd("Ctrl-C") does nothing at all. This step replaces it with a
package of our own, and adds two flags every production tool ends up with.

=== Package `lifecycle`

Create `lifecycle/lifecycle.go`:

#src("workbook/ch04/step7/lifecycle/lifecycle.go", region: "head")
#src("workbook/ch04/step7/lifecycle/lifecycle.go", region: "notify")

The details that make this production-grade:

- The signal channel is buffered. `signal.Notify` never blocks when it
  delivers a signal; if the channel is full, the signal is dropped. With a
  buffer of two, a fast double-tap is never lost.
- The cancellation cause is a typed `*SignalError`, so callers can tell
  "interrupted by the user" from "deadline exceeded" with `errors.AsType`.
  That is how `sweep` chooses between exit status 130 and 1.
- `Exit` and `Stderr` can be replaced, so the two-stage behaviour has a real
  test, not a manual check.
- `stop` is idempotent, unregisters the handler (restoring the default "kill
  the process" behaviour for later signals), waits for the helper goroutine,
  and cancels the context. Rule zero again.

The test sends real signals to the test process. It uses `SIGUSR1`, because a
`SIGINT` would also reach `go test` itself. The build constraint keeps it off
Windows, which has no `SIGUSR1`. Create `lifecycle/lifecycle_test.go`:

#src("workbook/ch04/step7/lifecycle/lifecycle_test.go", region: "head")
#src("workbook/ch04/step7/lifecycle/lifecycle_test.go", region: "test")

`syncBuffer` exists because the helper goroutine writes to `Stderr` while the
test goroutine reads it; a plain `strings.Builder` would be a data race, and
`-race` would say so.

=== The final `main`

Replace the imports of `main.go`: `lifecycle` replaces `os/signal` and
`syscall`.

#src("workbook/ch04/step7/cmd/sweep/main.go", region: "imports")

Delete the `exitInterrupted` constant, since `lifecycle.ExitInterrupted` has
the same value, and replace `main`:

#src("workbook/ch04/step7/cmd/sweep/main.go", region: "main")

`main` stays tiny, and the order of its last three lines matters. `os.Exit`
ends the process without running deferred calls, so `stop()` is called by
hand first; `defer stop()` followed by `os.Exit` would leave the signal
handler registered and its goroutine running until the process died. Two new
flags complete the tool:

#src("workbook/ch04/step7/cmd/sweep/main.go", region: "flags")

`-deadline` bounds the whole sweep, which a CI job needs when a step has a
time budget. `-version` prints the version variable that release builds stamp
with `-ldflags`. Replace `run`:

#src("workbook/ch04/step7/cmd/sweep/main.go", region: "run")

The deadline is one more layer in the context tree (@fig-context-tree), with
its own cause, so cancelled results say "sweep deadline of 1.5s exceeded"
instead of "context deadline exceeded". `isSignal` reads the cause to pick
the exit status: a run cut short by #kbd("Ctrl-C") exits 130, while a run cut
short by its own deadline exits 1, because a sweep that didn't finish in time
didn't prove the fleet healthy.

The interrupted test now cancels with a `SignalError`, as the real handler
does. Replace the imports of `cmd/sweep/main_test.go` and the test:

#src("workbook/ch04/step7/cmd/sweep/main_test.go", region: "imports")
#src("workbook/ch04/step7/cmd/sweep/main_test.go", region: "interrupted")

#production(title: [Shutdown in Kubernetes is a race])[
  When a pod is deleted, the kubelet sends `SIGTERM` _at the same time_ as the
  endpoints controller starts removing the pod from Service endpoints. For a
  few seconds your process is shutting down while load balancers and
  kube-proxy may still route new requests to it. Servers (Chapter 13) handle
  this by failing their readiness probe first, waiting briefly in a `preStop`
  hook or in code, and only then draining. For batch-style tools like
  `sweep`, the lesson is simpler: make the grace period you need explicit in
  the Job spec, and make sure your shutdown path finishes well inside it.
]

=== What the tests now guarantee <sec-testing>

`sweep` is done, and its tests are worth a second look as a set, because they
show how to test concurrent code without flakiness:

- *Every package runs under `-race` in CI.* The race detector only finds races
  that happen during the run, so concurrent tests must really run things
  concurrently, as the fleet and limit tests do.
- *goleak guards `conc` and `internal/sweep`.* A test that leaves a goroutine
  behind fails, even if all its assertions passed.
- *Timing is virtual.* The runner, retry and semaphore tests use `synctest`
  bubbles and the in-memory network, so a test with three two-second timeouts
  and jittered backoff finishes in microseconds and asserts exact durations.
- *Real sockets stay outside bubbles.* The TLS certificate test, the TCP
  test, the end-to-end CLI test and the signal test use the real clock and the
  real network, and keep their timeouts generous.

#warning(title: [What synctest can't see])[
  Locking a `sync.Mutex`, blocking on real I/O, and system calls are _not_
  durably blocking, because something outside the bubble could unblock them.
  A goroutine stuck on a mutex inside a bubble stops the fake clock from
  advancing, and a real socket inside a bubble can hang the test outright, as
  the troubleshooting table below shows. Keep mutex critical sections short
  (good advice anyway), use the in-memory network, and keep real sockets,
  files and subprocesses out of bubbles.
]

#needspace(12em)
#checkpoint(step: 7, of: 7, title: [Shutdown in two stages])[
  This is the finished tool. Its files and tests match the repository's
  `pkg/conc`, `pkg/retry`, `pkg/lifecycle`, `internal/sweep` and `cmd/sweep`.
  #output("ch04/s7-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch04/s7-test.txt", cmd: "go vet ./... && go test -race ./...")
  The bubbles at work: six seconds of timeouts and three backoff sleeps, in
  no measurable time.
  #output("ch04/s7-synctest.txt", cmd: "go test -v -run 'TestRunnerOutcomes|TestDoRetriesUntilSuccess' ./internal/sweep ./retry 2>&1 | grep -E '^(=== RUN|--- |ok)'", size: 6.6pt)
  Build the binary and look at its interface:
  #session(
    ("go build -o sweep ./cmd/sweep", "ch04/s7-build.txt"),
    ("./sweep -version", "ch04/s7-version.txt"),
    ("./sweep -h", "ch04/s7-help.txt"),
  )
  With the fleet running, sweep the eight slow targets two at a time and
  press #kbd("Ctrl-C") after about a second:
  #session(
    ("./sweep -c 2 many.txt", "ch04/s7-ctrlc.txt"),
    ("echo $?", "ch04/s7-ctrlc-status.txt"),
  )
  The two checks in flight were cancelled and reported, the six that never
  started are counted, and the status is 130. A deadline instead of a signal
  gives status 1, and each cancelled result names the deadline:
  #output("ch04/s7-deadline.txt", cmd: "./sweep -deadline 1500ms fleet.txt; echo \"exit status $?\"", size: 6.6pt)
  #troubleshoot(
    ([#ts("s7-unbuffered.txt")], [`make(chan os.Signal)` without a buffer: `signal.Notify` drops signals it can't deliver at once.], [Buffer the channel; two slots for a double-tap.]),
    ([#ts("s7-lostcancel.txt")], [The `cancel` from `WithTimeoutCause` was discarded, so its timer lives until the deadline.], [Keep `cancel` and `defer cancel()`.]),
    ([#ts("s7-exitdefer.txt")], [`defer stop()` followed by `os.Exit`: the deferred call never runs.], [Call `stop()` before `os.Exit`, as `main` does.]),
    ([#ts("s7-realnet.txt")], [`httptest.NewServer` (real sockets) inside a `synctest` bubble: the fake clock waits for I/O that it can't see, and the test hangs.], [Use `httptest.NewTestServer` in bubbles.]),
  )
]

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
(stacks start at a few kilobytes and grow on demand), not threads. It is also
why `sweep`'s limits are about the _targets_, not about Go.

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

== Diagnosing concurrency in production <sec-diagnosing>

Tests catch most problems. The rest show up at 3 a.m. as a process that is
alive but stuck, or a memory graph that only goes up. Go gives you four tools
for those nights.

*Goroutine dumps.* Send `SIGQUIT` (`kill -QUIT <pid>`, or #kbd("Ctrl-\\") in a
terminal) and the runtime prints every goroutine's stack and exits.
`GOTRACEBACK=all` (or `system`, `crash`) controls how much detail appears.
Since Go 1.27, tracebacks include the goroutine's `runtime/pprof` labels in
the header line, so tag goroutines with labels such as the target or the
request ID and the dump shows which goroutine was doing what. A dump with 4,000
goroutines all parked on the same line is the classic signature of a leak.
You have already read several of these: every `synctest` deadlock and test
timeout in this chapter's troubleshooting tables printed one.

*The goroutine profile.* In daemons, expose `net/http/pprof` on a
localhost-only admin port, never on the public listener, and fetch
`/debug/pprof/goroutine?debug=2` without killing the process. It aggregates
identical stacks, so you see the count for each blocked line.

*The goroutine leak profile.* The most common goroutine leak in production Go
looks innocent. Here it is, reduced to its essence in
`examples/ch04/leak/main.go`:

#src("examples/ch04/leak/main.go", region: "leak")

When the first error arrives, the function returns and nobody will ever read
from `errc` again. Every goroutine that hasn't sent yet blocks forever,
holding its stack and anything it references. It is step 2's leak without the
test that caught it. Run it a thousand times in a long-lived process and you
have a slow memory leak that no heap profile explains. The fixes are a buffered
channel sized to the number of senders, or a context that senders `select`
on, or `conc.Map`.

Go 1.26 introduced a `goroutineleak` profile as an experiment, and Go 1.27
made it generally available in `runtime/pprof` and as
`/debug/pprof/goroutineleak`. It uses the garbage collector to find goroutines
blocked on a channel, mutex or condition variable that is no longer reachable
from any goroutine that could unblock it. Those goroutines are provably stuck
forever. The example's `main` calls `checkAll`, waits, and prints the profile.
Copy it into a directory of its own with a `go.mod` and run it:

#output("ch04/leak.txt", cmd: "go run .")

The profile reports three leaked goroutines, all on line 20: the send inside
the closure, after `checkAll` returned on the first error. Detection relies on
reachability, so leaks through channels held in global variables or by
runnable goroutines can escape it. It still catches a large and common class
of bugs with no false positives, which is exactly what you want from a
profile you check during an incident.

*The execution trace flight recorder.* Some problems are about _timing_: a
reconcile loop that stalls for two seconds once an hour, or GC pauses that
line up with timeouts. `runtime/trace.FlightRecorder` (Go 1.25) keeps the
last few seconds of execution trace in a ring buffer at low overhead, and
`WriteTo` snapshots it when your code notices something wrong, for instance a
request that exceeded its latency objective. You get a trace of the moments
_before_ the anomaly, which is what you need. Chapter 30 uses it alongside
CPU and heap profiles and PGO.

For dashboards, `runtime/metrics` exposes scheduler metrics (Go 1.26 added
counts of goroutines by state under `/sched/goroutines`, OS thread counts, and
total goroutines created). Chapter 17 wires them into OpenTelemetry and
Prometheus alongside the application's own metrics.

#takeaways(
  [Goroutines are cheap; what they hold is not. Bound concurrency according to what the _downstream_ tolerates, and make the bound a flag.],
  [Rule zero: a function that starts goroutines doesn't return until they finish. `WaitGroup.Go`, `errgroup`, and iterators that wait before returning make this easy to keep; goleak makes it a test.],
  [Contexts form a tree. Derive, don't replace; always call `cancel`; use causes so users and exit statuses can tell #kbd("Ctrl-C") from a deadline from a slow target.],
  [Pick failure semantics deliberately: fail-fast (`conc.Map`) when one error invalidates the result, collect-all (`conc.Stream`) when failures are data.],
  [Retries need classification, exponential backoff with full jitter, a cap, a total deadline, `Retry-After`, and a shared rate budget. Anything less can amplify an outage.],
  [Shared lookups via singleflight must not inherit one caller's cancellation: detach with `WithoutCancel`, bound with a timeout, and let callers wait on their own contexts.],
  [Prefer ownership to locks: one goroutine that owns the reporter needs no mutex.],
  [Graceful shutdown has two stages: the first signal cancels and reports, the second exits at once with status 130.],
  [`-race`, goleak and `testing/synctest` (plus Go 1.27's `httptest.NewTestServer`) make concurrent tests fast and deterministic. The `goroutineleak` profile finds what tests miss.],
)

#exercise-set(4,
  (
    tier: "warm-up",
    title: [Count the retries],
    body: [
      A target that needed three attempts to come up is healthy today and a
      problem next week. Add a `Retried` field to `Summary` (JSON key
      `retried`) that counts results with more than one attempt, whatever
      their status, and make `String` append `, N retried` after the down
      count when N is above zero. With no retries the line must not change.
    ],
    hint: [Everything happens in `report.go`. Which method sees every result?],
    tests: "workbook/ch04/exercises/ex1",
  ),
  (
    tier: "warm-up",
    title: [Collect every error],
    body: [
      `conc.Map` stops at the first error. Write `conc.MapAll`, with the same
      signature, that runs every call (at most `limit` at once), returns all
      results in input order, and returns the failures joined with
      `errors.Join` in input order, or `nil` if there were none. A failure
      must not cancel the other calls. The result of a failed item is `R`'s
      zero value.
    ],
    hint: [Start from the semaphore shape in @sec-bounded, not from `Map`: `errgroup.WithContext` is exactly the behaviour you don't want.],
    tests: "workbook/ch04/exercises/ex2",
  ),
  (
    tier: "warm-up",
    title: [Which limit binds?],
    body: [
      `sweep` has three limits: `-c` (default 32), `-per-host` (4) and `-rate`
      (50 attempts per second, burst 5). For each inventory, predict how long
      the sweep takes and which limit decides it, assuming every target
      answers successfully: (a) 300 targets spread evenly over 3 hosts, each
      answering in 100 ms, default flags; (b) the same with `-rate 0`; (c) 300
      targets on 300 different hosts, 100 ms each, `-rate 0`; (d) 200 targets
      on one host that answers instantly, default flags. Then check (d)
      against the fake fleet with and without `-rate 0`.
    ],
    hint: [Work out each limit's ceiling in checks per second; the lowest one wins.],
  ),
  (
    tier: "core",
    title: [Fail fast],
    body: [
      A deploy gate doesn't need to know about every broken target; one is
      enough to stop the promotion. Add `-fail-fast` to `sweep`: stop at the
      first result that is down, cancel the checks in flight, print the
      results seen so far, and end the summary line with
      `(stopped at first failure)`. The exit status is 1. Without the flag,
      nothing changes.
    ],
    hint: [The change is a few lines in `run`. What does `Stream` do when the loop body executes `break`?],
    tests: "workbook/ch04/exercises/ex4",
  ),
  (
    tier: "core",
    title: [A time budget for retries],
    body: [
      `MaxAttempts` bounds how many times `Do` tries, but not how long it
      takes when each attempt is slow. Add `MaxElapsed time.Duration` to
      `retry.Policy`. When it is positive, `Do` must not start a sleep that
      would end more than `MaxElapsed` after the first attempt began; it
      returns an `*ExhaustedError` for the attempts made so far instead, at
      once, without sleeping first. Zero means no limit.
    ],
    hint: [You know the delay before you sleep. Test in a bubble, where "returned without sleeping" can be checked exactly.],
    tests: "workbook/ch04/exercises/ex5",
  ),
  (
    tier: "core",
    title: [Why `consumerGone`?],
    body: [
      Delete the `case <-consumerGone:` line from the worker's `select` in
      `conc.Stream` and run the package's tests. Which test fails, how, and
      why? Explain which goroutines are stuck and on what, and why the parent
      context's cancellation doesn't free them. Then explain why the fix is
      a separate channel instead of `ctx.Done()`.
    ],
    hint: [Read the goroutine states in the panic: `chan send` and `sync.WaitGroup.Wait`. Who would receive?],
  ),
  (
    tier: "stretch",
    title: [Ordered streaming],
    body: [
      Write `conc.StreamOrdered`, with `Stream`'s signature and behaviour
      except that results come out in input order: each one as soon as every
      result before it has been yielded, while calls still run concurrently.
      Memory must stay bounded: at most `limit` calls may be running or
      finished but not yet yielded, so one slow first item makes the stream
      wait rather than buffer the whole input. Early `break` and parent
      cancellation behave as for `Stream`.
    ],
    hint: [Give each call its own one-slot result channel, and queue those channels in input order. When is a slot really free?],
    tests: "workbook/ch04/exercises/ex7",
  ),
)
