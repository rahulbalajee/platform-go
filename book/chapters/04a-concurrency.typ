#import "../template/book.typ": *
#import "04-lib.typ": ts, needspace

#chapter(4, "Concurrency Patterns for Production Tooling", label: <ch-concurrency>,
  abstract: [
    Platform tools spend most of their lives waiting on APIs, sockets, disks,
    and other people's clusters. Go makes it trivial to wait on a thousand
    things at once. It makes it just as easy to leak goroutines, take down a
    dependency with your own retries, or turn #kbd("Ctrl-C") into a
    half-finished deploy. In this chapter you build a fleet checker from an
    empty directory, one working step at a time, and you meet each
    concurrency tool at the moment the program needs it.
  ],
  learn: (
    [Goroutines, channels, `WaitGroup` and `select`, and the rule that every goroutine has an owner and an exit],
    [Context trees, deadlines, and cancellation _causes_],
    [Bounded parallelism, and streaming results behind a generic iterator],
    [Interfaces and adapters for pluggable checks; `singleflight` for shared lookups],
    [Rate limits, per-host limits, and retries with full jitter],
    [Two-stage graceful shutdown, deterministic tests with `testing/synctest`, and finding leaks],
    [How the scheduler runs goroutines, and why Go 1.25 changed the defaults inside containers],
  ),
  build: [
    *`sweep`*, a CLI that checks hundreds of HTTP, TCP, TLS, and DNS targets
    concurrently with global and per-host limits, rate limiting, retries,
    streaming output, and clean #kbd("Ctrl-C") handling, in seven steps.

    #v(4pt)
    Three reusable packages that later chapters build on: *`conc`*,
    *`retry`*, and *`lifecycle`*. The last step is the production code in
    the book's repository.
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

The first concurrent version every Go programmer writes looks like this:

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

This chapter fixes each of these, in order, by building the tool. Along the way
it extracts three reusable packages, because every project later in the book
(the deployment CLI, the operator, the monitoring agent, the AI investigator)
has the same needs.

== What we're building <sec-building>

`sweep` reads an inventory of targets, one per line, checks them all, prints a
report, and sets its exit status so that a CI job can gate a release on it.
Here is the finished tool, built in step 7, against a fake fleet that runs on
your machine plus a few real hosts on the internet:

#output("ch04/s7-tour-cat.txt", cmd: "cat tour.txt")
#output("ch04/s7-tour.txt", cmd: "./sweep -timeout 2s tour.txt; echo \"exit status $?\"")

The table goes to standard output and the summary line to standard error, so a
script can pipe one and log the other. The `TRIES` column shows the retry
policy at work: the flaky endpoint answered on its third try, the endpoint
returning 503 was tried three times and given up on, and the 404, the expired
certificate and the name that does not exist were tried once each, because
retrying them would be pointless. The whole run took about as long as its
slowest target, not the sum of all ten.

@fig-sweep shows the pieces and the order in which a check passes through
them. Each piece arrives in one build step.

#fig(caption: [The finished `sweep`. A check passes the limits in a fixed order: global concurrency, a per-host slot, then a rate-limit token per attempt. The dashed arrow from `lifecycle` is cancellation. The numbers are the build steps that add each piece.])[
  #diagram(
    spacing: (30pt, 9pt),
    dnode((0, 0), [inventory file / stdin], kind: "muted"),
    dnode((0, 1), [`ParseTargets` · all errors, line numbers #h(2pt) *1*], kind: "default"),
    dnode((0, 2), [`conc.Stream` · ≤ `-c` checks in flight #h(2pt) *2, 3*], kind: "dark"),
    dnode((0, 3), [`KeyedSemaphore` · ≤ `-per-host` per host #h(2pt) *5*], kind: "accent"),
    dnode((0, 4), [`retry.Policy.Do` · full jitter, Retry-After #h(2pt) *5*], kind: "accent"),
    dnode((0, 5), [`rate.Limiter.Wait` · every attempt #h(2pt) *5*], kind: "accent"),
    dnode((0, 6), [attempt context · `-timeout`, cause #h(2pt) *2*], kind: "default"),
    dnode((0, 7), [`Prober`: HTTP · TCP · TLS · DNS #h(2pt) *1, 4*], kind: "default"),
    dnode((1, 2), [`range` loop (single owner)\ → Summary + Reporter #h(2pt) *6*], kind: "dark"),
    dnode((1, 3), [stdout: table · wide · json · jsonl\ stderr: summary · exit status], kind: "muted"),
    dnode((1, 0), [`lifecycle.NotifyContext`\ two-stage #kbd("Ctrl-C") #h(2pt) *7*], kind: "warn"),
    dnode((1, 7), [`CachingResolver`\ TTL + singleflight #h(2pt) *4*], kind: "good"),
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
    dedge((1, 0), (0, 2), "--|>"),
    dedge((0, 7), (1, 7), "-|>", label: [lookups]),
    dedge((1, 7), (1, 8), "-|>"),
  )
] <fig-sweep>

=== The plan

You build `sweep` in seven steps. Each one ends with a program that compiles,
passes its tests, and does something you can see.

#table(
  columns: (auto, 1.25fr, 1fr),
  table.header([Step], [What it adds], [Go you meet there]),
  [1 #h(3pt) A sequential checker], [Inventory parsing with line numbers, one HTTP check at a time, exit statuses, an end-to-end test], [modules and `internal/`, `net/http`, `defer`, `context` deadlines, `time.Duration`, `flag`],
  [2 #h(3pt) Checking concurrently], [A goroutine per target, results streamed over a channel, timeouts with causes, #kbd("Ctrl-C")], [goroutines, channels, `select`, `sync.WaitGroup`, closures, `testing/synctest`, `-race`, goleak],
  [3 #h(3pt) Bounded and streaming], [`conc.Map` and `conc.Stream`, the `-c` limit], [generics, iterators and range over func, `errgroup`, `errors.Join`],
  [4 #h(3pt) One interface, four probers], [TCP, TLS and DNS checks, a caching resolver], [interfaces, function types as adapters, `sync.Mutex`, `singleflight`],
  [5 #h(3pt) Politeness and retries], [Per-host limits, a rate limit, retries with full jitter and `Retry-After`], [`errors.Is`, `As` and `AsType`, generic methods, `golang.org/x/time/rate`],
  [6 #h(3pt) Reports], [Table, wide, JSON and JSON Lines output; the summary], [struct tags, `encoding/json`, `text/tabwriter`, ownership instead of locks],
  [7 #h(3pt) Shutdown in two stages], [A second #kbd("Ctrl-C") that forces exit, `-deadline`, `-version`], [`os/signal`, `os.Exit` and `defer`],
)

After the build, two deep dives cover what doesn't fit inside a step: how the
runtime schedules goroutines (@sec-scheduler), and how to find concurrency bugs
in a running process (@sec-diagnosing).

=== How to work through the steps

Every step lists the files to create or the functions to replace, in full. Type
them (copying teaches less than typing), run the checkpoint commands at the
end of the step, and compare your output with the book's. Timings and the
order of concurrent results will differ from run to run; everything else
should match. If it doesn't, the troubleshooting table under each checkpoint
lists failures we produced on purpose by breaking a copy of that step, with the
exact message each one prints.

If you get stuck, the repository has every step as a complete module under
`workbook/ch04/step1` to `step7`, and each one passes `go vet`, `go test
-race` and `golangci-lint`. Diff your directory against the step you are on.
The last step is not a toy: the repository's `pkg/conc`, `pkg/retry`,
`pkg/lifecycle`, `internal/sweep` and `cmd/sweep` are the same files with
longer import paths, and a check in CI keeps them identical.

You need Go 1.27, the `golangci-lint` setup from Chapter 1, two terminal
windows, network access in step 4, and `jq` in step 6.

#step(1, 7, "A sequential checker", label: <sec-step-seq>)

The first version does everything the final one does except the interesting
parts. It reads an inventory, checks each HTTP target in turn with a timeout,
prints one line per target, and exits with a status CI can act on. Every
later step changes this program; none replaces it.

Start with an empty module:

#session(
  ("mkdir sweep && cd sweep", none),
  ("go mod init sweep", "ch04/s1-modinit.txt"),
  ("go get go@1.27.0", "ch04/s1-goget.txt"),
)

`go mod init` writes the exact version of the toolchain you ran into the `go`
line of `go.mod`. That line is the _minimum_ Go version the module needs, so
`go get go@1.27.0` lowers it to the first 1.27 release: anyone with any Go
1.27 can build `sweep`. The module path is plain `sweep`, because this is a
program, not a library anyone will import. Packages inside the module are
imported as `sweep/...`.

The layout follows Chapter 1's conventions: one directory per binary under
`cmd/`, and the code that does the work in `internal/sweep`, where no other
module can import it.

=== Something to sweep

You need targets that behave badly on demand, and pointing a new tool at
production is a bad way to find out how it fails. `cmd/fleet` is a tiny HTTP
server with one path per behaviour. Create `cmd/fleet/main.go`:

#src("workbook/ch04/step1/cmd/fleet/main.go")

Two details are worth reading now and returning to later. `handle` is a
_closure_: a function value that captures `mux` from the surrounding scope, so
each handler it registers logs its own pattern. And `flakyCalls` is an
`atomic.Int64`, a counter that is safe to update from many goroutines at once,
which matters because the HTTP server runs every request on its own goroutine.
Step 2 introduces goroutines and step 4 the `sync` and `sync/atomic` packages.

#goconcept(title: [Closures])[
  A function literal can use variables from the function around it, and it
  keeps them alive for as long as the literal exists:
  `count := 0; inc := func() { count++ }`. Each call to `inc` changes the same
  `count`. JavaScript and Python closures behave the same way. Closures are how
  Go passes behaviour around: HTTP handlers, the `check` helper in step 3's
  `NewRunner`, and every function you hand to a goroutine. The trap is sharing:
  if two goroutines run closures over the same variable, they share it, and
  you need the synchronization step 2 introduces.
]

=== Parsing the inventory

An inventory is a text file with one target per line, comments starting with
`#`, and blank lines for readability. The parser lives in
`internal/sweep/target.go`. Start the file with the package, the `Kind` of a
target and the `Target` type itself:

#src("workbook/ch04/step1/internal/sweep/target.go", region: "head")

Only HTTP exists for now; step 4 adds TCP, TLS and DNS. `Index` remembers where
a target appeared in the file, which matters once results arrive out of order.
Next, the parser:

#src("workbook/ch04/step1/internal/sweep/target.go", region: "parse")

`ParseTargets` takes an `io.Reader`, so it reads files, standard input and
strings in tests with the same code. It does not stop at the first bad line.
It collects every error with its line number and reports them together,
because someone fixing a 400-line inventory wants one list of mistakes, not
seventeen runs. The function that parses one line goes at the end of the file:

#src("workbook/ch04/step1/internal/sweep/target.go", region: "parse1")

The port check is there because `url.Parse` accepts any run of digits as a
port, including `99999`. It was not in the first version of this parser:
Chapter 6 shows the fuzz test that found the gap.

=== Checking one HTTP target

`internal/sweep/probe.go` holds the code that talks to the network. For now
that is one type, `HTTPProber`:

#src("workbook/ch04/step1/internal/sweep/probe.go")

The request is built with `http.NewRequestWithContext`, so whatever deadline or
cancellation `ctx` carries applies to the whole exchange: connecting, sending,
and waiting for the response. The client has no `Timeout` of its own, and the
comment on the field says why: deadlines come from the context, and a second,
competing timeout would only produce confusing errors.

#goconcept(title: [`http.Client`])[
  `http.Client` sends requests and follows redirects; its `Transport` keeps a
  pool of open connections and reuses them. Create one client and share it,
  because a new client per request throws the pool away. A response's `Body` is
  a stream you must close, or the connection it holds is never returned to the
  pool. The `bodyclose` linter from Chapter 1 checks this for you. Status codes
  are data, not errors: a 404 or 503 comes back with `err == nil`, and only
  network-level failures (refused, reset, timed out) return an error.
]

#goconcept(title: [`defer`])[
  `defer f()` schedules `f` to run when the surrounding function returns, by
  any path: a normal return, an early return on error, or a panic. Deferred
  calls run last in, first out. Use it to pair every acquire with its release
  right where you acquire: `resp, err := client.Do(req)`, check `err`, then
  `defer resp.Body.Close()`. Two traps: `defer` runs at function exit, not at
  the end of a loop iteration, and `os.Exit` skips deferred calls entirely
  (step 7 deals with that). Python's `with` and Java's try-with-resources solve
  the same problem.
]

Reading up to 64 KiB of the body before closing it lets HTTP/1.1 reuse the
connection, which matters when 300 targets sit behind one load balancer. Go
1.27 drains unread bodies on `Close` automatically, up to a conservative limit;
draining explicitly keeps the behaviour the same on older toolchains and makes
the intent visible.

=== The runner

`internal/sweep/runner.go` turns targets into results. Start with the result
type:

#src("workbook/ch04/step1/internal/sweep/runner.go", region: "types")

A `Result` is plain data: what was checked, how it went, how long it took, and
a short detail. `Status` is a `string` type with named constants, so a typo such
as `Status("dwon")` stands out in review and a `switch` can list the cases.
Next, the configuration and the constructor:

#src("workbook/ch04/step1/internal/sweep/runner.go", region: "config")

`NewRunner` validates its input and returns an error instead of a half-working
value, so a zero or negative timeout is reported at startup, not as a mystery
later. Then the method that runs a sweep, one target after another:

#src("workbook/ch04/step1/internal/sweep/runner.go", region: "run")

And the check itself:

#src("workbook/ch04/step1/internal/sweep/runner.go", region: "check")

`context.WithTimeout` derives a context that expires after `r.cfg.Timeout`;
the HTTP request built from it is abandoned at that moment. The `defer
cancel()` releases the timer as soon as the check finishes rather than when
the timeout would have fired.

#goconcept(title: [`context.Context`])[
  A `context.Context` carries a deadline, a cancellation signal, and a few
  request-scoped values across API boundaries. By convention it is the first
  parameter of anything that blocks or does I/O, named `ctx`. You never modify
  a context; you derive a child from it with `context.WithTimeout`,
  `WithDeadline` or `WithCancel`, and each of those returns a `cancel` function
  that you must call, usually with `defer`. When a context is done, `ctx.Done()`
  is closed and `ctx.Err()` says why. Step 2 builds on this.
]

#goconcept(title: [`time.Duration`])[
  `time.Duration` is an `int64` count of nanoseconds with a type of its own,
  so `5*time.Second` and `200*time.Millisecond` read naturally and a bare `5`
  can't sneak in where seconds were meant. `time.Since(start)` returns a
  `Duration`, `d.Round(time.Millisecond)` rounds it for display, and the `flag`
  package parses values such as `2s` or `1m30s` straight into one.
]

=== The command

`cmd/sweep/main.go` is the program's entry point. It starts with the package
documentation, the imports, the exit statuses and `main`:

#src("workbook/ch04/step1/cmd/sweep/main.go", region: "head")

The exit statuses are the tool's contract with every script that runs it: 0
means all targets are up, 1 means at least one is down, 2 means the tool could
not do its job (bad flags, bad inventory). A CI step fails on any non-zero
status, and a human can tell the difference between "the fleet is unhealthy"
and "you typed the flag wrong". `version` is a variable rather than a constant
so a release build can stamp it with `-ldflags` (Chapter 1).

Flags are parsed into a small struct by their own function:

#src("workbook/ch04/step1/cmd/sweep/main.go", region: "flags")

`flag.ContinueOnError` makes `Parse` return an error instead of exiting the
process, which is what lets the tests below call the parser. Each later step
adds a field to `options` and a line to `parseFlags`, and nothing else in this
part of the file has to change.

`main` does almost nothing. The work happens in `run`, which takes its
arguments, input and output streams as parameters and returns an exit status:

#src("workbook/ch04/step1/cmd/sweep/main.go", region: "run")

Because `run` never calls `os.Exit` and never touches `os.Stdout` directly, a
test can call it with fake arguments and buffers and check the status and the
output. That shape (a tiny `main`, a testable `run`) is the one Chapter 1
recommended for every binary. The output helper prints one line per result:

#src("workbook/ch04/step1/cmd/sweep/main.go", region: "print")

Finally, reading the inventory, from named files or standard input, and
building the runner:

#src("workbook/ch04/step1/cmd/sweep/main.go", region: "read")
#src("workbook/ch04/step1/cmd/sweep/main.go", region: "newrunner")

`readTargets` opens every file before parsing and joins them with
`io.MultiReader`, so `sweep a.txt b.txt` is one inventory and line numbers keep
counting across files. The `defer f.Close()` inside the loop is one of the few
places where deferring in a loop is right: every file must stay open until
`ParseTargets` has read them all.

=== Tests

Two test files pin the behaviour down. `internal/sweep/runner_test.go` runs the
runner against a local HTTP server from `net/http/httptest` and checks that the
parser reports every error:

#src("workbook/ch04/step1/internal/sweep/runner_test.go")

`TestRunnerOutcomes` takes about 200 milliseconds of real time, because the
`/slow` handler really does wait for the client's deadline. Step 2 removes that
cost. `cmd/sweep/main_test.go` drives `run` end to end, from an inventory file
on disk to the exit status:

#src("workbook/ch04/step1/cmd/sweep/main_test.go")

#needspace(12em)
#checkpoint(step: 1, of: 7, title: [A sequential checker])[
  Your module should contain these Go files:
  #output("ch04/s1-tree.txt", cmd: "find . -name '*.go' | sort")
  Vet and test it:
  #output("ch04/s1-test.txt", cmd: "go vet ./... && go test ./...")
  Start the fake fleet in a second terminal and leave it running. It prints
  one line when it starts listening, then one per request it answers.
  Create `fleet.txt` with this content, then sweep it:
  #output("ch04/s1-cat.txt", cmd: "cat fleet.txt")
  #output("ch04/s1-run.txt", cmd: "go run ./cmd/sweep -timeout 2s fleet.txt", size: 6.6pt)
  The two `/slow` targets each used their full two seconds, one after the
  other, so the sweep took four. `go run` reports the program's non-zero exit
  status on its last line. Meanwhile the fleet logged the requests, one after
  another; `/missing` has no handler, so it isn't logged:
  #output("ch04/s1-fleet.txt", cmd: "go run ./cmd/fleet", title: "terminal 2")
  An inventory with mistakes is rejected before any target is contacted,
  with every mistake listed:
  #output("ch04/s1-catbad.txt", cmd: "cat bad.txt")
  #output("ch04/s1-bad.txt", cmd: "go run ./cmd/sweep bad.txt")
  #troubleshoot(
    ([#ts("s1-nofleet.txt")], [The fake fleet is not running, so every connection is refused.], [Start `go run ./cmd/fleet` in a second terminal.]),
    ([#ts("s1-modpath.txt")], [The module path in `go.mod` is not `sweep` (here `go mod init github.com/you/sweep`), so `sweep/internal/sweep` matches no package and Go looks for it in the standard library.], [Make the `module` line and the import paths agree.]),
    ([#ts("s1-bodyclose.txt")], [`defer resp.Body.Close()` is missing; each check leaks a connection.], [Add it right after the error check on `Do`. See "Checking one HTTP target".]),
    ([#ts("s1-assign.txt")], [`=` where `:=` was needed: `cancel` is a new variable, so it must be declared.], [Use `ctx, cancel := context.WithTimeout(...)`.]),
    ([#ts("s1-unused.txt")], [An import the file no longer uses. Go refuses to compile unused imports.], [Delete the import, or let `goimports` manage the block.]),
  )
]

#step(2, 7, "Checking concurrently", label: <sec-step-conc>)

Step 1 took four seconds for five targets because it waited for each one in
turn. With 300 targets and a few slow ones, that is minutes. The checks are
independent, so the fix is to run them at the same time. This step does that
with the three basic tools of concurrent Go, then makes the result safe to
interrupt.

#goconcept(title: [Goroutines])[
  `go f(x)` starts `f(x)` running concurrently and returns immediately. The new
  _goroutine_ is a function call with its own small stack, scheduled by the Go
  runtime onto operating system threads. Starting one costs about as much as a
  small allocation, so a program can run thousands. Two things catch
  newcomers. The program exits when `main` returns, whether or not other
  goroutines have finished. And a goroutine has no handle: you cannot ask it
  for its result or stop it from outside, so you arrange both yourself, with a
  channel and a context. @sec-scheduler explains how the runtime runs them.
]

#goconcept(title: [Channels and `select`])[
  A channel is a typed pipe between goroutines: `ch := make(chan Result)`,
  `ch <- r` sends, `r := <-ch` receives. An _unbuffered_ channel makes the sender
  wait until a receiver takes the value, so a send is also a handoff;
  `make(chan T, n)` gives a buffer of `n`. `close(ch)` says no more values
  will come, and `for r := range ch` reads until then. Sending on a closed
  channel panics, so only the sender may close it. `select` waits on several
  channel operations and runs whichever is ready first:
  `select { case r := <-results: ...; case <-ctx.Done(): ... }`. If several are
  ready, it picks one at random.
]

#goconcept(title: [`sync.WaitGroup`])[
  A `WaitGroup` counts goroutines that have not finished yet. `Add(n)` raises
  the count, `Done()` lowers it, and `Wait()` blocks until it reaches zero.
  Go 1.25 added `wg.Go(f)`, which does `Add(1)`, starts `f` in a goroutine,
  and calls `Done` when `f` returns. Prefer it: the classic bug of calling
  `Add` inside the new goroutine, where it can run after `Wait`, can't happen.
  Since Go 1.22 each loop iteration has its own copy of the loop variable, so
  `for _, t := range targets { wg.Go(func() { check(t) }) }` captures each `t`
  correctly.
]

=== Rule zero: every goroutine has an owner and an exit

The single most useful discipline in concurrent Go is borrowed from
_structured concurrency_: a function that starts goroutines must not return
until those goroutines have finished, or must hand them to someone who will
wait for them. Callers then never have to wonder what is still running in the
background. Every helper in this chapter keeps that contract, and it is the
first thing to check in code review.

Two habits make it easy to keep. Pair every `go` with a wait, using a
`WaitGroup`. And let the sender close the channel: a channel should have
exactly one owner that closes it, the side that sends. If several goroutines
send, none of them can close it safely, so a coordinating goroutine waits for
all of them and then closes.

Here is the new `Run`. Replace the old one in `runner.go`:

#src("workbook/ch04/step2/internal/sweep/runner.go", region: "run")

Each target gets a goroutine that sends its result on `results`. A separate
goroutine waits for all of them and then closes the channel, which ends the
caller's `for range` loop. `Run` itself returns at once, before any check has
finished; the results arrive on the channel as each one completes, so the
caller can print them as they come.

This version breaks rule zero by design: the goroutines outlive `Run`. They
finish only when the caller has read every result. If the caller stops reading
early, every goroutine that has not sent yet blocks forever on `results <-`,
holding its memory and everything it references. The checkpoint shows that
leak being caught, and step 3 replaces this function with one that cannot
leak.

=== Context: the cancellation tree

Step 1 used a context for one timeout. Its real job is to carry cancellation
through a whole program. Contexts form a tree: cancelling a node cancels
everything below it and nothing above it. So each operation can have its own
limits while still responding to the global ones. @fig-context-tree is the
tree `sweep` has by the end of the chapter; this step builds its top and
bottom layers.

#fig(caption: [The context tree in the finished `sweep`. Each layer adds one reason to stop. The shared DNS lookup (step 4) is deliberately detached from any single caller.])[
  #diagram(
    spacing: (14pt, 14pt),
    dnode((1, 0), [`lifecycle.NotifyContext`\ cancelled on SIGINT / SIGTERM · cause `*SignalError`], kind: "dark"),
    dnode((1, 1), [`WithTimeoutCause(-deadline)`\ cause: "sweep deadline exceeded"], kind: "accent"),
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
  loop is a leak. `go vet` reports a `cancel` you discard.
+ Check `ctx.Err()` before starting expensive work, and `select` on
  `ctx.Done()` wherever you block on something that doesn't take a context.

==== Causes: saying _why_ you stopped

`ctx.Err()` only ever returns `context.Canceled` or
`context.DeadlineExceeded`. For a tool, that loses the most important
information. Did the user press #kbd("Ctrl-C")? Did this one check exceed its
own timeout? The `Cause` family (Go 1.20 and 1.21) answers that:
`context.WithTimeoutCause(parent, d, cause)` records `cause` when the timer
fires, and `context.Cause(ctx)` returns it. Here is the check with causes.
Replace `check` in `runner.go`, and add the variable and helper that come
with it:

#src("workbook/ch04/step2/internal/sweep/runner.go", region: "check")

The `switch` reads as a decision table. If the probe succeeded, the target is
up. If the _parent_ context is done, the whole run is being cancelled, and the
result says `cancelled` with the parent's cause; blaming the target would be
wrong. If this check's own timer fired, the target is down with a short, exact
message instead of Go's `context deadline exceeded`. Anything else is the
probe's own error. `errors.Is` compares errors through any wrapping; step 5
covers it properly.

The new status and imports go at the top of the file:

#src("workbook/ch04/step2/internal/sweep/runner.go", region: "imports")
#src("workbook/ch04/step2/internal/sweep/runner.go", region: "status")

==== Three context functions worth knowing

`context.WithoutCancel(ctx)` (Go 1.21) returns a child that keeps the parent's
values but is never cancelled by it. Use it for work that must finish even if
the request that triggered it goes away, such as writing an audit record after
a deployment request is cancelled, or a lookup shared by many callers (step 4).
Always give the detached work its own timeout, or you have built a leak.

`context.AfterFunc(ctx, f)` (Go 1.21) runs `f` in its own goroutine when `ctx`
is done. It is the clean way to make a blocking call that doesn't take a
context respond to cancellation, for example by closing a connection to
unblock a `Read`:

#code(file: "afterfunc.go")[```go
stop := context.AfterFunc(ctx, func() { conn.Close() }) // unblocks Read on cancel
defer stop()
n, err := conn.Read(buf)
```]

`t.Context()` (Go 1.24) gives every test a context that is cancelled just
before the test's cleanup functions run. The tests in this chapter use it
instead of `context.Background()`, so goroutines started by the code under test
get a stop signal.

=== #kbd("Ctrl-C") becomes a context

The root of the tree is a context that the operating system's signals cancel.
`signal.NotifyContext` provides one. Replace the top of `main.go`, from the
package comment through `main`:

#src("workbook/ch04/step2/cmd/sweep/main.go", region: "head")

#newingo("1.26", title: [Signal contexts carry the signal])[
  `signal.NotifyContext` cancels its context with a cause that names the
  signal received, so `context.Cause(ctx)` reports `interrupt signal received`
  rather than a bare `context canceled`. Step 7 replaces it with a wrapper
  that also handles a second #kbd("Ctrl-C").
]

`run` changes in its loop and its ending. Replace it:

#src("workbook/ch04/step2/cmd/sweep/main.go", region: "run")

The loop reads `for res := range runner.Run(ctx, targets)` now, without the
index, because ranging over a channel yields one value per receive. When the
user presses #kbd("Ctrl-C"), the root context is cancelled, every in-flight
check sees its parent context end and reports `cancelled`, the channel closes,
and `run` prints a summary that says so and returns 130. That is
128 plus the signal number of `SIGINT`, the status shells use for a process
interrupted by #kbd("Ctrl-C"), so a CI system can tell "interrupted" from
"unhealthy".

=== Tests that don't wait

The runner test from step 1 waited 200 milliseconds of real time for a
timeout. A test of concurrent checks with realistic timeouts would wait
seconds, and a test with short timeouts would be flaky on a busy CI machine.
Go has a better answer.

#newingo("1.25", title: [`testing/synctest`: virtual time for tests])[
  `synctest.Test(t, f)` runs `f` in an isolated _bubble_. Inside it, the `time`
  package uses a fake clock that starts at midnight UTC on 2000-01-01 and only
  moves when every goroutine in the bubble is _durably blocked_: waiting on a
  channel, timer, `select`, `sync.Cond` or `WaitGroup` that belongs to the
  bubble. The clock then jumps straight to the next timer that would unblock
  something. A test with a two-second timeout finishes in microseconds and
  measures exactly two seconds. `synctest.Wait()` blocks until every other
  goroutine in the bubble is durably blocked, which lets a test assert that
  something _is_ waiting without sleeping and hoping. Production code needs no
  changes.
]

#newingo("1.27", title: [In-memory networks for synctest])[
  Real sockets are not durably blocking, because a packet from outside the
  bubble could wake them, so `synctest` alone can't virtualize an HTTP round
  trip. Go 1.27 adds `httptest.NewTestServer`, which creates a test server on
  an in-memory network. Its `Client()` talks to that network, so server
  handlers that sleep for ten seconds, clients that time out after two, and
  retries with backoff all run in virtual time. Go 1.27 also adds
  `synctest.Sleep(d)`, shorthand for `time.Sleep(d)` followed by
  `synctest.Wait()`.
]

`runner_test.go` changes almost completely. Replace everything from the
package clause down to the `targets` helper, which stays, with the new
imports and a fake fleet like `cmd/fleet` that runs on the in-memory network:

#src("workbook/ch04/step2/internal/sweep/runner_test.go", region: "imports")
#src("workbook/ch04/step2/internal/sweep/runner_test.go", region: "fixture")

`track` wraps every handler and records the highest number of requests the
fleet ever served at once, using atomic operations because handlers run on
many goroutines. Then add a helper that builds a runner for that fleet, just
above the `targets` helper from step 1:

#src("workbook/ch04/step2/internal/sweep/runner_test.go", region: "helpers")

After `targets`, replace step 1's `TestRunnerOutcomes`. The new version runs
in a bubble and asserts something step 1 could not: that the sweep took
exactly as long as its slowest check.

#src("workbook/ch04/step2/internal/sweep/runner_test.go", region: "outcomes")

Two more tests pin down cancellation and concurrency. `time.AfterFunc` plays
the user pressing #kbd("Ctrl-C") three seconds in; in virtual time, "three
seconds" is exact.

#src("workbook/ch04/step2/internal/sweep/runner_test.go", region: "cancel")
#src("workbook/ch04/step2/internal/sweep/runner_test.go", region: "limit")

`TestParseTargetsReportsAllErrors` stays as it was. Leaks need a separate
check, because a leaked goroutine fails no assertion. `go.uber.org/goleak`
compares the goroutines alive at the end of the package's tests with those
alive at the start and fails if anything new is still running. Add it to the
module, then create `internal/sweep/main_test.go`:

#session(
  ("go get go.uber.org/goleak@v1.3.0", "ch04/s2-goget.txt"),
  ("go mod tidy", "ch04/s2-tidy.txt"),
)
#src("workbook/ch04/step2/internal/sweep/main_test.go")

`go get` records the new requirement, and `go mod tidy` marks it as a direct
dependency once it sees the import. That one `TestMain` turns rule zero from
a convention into an enforced property of the package. Finally, add the
interrupted case to `cmd/sweep/main_test.go`, along with the `context` import:

#src("workbook/ch04/step2/cmd/sweep/main_test.go", region: "imports")
#src("workbook/ch04/step2/cmd/sweep/main_test.go", region: "interrupted")

Run the tests with the race detector at least once per step, and always in CI.
It instruments every memory access and reports two goroutines touching the
same variable without synchronization, if your tests make that happen. It
costs several times more CPU and memory, so it stays out of production builds.

#needspace(12em)
#checkpoint(step: 2, of: 7, title: [Checking concurrently])[
  #output("ch04/s2-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch04/s2-test.txt", cmd: "go vet ./... && go test ./...")
  The internal tests now take well under a second, although they cover
  timeouts of two seconds and more. With the fleet still running in the second
  terminal:
  #output("ch04/s2-run.txt", cmd: "go run ./cmd/sweep -timeout 2s fleet.txt")
  Results arrive in the order the checks finish, and the sweep takes as long as
  the slowest target: two seconds instead of four. Now build the binary, run it
  with the default five-second timeout, and press #kbd("Ctrl-C") after about a
  second:
  #session(
    ("go build -o sweep ./cmd/sweep", "ch04/s2-build.txt"),
    ("./sweep fleet.txt", "ch04/s2-ctrlc.txt"),
    ("echo $?", "ch04/s2-ctrlc-status.txt"),
  )
  The two slow checks report the signal as their cause. (`CANCELLED` is wider
  than the status column; step 6 replaces this output with a proper table.)
  #troubleshoot(
    ([#ts("s2-nowait.txt")], [`close(results)` ran without `wg.Wait()` first, so a check sent on a closed channel.], [Close only after `Wait`. See "Rule zero".]),
    ([#ts("s2-noclose.txt")], [Nobody closes `results`, so the caller's `range` waits forever. In a bubble, `synctest` detects it; the real binary just hangs.], [Close the channel in the goroutine that waits.]),
    ([#ts("s2-addinside.txt")], [`wg.Add(1)` inside the goroutine, where it can run after `Wait`. `go vet` catches it.], [Use `wg.Go`, or call `Add` before `go`.]),
    ([#ts("s2-race.txt")], [Two goroutines update the same variable (here a progress counter on the `Runner`) with no synchronization. Only `-race` notices.], [Count in the goroutine that reads `results`, or use `atomic.Int64`.]),
    ([#ts("s2-leak.txt")], [The caller stopped reading early, so senders block forever. goleak names the stuck line.], [Read every result, or wait for step 3's `Stream`.]),
    ([#ts("s2-bubbleleak.txt")], [The same leak inside a `synctest` bubble: the bubble refuses to end with blocked goroutines.], [As above.]),
  )
]
