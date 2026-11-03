#import "../template/book.typ": *

// A troubleshooting row quotes the first lines of a real failure that
// book/scripts/capture-ch06.sh produced by breaking a copy of a lab snapshot.
#let ts(name) = quote-output("ch06/ts/" + name)

#chapter(6, "Testing Tools That Touch the Real World", label: <ch-testing>,
  abstract: [
    Platform tools are mostly side effects: they dial sockets, read files a
    human wrote, print tables a human reads and JSON a pipeline parses, exit
    with a status that decides whether a release ships, and react to
    #kbd("Ctrl-C"). Each of those is a contract, and each is easy to break
    without noticing. In nine labs you give `sweep`, the fleet checker you
    built in Chapter 4, the test suite a tool like it deserves: table tests,
    fakes, golden files, the real binary under real signals, fuzzing,
    benchmarks, merged coverage, flaky-test forensics and real containers.
    Along the way you put back two bugs a fuzzer once found, and watch it
    find them again.
  ],
  learn: (
    [Where the seams are in a tool that touches networks, clocks, files and processes, and what each layer of the test pyramid buys you],
    [Table-driven tests that read well and fail clearly, and the `testing` features added in Go 1.24 to 1.27],
    [Fakes over mocks, interfaces at the consumer, and when a mocking library is worth it],
    [Golden files with `-update`, and how to keep them deterministic],
    [End-to-end tests of the real binary with `testscript`: exit codes, stdout and stderr, stdin, signals],
    [Fuzzing, benchmarking with `b.Loop` and `benchstat`, and integration coverage with `GOCOVERDIR`],
    [Why tests become flaky, how to catch it, and how to tier a CI pipeline],
    [Real dependencies with `testcontainers-go`, without depending on a registry],
  ),
  build: [
    A complete test suite for *your own `sweep`* from Chapter 4, added in
    nine labs without changing a line of the tool itself: unit, fake-driven,
    golden, end-to-end, fuzz, benchmark and container tests, with coverage
    merged across all of them. The last lab's tests are the ones the book's
    repository runs against its production `sweep`.

    #v(4pt)
    *`sweeptest`*, a fake fleet of HTTP endpoints in the spirit of
    `net/http/httptest`, reused by the unit tests, the end-to-end scripts and
    the golden test of the whole command.
  ],
)

== Tools that touch the real world <sec-test-real-world>

`sweep` started life in Chapter 4 as a fleet checker. By the end of that
chapter it had become something more dangerous: a deploy gate. A pipeline
step runs `sweep staging.txt`, and exit status 0 promotes the build. If a
refactor makes `sweep` exit 0 when a target is down, bad releases ship. If it
exits 1 because someone typed a port wrong in the inventory, good releases
are blocked and people learn to skip the gate. Neither failure shows up in a
code review.

Chapter 4 tested the concurrency: the runner's retry and timeout behaviour
in a `synctest` bubble, the two-stage signal handler, and the `run` function
against real sockets. That leaves most of what users and pipelines actually
depend on untested. The table layout and the JSON schema are not pinned. The
real binary has never been run with a real signal. Nobody has fed the
inventory parser anything nasty. Nobody knows what fraction of the code the
end-to-end path exercises.

Tools are hard to test because almost everything they do touches something
outside the process. @tab-test-seams lists what `sweep` touches, the seam
that lets a test take control of it, and the lab that uses it.

#figure(
  table(
    columns: (auto, 1fr, 1fr),
    table.header([The world], [Seam in `sweep`], [Technique (lab)]),
    [Network], [The one-method `Prober` interface; an injected `*http.Client` and dial function], [Hand-written fakes and the `sweeptest` fake fleet (2), containers (9)],
    [Clock], [None needed: timers and sleeps go through the `time` package], [`testing/synctest` bubbles (Chapter 4, Lab 2)],
    [Filesystem], [Inventory paths come from arguments; output goes to an `io.Writer`], [`t.TempDir`, `t.Chdir`, golden files (3)],
    [Process], [`run(ctx, args, stdin, stdout, stderr) int` instead of `os.Exit` in `main`], [Calling `run` directly (3); `testscript` against the built binary (4)],
    [Signals], [`lifecycle.NotifyContext` turns signals into a context cause], [A real `SIGINT` from a test script (4)],
    [Human input], [`ParseTargets` takes an `io.Reader`; `parseRetryAfter` takes a string], [Table tests (1), fuzzing (5)],
    [Real services], [Probers dial real addresses], [`testcontainers-go` (9)],
  ),
  caption: [What `sweep` touches, and how its tests take control.],
  kind: table,
  placement: auto,
) <tab-test-seams>

Every row has the same shape. Production code takes the dependency as a
parameter (an interface, a writer, a context, a list of arguments) instead
of reaching for a global, and the test passes something it controls. When
code does reach for a global (`os.Args`, `os.Stdout`, `time.Now`,
`http.DefaultClient`), the test has to fight it with environment hacks or
not test it at all. Chapter 4 built `sweep` with these seams on purpose,
which is why this chapter can test it without changing it.

=== The pyramid for tools

The test pyramid is an old idea: many fast, narrow tests at the bottom, a few
slow, broad ones at the top. For CLIs and controllers the layers have
concrete names, shown in @fig-test-pyramid.

#fig(placement: auto, caption: [The test pyramid for a CLI such as `sweep`, with the time one test takes on a laptop and roughly how many a mature tool has. A controller has the same layers: reconcile helpers, envtest with faked external APIs, and a kind cluster on top.])[
  #diagram(
    spacing: (14pt, 7pt),
    dnode((0, 0), [real dependencies\ containers · kind], kind: "dark", width: 100pt),
    dnode((0, 1), [the binary\ `testscript` · signals], kind: "accent", width: 145pt),
    dnode((0, 2), [components\ fakes · `httptest` · goldens], kind: "accent", width: 190pt),
    dnode((0, 3), [units\ parsers · policies · fuzz targets], kind: "default", width: 235pt),
    dnode((1, 0), [seconds · a handful], kind: "muted"),
    dnode((1, 1), [~100 ms · tens], kind: "muted"),
    dnode((1, 2), [milliseconds · hundreds], kind: "muted"),
    dnode((1, 3), [microseconds · hundreds], kind: "muted"),
    dedge((0, 0), (1, 0), "--"),
    dedge((0, 1), (1, 1), "--"),
    dedge((0, 2), (1, 2), "--"),
    dedge((0, 3), (1, 3), "--"),
  )
] <fig-test-pyramid>

The shape matters for two reasons. Speed: a suite that runs in five seconds
gets run before every commit, and one that takes five minutes gets run by CI
only. Diagnosis: when a unit test fails, the failure points at a function;
when an end-to-end test fails, it points at the whole program. You want most
bugs caught where the failure message is precise.

The top layers are not optional, though. A unit test can't tell you that
`main` forgot to call `stop()` before `os.Exit`, that the binary prints its
usage text on stdout instead of stderr, or that the official PostgreSQL
image restarts the server once while it initialises. Each layer catches a
class of bug the others can't. The labs go up the pyramid one layer at a
time, then back down to fuzzing, benchmarks, coverage and flakiness, and
finish at the top with real containers.

== How the labs work <sec-test-labs>

This chapter is a set of labs rather than one program. Each lab adds test
files to the `sweep` module you finished in Chapter 4, and none of them
changes a line of the tool itself, with one deliberate exception: in Lab 5
you put two old bugs back for a few minutes, so a fuzzer can find them.

#table(
  columns: (auto, 1.15fr, 1fr),
  table.header([Lab], [What you add], [Go and testing you meet]),
  [1 #h(3pt) Table tests], [`target_test.go`: the parser, case by case], [the `testing` package, subtests, `t.Parallel`, comparing values, `go-cmp`],
  [2 #h(3pt) Fakes over mocks], [A scripted fake prober; the `sweeptest` fake fleet], [interfaces as seams, `t.Helper`, `t.Cleanup`, `testing.TB`],
  [3 #h(3pt) Golden files], [Goldens for the four reporters and for the whole command], [test flags, `-update`, `t.TempDir`, `t.Chdir`, scrubbing],
  [4 #h(3pt) The real binary], [`testscript` scripts for exit codes, streams and signals], [`TestMain`, txtar archives, custom script commands],
  [5 #h(3pt) Fuzzing], [Fuzz targets for both parsers, and their corpus], [`testing.F`, internal test packages, corpus files],
  [6 #h(3pt) Benchmarks], [Benchmarks for parsing, reporting and decoding], [`testing.B`, `b.Loop`, `pprof`, escape analysis, `benchstat`],
  [7 #h(3pt) Coverage], [A `-cover` build of the binary under test], [`GOCOVERDIR`, `go tool covdata`, `go tool cover`],
  [8 #h(3pt) Flaky tests], [A package of broken tests; a fix for a real flake], [build tags, `-count`, `-shuffle`],
  [9 #h(3pt) Real dependencies], [A nested module of container tests], [`replace`, nested modules, `testcontainers-go`],
)

Every lab ends with a checkpoint like Chapter 4's: what you should have, the
commands to run, their real output, and a table of failures we produced on
purpose by breaking a copy of that lab, with the exact message each one
prints. The repository has every lab as a complete module under
`workbook/ch06/step1` to `step9`, and each passes `go vet`, `go test -race`
and `golangci-lint`. The last one is not a toy: its test files are the ones
the repository runs against the production `sweep`, and a check in CI keeps
them identical.

You need Go 1.27, your `sweep` module from Chapter 4, `git`, two terminal
windows for Lab 7, network access for `benchstat` in Lab 6, and Docker for
Lab 9 (the lab explains how its tests skip without it).

=== Before the labs

Work in the `sweep` directory you finished in Chapter 4. If you skipped that
chapter, copy `workbook/ch04/step7` from the book's repository and call the
copy `sweep`. Delete any `sweep` binary you built there, and create a
`.gitignore` file so the binaries and coverage data of the coming labs never
end up in a commit:

#src("workbook/ch06/step1/.gitignore")

Then put the module under version control, so `git status` can show what
each lab added and so Lab 5 can restore a file you break on purpose, and
check that the tests from Chapter 4 pass:

#session(
  ("cd sweep", none),
  ("git init -q && git add -A && git commit -qm \"sweep from Chapter 4\"", "ch06/s0-git.txt"),
  ("go test ./...", "ch06/s0-test.txt"),
)

`cmd/fleet` has no tests and says so with `?`; everything else passes.
Commit again at the end of each lab if you like; the checkpoints show `git status` against this first commit, so they list everything the chapter has
added so far.

#step(1, 9, "Lab 1: Table tests for the parser", label: <sec-test-tables>)

`ParseTargets` is the first place `sweep` touches the world: it reads a
file a person wrote. Chapter 4 gave it one test, which checks that every
error is reported with its line number. That test says nothing about what
the parser _accepts_: whether `HTTPS://Example.com/` is an HTTP target,
what host an IPv6 literal gets for the per-host limit, whether an indented
comment is skipped. This lab pins all of that down with a table-driven test,
the most common shape of test in Go, written well.

#goconcept(title: [The `testing` package, briefly])[
  Chapter 0 introduced Go's tests; here is what this chapter relies on. A
  test lives in a file ending in `_test.go`, is named `TestXxx`, and takes a
  `t *testing.T`. `t.Errorf` records a failure and carries on, `t.Fatalf`
  records one and stops the test, and a test that calls neither passes.
  `go test ./...` compiles each package together with its test files into a
  test binary and runs it; `-v` lists every test, `-run` picks tests by
  regular expression, and `-count=1` bypasses the cache that otherwise
  replays an unchanged package's last result as `(cached)`.

  A test file may declare `package sweep` and see everything in the
  package, or `package sweep_test`, an _external_ test package that sees
  only exported names, exactly as a user of the package would. Chapter 4's
  tests use the external form, and so does this lab: the parser is tested
  through `ParseTargets`, its public face.
]

The test compares results with `go-cmp`, Google's comparison library, which
prints a readable diff when two values differ. Add it to the module:

#session(
  ("go get github.com/google/go-cmp@v0.7.0", "ch06/s1-goget.txt"),
  ("go mod tidy", "ch06/s1-tidy.txt"),
)

Create `internal/sweep/target_test.go`. It starts with the imports and a
small type that holds the parts of a `Target` the tests care about:

#src("workbook/ch06/step1/internal/sweep/target_test.go", region: "top")

`Target` holds a `*url.URL`, and comparing whole URLs drags every parser
detail into the test: the `Opaque` field, `RawPath`, `ForceQuery` and six
more. The test maps each target to a `parsed` value with only the fields
the behaviour is about, and compares slices of those. Here is the table:

#src("workbook/ch06/step1/internal/sweep/target_test.go", region: "table")

*Names are paths.* `t.Run` turns spaces into underscores and keeps slashes,
so a name like `tcp/ipv6 literal` puts the case in a group. The `-run` flag
splits its pattern on slashes and matches each level separately, so you can
run one group of one test, as the checkpoint shows. Choose names that
describe the _input_, not the expected outcome: "tcp/ipv6 literal" says
what is special about the case; "returns correct host" says nothing when it
fails.

*Compare with `cmp.Diff`.* It returns an empty string when the values are
equal and a diff otherwise, conventionally reported as `(-want +got)`: lines
starting with `-` are what the test expected, `+` what it got.
`reflect.DeepEqual` would only say `false`. `cmp.Diff` also refuses to
compare unexported fields unless you tell it how (`cmpopts.IgnoreUnexported`,
`cmp.AllowUnexported`, or a `cmp.Transformer`), which is a feature: a test
that silently compares a struct's private cache is a test that breaks on
refactors.

#goconcept(title: [Comparing values])[
  `==` works on numbers, strings, booleans, pointers, channels, and on
  structs and arrays whose fields are all comparable. It does _not_ work on
  slices, maps or functions: `got != want` with two slices is a compile
  error (the troubleshooting table shows it), because "equal" could mean
  "same backing array" or "same elements", and Go makes you say which.
  `slices.Equal` compares elements of comparable slices, `maps.Equal` does
  the same for maps, and `reflect.DeepEqual` walks any two values
  recursively. In tests, prefer `cmp.Diff`: it compares as deeply, and when
  the values differ it tells you where. Python's `==` on lists and Java's
  `equals` compare contents by default; Go's choice is to have no default.
]

*Error cases get their own table.* Mixing "want a value" and "want an
error" in one table leads to cases with half their fields meaningless. Add
the second test to the file:

#src("workbook/ch06/step1/internal/sweep/target_test.go", region: "errors")

`TestParseTargetsRejects` maps a case name to an input and a substring of
the expected error. Because it is a map, the iteration order is random,
which costs nothing and gives every run a free shuffle. Checking a
substring rather than the whole message keeps the test from breaking when
someone improves the wording, while still pinning the part a user acts on.
Lab 5 adds two rows to this map, found by a fuzzer.

#goconcept(title: [Subtests and `t.Parallel`])[
  `t.Run(name, f)` runs `f` as a subtest with its own `t`, named
  `TestParseTargets/name`. A failing subtest marks its parent failed but
  doesn't stop the other subtests, and `t.Fatalf` inside a subtest ends only
  that subtest. `t.Parallel()` pauses the subtest and resumes it, alongside
  the other parallel subtests, once the parent function has returned. Since
  Go 1.22 each loop iteration has its own `tc`, so the old `tc := tc` copy
  before `t.Run` is gone. The common mistake is to use the parent's `t`
  inside the subtest's function: name the parameter `t` so it shadows the
  outer one, as these tests do.
]

=== `t.Parallel` and its traps

Both loops call `t.Parallel()`. Three traps come with it, and Lab 8 shows
the first two failing for real:

- *Cleanup in the parent runs too early.* The parent function returns
  _before_ its parallel subtests run. A `defer srv.Close()` in the parent
  closes the server while the subtests are still paused, and every one of
  them fails with "connection refused". `t.Cleanup` waits for subtests;
  `defer` does not.
- *Process-wide state is off limits.* The environment, the working
  directory and the global random source belong to the whole process.
  `t.Setenv` and `t.Chdir` panic if the test, or any ancestor, called
  `t.Parallel`.
- *Shared fixtures need to be read-only.* A table of structs shared by
  parallel subtests is fine until one case mutates a slice inside it.

Parallel subtests pay off when each case waits on something, such as a
server, a container or a subprocess. For microsecond-long parser cases like
these they gain little; they are there mostly to prove the cases share no
state, and `-race` checks that claim.

=== The `testing` package has grown

Several recent additions to `testing` matter for tools, and they appear
throughout the labs.

#newingo("1.24", title: [`t.Context` and `t.Chdir`])[
  `t.Context()` returns a context that is cancelled just before the test's
  cleanup functions run, so code under test that honours contexts stops
  when the test ends. Every test in this chapter passes `t.Context()` where
  production code would pass a request or signal context.
  `t.Chdir(dir)` changes the working directory and restores it in cleanup
  (on Unix it also sets `PWD`). Because the working directory is process
  state, a test that calls `t.Chdir` can't be parallel. `B.Context` and
  `B.Chdir` exist for benchmarks.
]

Two smaller additions help end-to-end tests. Go 1.25's `t.Attr(key, value)`
emits a key and value into the test log (an `attr` action in
`go test -json`), a clean way to hand CI a container ID or a trace link.
Go 1.26's `t.ArtifactDir()` is a directory for files a failing test wants to
leave behind, such as a container's logs; with `go test -artifacts` it
survives under `-outputdir`, otherwise it is removed after the test.

The flags you will use most are `-run` and `-skip` (regular expressions per
subtest level), `-count=1`, `-race`, `-short`, and `-timeout`, whose expiry
panics and dumps every goroutine, which is how you find a hung test.
`-count=N` and `-shuffle` are flake detectors and appear in Lab 8.

#needspace(14em)
#checkpoint(step: 1, of: 9, title: [Table tests for the parser])[
  `git status` lists what the chapter has added so far: the dependency, and
  one test file. (`-s` is the short format, `-uall` lists files inside new
  directories one by one.)
  #output("ch06/s1-status.txt", cmd: "git status -s -uall")
  #output("ch06/s1-test.txt", cmd: "go test ./internal/sweep")
  Run one group of one test. Anchor each level with `^` and `$`, or
  `TestParseTargets` also matches `TestParseTargetsRejects` and
  `TestParseTargetsReportsAllErrors`:
  #output("ch06/s1-run.txt", cmd: "go test -v -run '^TestParseTargets$/^(tcp|tls)$' ./internal/sweep", size: 6.8pt)
  `PAUSE` and `CONT` are `t.Parallel` at work: each subtest pauses, and
  resumes once its parent has returned. Now see what a failure looks like.
  Suppose you believed that `Host()` strips the brackets from an IPv6
  literal, and wrote `"::1"` as the host in the `tcp/ipv6 literal` row:
  #output("ch06/s1-fail.txt", cmd: "go test -run '^TestParseTargets$' ./internal/sweep", size: 6.8pt)
  The diff names the field and both values. The parser is right (the
  brackets are part of `host:port` syntax, and the per-host limit needs the
  port), so the fix is the row, not the code. Put `"[::1]:5432"` back.
  #troubleshoot(
    ([#ts("s1-norun.txt")], [The pattern matched no test: here `^TestParseTarget$` lacks the final `s`. Go treats that as success.], [Fix the pattern; `go test -list .` prints the test names.]),
    ([#ts("s1-unexported.txt")], [An external test package (`sweep_test`) can't see unexported names such as `parseTarget`.], [Test through `ParseTargets`, or see "Internal and external test packages" in Lab 5.]),
    ([#ts("s1-nomod.txt")], [`go-cmp` is imported but missing from `go.mod`.], [Run the `go get` and `go mod tidy` above.]),
    ([#ts("s1-slicecmp.txt")], [Slices can't be compared with `==` or `!=`.], [`cmp.Diff`. See "Comparing values".]),
    ([#ts("s1-setenv.txt")], [`t.Setenv` in a test that called `t.Parallel`: the environment belongs to the whole process.], [Drop `t.Parallel`, or pass the value as a parameter instead.]),
  )
]

#step(2, 9, "Lab 2: Fakes over mocks", label: <sec-test-fakes>)

The runner's interesting behaviour happens between attempts: honouring a
server's `Retry-After`, spacing attempts to a rate limit, giving up on a
kind it has no prober for. Testing that against real servers means waiting
real seconds and hoping the timing works out on a loaded CI runner. This lab
replaces the network with code the test controls, in two ways: a fake
`Prober` for the runner's logic, and a fake fleet of HTTP endpoints for the
code that really speaks HTTP.

A _fake_ is a working implementation of an interface with shortcuts: an
in-memory store instead of a database, an HTTP handler instead of a remote
service. A _mock_ is an object programmed with expectations about how it
will be called ("`Probe` will be called three times with these arguments")
that fails the test if the calls differ. Both replace a dependency. They
fail in different situations, and that difference decides which one to use.

=== Define the interface where it is used

`sweep.Prober` is declared in package `sweep`, the package that _uses_
probers, and it has one method. The HTTP, TCP, TLS and DNS probers are
implementations that happen to live in the same package, but the interface
belongs to the consumer. Go makes this natural, because a type satisfies an
interface without declaring it, so the consumer can define exactly the
slice of behaviour it needs.

The opposite pattern is common in code ported from Java: a package exports
a `Client` interface that mirrors every method of its concrete client, and
every consumer depends on all forty methods. Faking that interface means
writing forty methods, which is why people reach for mock generators. A
one-method interface at the consumer is trivial to fake by hand.

#goconcept(title: [Interfaces make fakes cheap])[
  Chapters 0 and 4 introduced interfaces. For tests, two of their rules do
  the work. Satisfaction is implicit, so a test file can declare a type
  with a `Probe` method and hand it to `sweep.NewRunner` without the
  `sweep` package knowing the type exists. And the _method set_ decides
  who satisfies: a method declared on a pointer receiver,
  `func (p *scriptedProber) Probe`, belongs to `*scriptedProber` only, so
  the test passes a pointer. That is what you want for a fake with state,
  because a value receiver would record attempts on a copy. In Python you
  would monkeypatch the network call; in Java you would reach for Mockito.
  In Go, the seam is an interface parameter and the fake is ten lines.
]

=== A hand-written fake

Create `internal/sweep/fake_test.go`. This fake prober follows a script of
outcomes per target and records when each attempt started:

#src("workbook/ch06/step2/internal/sweep/fake_test.go", region: "head")
#src("workbook/ch06/step2/internal/sweep/fake_test.go", region: "fake")

The mutex is there because the runner calls `Probe` from many goroutines at
once, and a fake shared between goroutines needs the same care as
production code. The outcome is returned after `s.took` of simulated latency, which
inside a `synctest` bubble costs no real time. A script that runs out of
steps fails permanently, so a test that probes more often than it planned
gets a clear error instead of a hang. Two helpers complete the file's
setup: an accessor for the recorded start times, and a function that runs
one sweep and collects the results by target:

#src("workbook/ch06/step2/internal/sweep/fake_test.go", region: "starts")

#goconcept(title: [Test helpers: `t.Helper`, `t.Cleanup` and `t.Context`])[
  A _test helper_ is an ordinary function that takes the test's `t` and
  calls `t.Fatal` when its setup fails, so the test reads as a list of
  steps. `t.Helper()` marks it as a helper: a failure inside it is then
  reported at the line of the _caller_, which is the line you need to read.
  `t.Cleanup(f)` registers `f` to run when the test and all its subtests
  have finished, in last-in, first-out order; unlike `defer`, it works from
  inside a helper, because it is tied to the test rather than to the
  function. `t.Context()` (Go 1.24) is cancelled just before those cleanups
  run. Helpers that should also work in benchmarks take `testing.TB`, the
  interface that `*testing.T`, `*testing.B` and `*testing.F` all satisfy.
]

The tests say what should _happen_, not what calls should be made. Here is
the runner honouring a server's `Retry-After`:

#src("workbook/ch06/step2/internal/sweep/fake_test.go", region: "retryafter")

And here it spaces attempts to the rate limit. Ten targets on ten hosts go
to a runner limited to five attempts per second:

#src("workbook/ch06/step2/internal/sweep/fake_test.go", region: "ratelimit")

Both run in a `synctest` bubble, so the fake's simulated latency and the
runner's sleeps happen in virtual time and the assertions can be exact: the
retry starts _exactly_ three seconds after the first attempt, and ten
attempts at five per second finish at _exactly_ 1.8 seconds. Neither test
mentions how many times `Probe` was called, in what order, or with which
context. If the runner is refactored to share the rate limiter differently
or to probe hosts in a different order, these tests keep passing as long as
the behaviour holds. Two short tests finish the file. The first checks a
kind with no prober:

#src("workbook/ch06/step2/internal/sweep/fake_test.go", region: "unknown")

The second checks the fake itself, because a fake that misbehaves quietly
makes every test that uses it lie:

#src("workbook/ch06/step2/internal/sweep/fake_test.go", region: "outofsteps")

=== Fakes at the protocol level

The `HTTPProber` itself needs a real HTTP server to talk to, and so do the
tests of the whole command in Lab 3 and of the binary in Lab 4. Chapter 4's
`cmd/fleet` is a program, and `runner_test.go` has a private fleet of its
own; neither can be shared by tests in other packages. `sweeptest` is a
small package in the spirit of `httptest`: a handler with one path per
behaviour a health checker must classify, plus request counting, so tests
can wait for traffic instead of sleeping. Create
`internal/sweep/sweeptest/fleet.go`:

#src("workbook/ch06/step2/internal/sweep/sweeptest/fleet.go", region: "head")
#src("workbook/ch06/step2/internal/sweep/sweeptest/fleet.go", region: "fleet")

Every request goes through `record`, which counts it and wakes anyone
waiting for traffic. The wake-up is a channel that is closed and replaced on
every request, a common way to broadcast "something changed" to any number
of waiters without a `sync.Cond`:

#src("workbook/ch06/step2/internal/sweep/sweeptest/fleet.go", region: "record")

`WaitFor` reads the count and the current channel under the lock, then
waits on the channel outside it, so a request that arrives in between still
wakes it. Last, a constructor for tests that need a real socket:

#src("workbook/ch06/step2/internal/sweep/sweeptest/fleet.go", region: "server")

`NewServer` is a helper in the sense of the box above: `t.Helper()` for
error locations, `t.Cleanup` so the caller never has to remember to close
the server, and `testing.TB` so a benchmark can use it too. Closing client
connections first matters for `/slow`, whose handlers would otherwise keep
`srv.Close` waiting for a minute.

Which server constructor to use depends on who the client is.
`httptest.NewServer` listens on a real loopback port, which a separate
process such as the `sweep` binary can reach. `httptest.NewTestServer`
(Go 1.27, Chapter 4) serves on an in-memory network, which keeps
`synctest` bubbles in virtual time and avoids the kernel entirely, but only
its own `Client()` can reach it. Reading its source shows the details that
matter. The server starts on the first call to `Client()`, so `srv.URL` is
empty until then, and afterwards it is `http://example.com`: the client's
transport dials the in-memory listener whatever the address says. Pass
`srv.URL` to any other client and the request goes to the real
`example.com`. A test that does that passes, for the wrong reason, until
the CI runner has no internet access. `sweeptest` supports both: `NewFleet`
is a plain handler for either constructor, and `NewServer` is the
real-socket shortcut.

The fake fleet gets tests of its own, in
`internal/sweep/sweeptest/fleet_test.go`, because every test that relies on
it assumes it behaves:

#src("workbook/ch06/step2/internal/sweep/sweeptest/fleet_test.go", region: "top")
#src("workbook/ch06/step2/internal/sweep/sweeptest/fleet_test.go", region: "behaviours")
#src("workbook/ch06/step2/internal/sweep/sweeptest/fleet_test.go", region: "waitfor")

`TestWaitForUnblocksOnRequest` uses `NewTestServer` inside a bubble, so
`/slow` stalls for exactly ten virtual seconds; `synctest.Wait` proves that
`WaitFor` really is waiting before any request has arrived. Chapter 20's
`ddfake`, an in-memory fake of the Datadog monitors API, is the same idea for
a vendor API: a fake owned next to the code that depends on it, exercised
through the real HTTP client.

=== When a mock earns its keep

For contrast, here is how the `Retry-After` test starts with a generated
mock from `go.uber.org/mock`. It is a sketch; the repository doesn't use it.

#code(file: "runner_mock_test.go", caption: "sketch, not in the repo")[```go
ctrl := gomock.NewController(t)
p := NewMockProber(ctrl)
gomock.InOrder(
	p.EXPECT().Probe(gomock.Any(), gomock.Any()).
		Return("429", retry.After(3*time.Second, throttled)),
	p.EXPECT().Probe(gomock.Any(), gomock.Any()).Return("200 OK", nil),
)
```]

It reads well and it pins the call sequence, which is the problem. Add a
pre-flight probe, or retry a 429 once more without delay, and the test fails
although the user-visible behaviour is the same. Mocks couple tests to the
implementation; fakes couple them to the contract.

A mocking library is still the right tool in a few cases:

- *The interaction is the behaviour.* "Dry-run mode never calls
  `DeleteBucket`", "exactly one page is sent per incident". Even here, a
  fake that records calls usually reads better, but a strict mock that
  fails on any unexpected call is a reasonable guard for destructive
  operations.
- *The interface is wide and you don't own it.* Generated clients for a
  large API in legacy code, where narrowing the interface is a refactor for
  another day.
- *You need to inject failures at precise points* in a multi-step protocol,
  such as "fail the third `UploadPart`".

#interview(title: [“How do you test code that calls AWS?”])[
  Three layers. First, define a narrow interface at the consumer with only
  the SDK methods the code uses (the AWS SDK for Go v2 helps here: its
  paginators accept small interfaces such as `s3.ListObjectsV2APIClient`),
  and unit-test against a hand-written fake that holds state in memory and
  can inject throttling and partial failures. Second, run integration tests
  against an emulator (LocalStack, MinIO for S3, DynamoDB Local) in a
  container, with the SDK's endpoint pointed at it. Third, keep a small
  smoke suite against a real sandbox account, run on a schedule with cleanup
  and a budget alarm, because emulators drift from the real service in
  exactly the corners you care about: IAM, eventual consistency, error
  codes. Chapter 18 builds this for three clouds.
]

#needspace(14em)
#checkpoint(step: 2, of: 9, title: [Fakes over mocks])[
  #output("ch06/s2-status.txt", cmd: "git status -s -uall")
  The two timing tests take no measurable time, although one waits three
  seconds and the other 1.8:
  #output("ch06/s2-run.txt", cmd: "go test -v -run 'TestRunnerHonoursRetryAfter|TestRunnerRateLimitSpacesAttempts' ./internal/sweep", size: 6.8pt)
  #output("ch06/s2-fleet.txt", cmd: "go test -v ./internal/sweep/sweeptest")
  #troubleshoot(
    ([#ts("s2-copylocks.txt")], [`Probe` has a value receiver, so every call copies the fake, mutex included, and records on the copy.], [Pointer receiver: `func (p *scriptedProber) Probe`.]),
    ([#ts("s2-pointer.txt")], [The test passed a `scriptedProber` value, but `Probe` belongs to `*scriptedProber`.], [Pass the pointer `fake`. See "Interfaces make fakes cheap".]),
    ([#ts("s2-nobubble.txt")], [The test ran outside a `synctest` bubble, so the clock was real: the test took three real seconds and the timing was off by scheduling noise.], [Wrap the test body in `synctest.Test`.]),
    ([#ts("s2-maxdelay.txt")], [The policy's `MaxDelay` (2s) caps the server's `Retry-After` (3s). The fake caught a real policy decision.], [Raise `MaxDelay`, or change the test if capping is what you want.]),
  )
]

#step(3, 9, "Lab 3: Golden files", label: <sec-test-golden>)

`sweep` has four output formats, and two of them are machine-read. The JSON
document feeds dashboards, the JSON Lines stream feeds `jq` filters and the
deploy gate, and the table is read by people who will notice when a column
moves. Asserting on output with `strings.Contains` checks that some text is
present. It can't tell you that a field was renamed, a column re-ordered, or
a long error truncated in a new place.

A _golden file_ stores the exact expected output next to the test. The test
renders the output and compares it byte for byte. When the output changes
on purpose, you rerun the test with `-update`, which rewrites the file, and
the change to the golden file shows up in the pull request, where a reviewer
can see precisely how the output changed.

=== Goldens for the reporters

Create `internal/sweep/report_test.go`, starting with the imports, the
`-update` flag and the helper that compares or rewrites a golden file:

#src("workbook/ch06/step3/internal/sweep/report_test.go", region: "top")

The helper is about twenty lines and doesn't need a library. Two details
matter. The comparison is by lines: `cmp.Diff` on two slices of lines
reports which lines changed, the form a reviewer reads in a pull request.
And `-update` is a flag the test package defines for itself.

#goconcept(title: [Flags of your own in tests])[
  A test binary is a Go program, and `go test` passes it every flag it
  doesn't recognise. A package-level `flag.Bool` in a test file therefore
  becomes a flag of that package's test binary, parsed before any test
  runs: `go test ./internal/sweep -update` sets `*update` to `true`. The
  catch is that the flag exists only in packages that declare it, so
  `go test ./... -update` fails in every other package, as the
  troubleshooting table shows. Run `-update` for one package at a time,
  and never in CI. Flags after `-args` go to the test binary untouched,
  which Lab 7 uses.
]

=== Determinism first

A golden file is only useful if the output is identical on every run, on
every machine. Output from a real sweep contains three things that change:
latencies, the elapsed time, and the order in which results arrive. The
first rule is to remove them at the source, by feeding the reporter fixed
input instead of running a sweep:

#src("workbook/ch06/step3/internal/sweep/report_test.go", region: "fixture")

Every value is pinned, including the 42 ms latency and the 2.14 s elapsed
time, and the results are listed in a scrambled _completion_ order on
purpose. The table and JSON reporters sort by input index, so their golden
files prove the sorting works. The JSON Lines reporter streams in completion
order, so its golden file pins that order instead. The test renders the
fixture through each of the four reporters and hands the bytes to `golden`:

#src("workbook/ch06/step3/internal/sweep/report_test.go", region: "test")

The golden files don't exist yet, so the first run fails, and says what to
do:

#output("ch06/s3-missing.txt", cmd: "go test -run TestReportersGolden ./internal/sweep", size: 6.8pt)

Run the test once with `-update` to write them, then look at what it wrote:

#session(
  ("go test ./internal/sweep -run TestReportersGolden -update", "ch06/s3-update.txt"),
  ("ls internal/sweep/testdata/golden", "ch06/s3-ls.txt"),
)

The `testdata` directory is ignored by the `go` command, which makes it the
conventional home for fixtures. The golden table is a file anyone can read
in review:

#src("workbook/ch06/step3/internal/sweep/testdata/golden/report-table.golden")

Read it before you commit it. `-update` writes whatever the code produces,
so the first golden file is only as right as the person who checked it.
Here the rows are in inventory order although the fixture lists them
scrambled, and the two long details are cut to 36 characters, ellipsis
included, so the table stays readable in a terminal.

Now the payoff. Suppose someone decides that `latency_ns` is an awkward name
and renames the JSON field to `latency_ms` in `runner.go`, leaving the value
in nanoseconds. Every `jq` filter and the deploy gate that read the field
silently get `null`. The capture script made exactly that edit to a copy of
the lab and ran the JSON case:

#output("ch06/s3-rename.txt", cmd: "go test -run 'TestReportersGolden/^json$' ./internal/sweep", size: 6.8pt)

The rename turns into a red test with a diff that names the field. If the
rename is intended, `-update` accepts it and the reviewer sees five changed
lines in `report-json.golden`, which is the moment to ask who consumes that
field.

#warning(title: [Golden files rot when `-update` becomes a reflex])[
  The failure mode is social. A test goes red, someone runs `-update`
  without reading the diff, and the golden file now enshrines the bug. Keep
  golden files small enough to review (five results, not five hundred),
  give each one a single purpose, and treat a golden diff in a pull request
  like an API change, because for anything machine-read that is what it is.
]

=== Scrubbing second: the whole command

The reporter goldens prove the formatting. They don't prove that `run`
wires flags, files, the runner, the reporter and the summary together. The
next test runs the whole command, from an inventory file on disk to stdout,
stderr and the exit status, against the fake fleet from Lab 2 over real
sockets. Ports are chosen by the kernel and timings are real, so they can't
be pinned at the source. Here the rule is to scrub what varies,
structurally where possible.

Create `cmd/sweep/golden_test.go`. It is in package `main`, like Chapter 4's
`main_test.go`, because it calls the unexported `run`:

#src("workbook/ch06/step3/cmd/sweep/golden_test.go", region: "head")
#src("workbook/ch06/step3/cmd/sweep/golden_test.go", region: "update")
#src("workbook/ch06/step3/cmd/sweep/golden_test.go", region: "scrub")

`scrubJSON` decodes the document, zeroes the two timing fields and encodes
it again. Regular expressions over JSON break on escaped quotes and
reordered keys; decoding into `map[string]any` and re-encoding also sorts
the keys, so the result is canonical. Scrubbing the _table_ by regular
expression would be a trap: `tabwriter` sizes each column to its widest
cell, so replacing `1ms` with a placeholder changes the padding on every
row. If an output format aligns columns, scrub the data before it is
formatted, or test a structured format instead, which is what this test
does. The test itself:

#src("workbook/ch06/step3/cmd/sweep/golden_test.go", region: "golden")

#newingo("1.24", title: [`t.TempDir` and `t.Chdir` together])[
  `t.TempDir()` creates a directory that is removed when the test ends.
  `t.Chdir(dir)` makes it the working directory until then. Together they
  let the test pass the inventory as `fleet.txt`, a relative path, the way a
  user types it. The trap: after the `Chdir`, every relative path in the
  test resolves against the new directory, including `testdata/`.
]

That trap is why the golden helper in `cmd/sweep` differs from the one in
`internal/sweep`. It resolves golden files against the package directory,
captured once when the test binary starts and before any test changes
directory:

#src("workbook/ch06/step3/cmd/sweep/golden_test.go", region: "goldenfile")

Write the two golden files and read them. The scrubbed stderr is a single
line:

#output("ch06/s3-cli-update.txt", cmd: "go test ./cmd/sweep -run TestRunGolden -update")
#src("workbook/ch06/step3/cmd/sweep/testdata/golden/run-stderr.golden")

and the JSON document lists six results with their ports replaced by `PORT`
and their latencies by zero. The flaky target came up on its third
attempt, the 404 failed for good after one, and the 503, the slow and the
refused targets used all three: the retry policy from Chapter 4, pinned
end to end.

#needspace(14em)
#checkpoint(step: 3, of: 9, title: [Golden files])[
  The golden files are part of the change; commit them with the tests.
  #output("ch06/s3-status.txt", cmd: "git status -s -uall")
  #output("ch06/s3-pass.txt", cmd: "go test -count=1 -v -run 'TestReportersGolden|TestRunGolden' ./internal/sweep ./cmd/sweep | grep -E '^(---|    ---|ok)'", size: 6.8pt)
  #troubleshoot(
    ([#ts("s3-missing.txt")], [The golden file doesn't exist yet.], [`go test ./internal/sweep -run TestReportersGolden -update`, then read the files.]),
    ([#ts("s3-updateall.txt")], [`-update` given to packages that don't define it.], [Name one package: `go test ./internal/sweep -update`. See "Flags of your own in tests".]),
    ([#ts("s3-relpath.txt")], [The helper used a relative path after the test's `t.Chdir`.], [Resolve against `testDir`, captured before any `Chdir`.]),
    ([#ts("s3-noscrub.txt")], [Something that varies between runs reached the golden file: here the elapsed time, unscrubbed.], [Scrub it, or better, pin it at the source.]),
    ([#ts("s3-chdir.txt")], [`t.Chdir` in a parallel test: the working directory belongs to the whole process.], [Don't call `t.Parallel` in tests that change directory.]),
  )
]

#step(4, 9, "Lab 4: The binary, end to end, with testscript", label: <sec-test-script>)

The `run` function is a seam, and Lab 3 tests through it. But `run` is not
what CI executes. CI executes a binary, which reads `os.Args`, inherits an
environment, gets signals from the kernel, and reports through an exit
status. The contract `sweep` has with its callers lives at that level:

- exit status 0 when everything is up, 1 when something is down or the run
  was cut short by `-deadline`, 2 for usage and inventory errors, 130 when
  interrupted;
- results on stdout and diagnostics on stderr, so `sweep -o jsonl | jq`
  never sees an error message;
- the inventory from files named on the command line, in order, or from
  stdin when there are none;
- a report of everything that finished when the user presses #kbd("Ctrl-C").

Teams usually test this with a shell script in CI, which works until it
doesn't (the tip at the end of this lab lists why). `testscript`, from
`github.com/rogpeppe/go-internal`, is the harness the Go team built for
testing the `go` command itself, extracted into a library. A test is a
_txtar_ file: a short script followed by the files it needs. Add the module:

#session(
  ("go get github.com/rogpeppe/go-internal@v1.16.0", "ch06/s4-goget.txt"),
  ("go mod tidy", "ch06/s4-tidy.txt"),
)

The scripts live in a directory of their own, `sweepscript`, under
`testdata/script`. Create `sweepscript/testdata/script/exit_status.txtar`,
which checks the exit-status contract:

#src("workbook/ch06/step4/sweepscript/testdata/script/exit_status.txtar")

Each line is a command run by a small interpreter, not a shell. `exec` runs a
program, and `stdout` and `stderr` assert regular expressions against what
the previous command printed (`-count=N` asserts how many times). A leading
`!` negates. The `--` lines start files that are written into a fresh
temporary directory, `$WORK`, before the script runs. `envsubst` and
`exits` are custom commands, shown below. When a script fails, the log
shows every command, its stdout and stderr, and the line that failed.

=== Building the harness

There are two ways to give a script a `sweep` command. `testscript.Main`
re-executes the test binary itself as the command, so `main` runs inside
the test binary:

#code(file: "cmd/sweep/script_test.go", caption: "the in-package variant, a sketch")[```go
func TestMain(m *testing.M) {
	testscript.Main(m, map[string]func(){"sweep": main})
}
```]

That is a fine default, but it needs the test to live in package `main`.
This lab builds the real binary instead, the way CI would, for two reasons.
Lab 7 builds it with `-cover` to measure what the scripts exercise. And the
same harness then works from a module of its own: the book's repository keeps
its scripts in a nested module, `examples/ch06/sweepscript`, because the
root module avoids `testscript`'s dependencies, and Lab 9 shows why a team
does that. The harness starts with a `TestMain`.

#goconcept(title: [`TestMain` and `*testing.M`])[
  If a test package defines `func TestMain(m *testing.M)`, `go test` calls
  it instead of running the tests directly. `m.Run()` runs them all and
  returns an exit status, and `TestMain` passes it to `os.Exit`. Setup
  before `m.Run` happens once for the whole package: starting a server,
  building a binary, or wrapping the run in a check, as goleak's
  `VerifyTestMain` does in Chapter 4. `os.Exit` skips deferred calls, so
  clean up explicitly between `m.Run` and `os.Exit`, as below. A package
  can have only one `TestMain`, which is one reason this harness has a
  directory of its own.
]

Create `sweepscript/script_test.go`:

#src("workbook/ch06/step4/sweepscript/script_test.go", region: "top")
#src("workbook/ch06/step4/sweepscript/script_test.go", region: "build")

`buildSweep` asks the `go` command which module owns `cmd/sweep` and builds
inside that module. In your module the answer is simply your module's
directory. In a nested module the answer is the module that _owns_ the
command, so the build uses that module's `go.mod` and its dependency
versions rather than the test module's. `TestScripts` turns each txtar file
into a subtest:

#src("workbook/ch06/step4/sweepscript/script_test.go", region: "run")

`Setup` runs after the archive is unpacked and before the script starts. It
puts the binary first on `PATH` and starts a fake fleet for this script
alone, so scripts can run in parallel without sharing state. The fleet's
address goes into the environment, because the scripts can't know the port
in advance. The `fleetKey` value hands the fleet itself to custom commands.

Three custom commands cover what the built-ins can't express. `exits`
asserts an exact exit status:

#src("workbook/ch06/step4/sweepscript/script_test.go", region: "exits")

`waitreq path n` removes the need to sleep: it blocks on the fake fleet
until `path` has served `n` requests.

#src("workbook/ch06/step4/sweepscript/script_test.go", region: "waitreq")

`envsubst` expands `$FLEET` inside inventory files, since testscript expands
variables in command arguments but not in the files of the archive:

#src("workbook/ch06/step4/sweepscript/script_test.go", region: "envsubst")

The file ends with the helper `Setup` uses to reserve a refused address. It
listens on port 0, notes the port the kernel picked, and closes the
listener; Lab 8 explains why that is good enough for a test and no more:

#src("workbook/ch06/step4/sweepscript/script_test.go", region: "refused")

=== Three more scripts

`inventory.txtar` checks that every inventory mistake is reported at once,
with line numbers and status 2, before any target is contacted, and that
stdin and multiple files work:

#src("workbook/ch06/step4/sweepscript/testdata/script/inventory.txtar")

`help.txtar` pins the usage text with `cmp stderr usage.txt`, where
`usage.txt` is a file inside the same archive. Running the suite with
`-update` sets `UpdateScripts`, which rewrites that file in place when a
flag changes: a golden file that lives next to its test.

#src("workbook/ch06/step4/sweepscript/testdata/script/help.txtar")

=== A real Ctrl-C

The test that justifies the whole harness sends a real `SIGINT` to a real
process and checks what the user would see:

#src("workbook/ch06/step4/sweepscript/testdata/script/interrupt.txtar")

With `-v`, testscript prints each script's transcript: comments, every
command (prefixed `>`), and what it printed. Here is the `interrupt` script
running, without the dump of the script's environment that testscript
prints first (it is long and specific to the machine):

#output("ch06/s4-interrupt.txt", cmd: "go test -count=1 -v -run 'TestScripts/^interrupt$' ./sweepscript", size: 6.6pt)

`exec sweep ... &sweep&` starts the binary in the background under the name
`sweep`. `waitreq /slow 2` waits until two checks are hanging on `/slow`, so
the interrupt lands at a known point instead of after a guessed sleep.
`kill -INT sweep` delivers the signal, and `wait sweep` collects the output.
Everything in that log is real: the binary installed its signal handler,
printed its own shutdown notice on stderr, cancelled the two in-flight
checks, never started the fourth target, and still printed a complete table
and summary. The second half of the script runs the same inventory with
`-deadline 300ms` and asserts exit status 1, not 130: a deadline is a
property of the fleet, an interrupt is a decision by the user, and a CI
system should be able to tell them apart.

#tip(title: [Why this beats a shell script in CI])[
  Each script runs in a fresh directory with a controlled environment
  (`HOME` points nowhere, `TMPDIR` is private), so scripts can't leak into
  each other or depend on the developer's machine. They run in parallel
  under `go test`, so `-run`, `-count`, `-shuffle` and `-timeout` all work.
  The harness runs the same way on Linux, macOS and Windows runners, with
  no `bash` or GNU `grep` required (only the signal test is Unix-specific).
  A failure prints the full transcript up to the failing line. And the
  binary under test can be built with `-cover`, so the end-to-end suite
  counts towards coverage instead of being a black box (Lab 7).
]

#needspace(14em)
#checkpoint(step: 4, of: 9, title: [The binary, end to end])[
  #output("ch06/s4-status.txt", cmd: "git status -s -uall")
  The four scripts run in parallel, each with its own fleet and directory:
  #output("ch06/s4-run.txt", cmd: "go test -count=1 -v ./sweepscript | grep -E \"^(=== RUN|---|    ---|ok|PASS|FAIL)\"", size: 6.8pt)
  #troubleshoot(
    ([#ts("s4-exits.txt")], [The script expected status 1; `sweep` says 2. The statuses mean different things, which is why `exits` checks the number.], [Fix whichever side is wrong; here the script.]),
    ([#ts("s4-envsubst.txt")], [The inventory still says `$FLEET/ok`: the script skipped `envsubst`, so the URL has no scheme.], [Run `envsubst` on every file that mentions a variable.]),
    ([#ts("s4-path.txt")], [`Setup` didn't put the built binary on `PATH`.], [Prepend `binDir` to `PATH` in `Setup`.]),
    ([#ts("s4-regex.txt")], [A `stdout` pattern didn't match. The transcript above the failure shows what was printed.], [Read the `[stdout]` block, then fix the pattern or the code.]),
    ([#ts("s4-cmp.txt")], [The usage text changed (here the archive's copy was edited), so `cmp` fails with a diff.], [If the new text is right: `go test ./sweepscript -update`.]),
  )
]

#step(5, 9, "Lab 5: Fuzzing the parsers", label: <sec-test-fuzz>)

Every test so far checks inputs someone thought of. The inputs that break
tools are the ones nobody thought of: an inventory line pasted from a wiki
with a non-breaking space, a header from a misconfigured proxy, a port
number with one digit too many. Go's native fuzzing (Go 1.18) generates
those inputs for you. `go test -fuzz` runs a fuzz target millions of times,
mutating inputs and keeping the ones that reach new code, until it finds an
input that fails or the time runs out.

#goconcept(title: [Fuzz targets])[
  A fuzz target is a function `FuzzXxx(f *testing.F)` in a test file.
  `f.Add(...)` adds _seed_ inputs, and `f.Fuzz(func(t *testing.T, ...))`
  registers the function that checks one input. Its parameters after `t`
  are the generated values, and each must be a string, `[]byte`, a sized
  integer, a float, a `bool` or a rune; the seeds passed to `f.Add` must
  have exactly those types. Without `-fuzz`, `go test` runs the target as
  an ordinary test over its seeds and the saved corpus, so it costs nothing
  in CI. With `-fuzz '^FuzzXxx$'`, which must match exactly one target in
  exactly one package, it generates new inputs until `-fuzztime` runs out
  or one fails. A failing input is saved under `testdata/fuzz/FuzzXxx/` and
  replayed by every later `go test`.
]

The hard part is not the mechanics. It is deciding what must be true for
_every_ input, because the fuzzer can only find violations of properties
you write down. "Doesn't panic" is the weakest property and still worth
having. Stronger ones come from the function's contract. `ParseTargets`
promises to report every syntax error up front, with a line number, so
anything it accepts must be something the runner can actually probe, and
the lines it accepted must parse to the same targets again. Create
`internal/sweep/target_fuzz_test.go`:

#src("workbook/ch06/step5/internal/sweep/target_fuzz_test.go", region: "head")
#src("workbook/ch06/step5/internal/sweep/target_fuzz_test.go", region: "fuzz")

`project` and the `parsed` type come from Lab 1's `target_test.go`, in the
same package. The seeds also run as subtests on every plain `go test`.

=== Put the first bug back

Your parser already rejects bad ports, because Chapter 4 printed the fixed
version. The check wasn't in the first version of that parser; a fuzz test
like this one found the gap. To watch the fuzzer find it, put the parser
back the way it was. In `internal/sweep/target.go`, delete this block from
`parseTarget`, and the `"strconv"` import, which only the block uses:

#src("workbook/ch06/step5/internal/sweep/target.go", region: "port")

Then fuzz for at most a minute:

#output("ch06/s5-fuzz-targets.txt", cmd: "go test -run '^$' -fuzz '^FuzzParseTargets$' -fuzztime 60s ./internal/sweep", size: 6.8pt)

`-run '^$'` skips the ordinary tests, which have already passed. The lines
before the failure are the fuzzer's progress: `execs` is how many inputs it
has tried, and `new interesting` how many reached code no earlier input
had. Your run will probably find a different input, in a different time,
because mutation is random, but it finds the same bug: `url.Parse` accepts any run
of digits as a port, so `ParseTargets` accepted a port above 65535. Nothing
failed at parse time. At run time the dialer rejects the address with
"invalid port", which `sweep` treats as a transient network error: it
retries three times, reports the target as down, and fails the pipeline
over a typo in an inventory file, with no line number.

The fuzzer saved the input it found, shrunk to a minimal form, and the file
is plain text:

#session(
  ("ls internal/sweep/testdata/fuzz/FuzzParseTargets", "ch06/s5-corpus-ls.txt"),
  ("cat internal/sweep/testdata/fuzz/FuzzParseTargets/*", "ch06/s5-corpus-cat.txt"),
)

From now on, every `go test` replays it as a subtest named after the file,
and fails while the bug is there. Put your parser back with `git`, and the
saved input passes:

#session(
  ("git restore internal/sweep/target.go", "ch06/s5-restore.txt"),
  ("go test -v -run '^FuzzParseTargets$' ./internal/sweep | grep -E '^(---|    ---|ok)'", "ch06/s5-replay.txt"),
)

Commit the file under `testdata/fuzz`, so the bug can't return unnoticed.
And give the table from Lab 1 the two rows this finding implies. Add them
at the end of the map in `TestParseTargetsRejects`:

#src("workbook/ch06/step5/internal/sweep/target_test.go", region: "portrows")

The rows are faster than the corpus entry, run with `-run`, and document
the rule in words: a port must be between 1 and 65535.

=== A second target, a second bug

`parseRetryAfter` reads the `Retry-After` header, which a server sends with a
429 or 503 to say how long to back off. Its contract is simple: an accepted
value is a delay, and a delay is never negative. It is unexported, so its
fuzz target can't live in the external test package.

#goconcept(title: [Internal and external test packages])[
  The test files of one directory can mix two packages. Files that say
  `package sweep` are compiled _into_ the package and see its unexported
  names; files that say `package sweep_test` are a separate package that
  imports `sweep` like any user. `go test` builds both into one test
  binary, so `TestMain` and helpers in either serve both, but names don't
  cross from `sweep_test` to `sweep`. Prefer the external package: it tests
  what callers can rely on and survives refactors. Use the internal one for
  unexported functions worth testing directly, such as a parser hidden
  behind an HTTP client.
]

Create `internal/sweep/probe_fuzz_test.go`, in package `sweep`:

#src("workbook/ch06/step5/internal/sweep/probe_fuzz_test.go", region: "head")
#src("workbook/ch06/step5/internal/sweep/probe_fuzz_test.go", region: "fuzz")

The file also gets a table test for the parser's documented cases,
including the row this lab is about to justify:

#src("workbook/ch06/step5/internal/sweep/probe_fuzz_test.go", region: "table")

Now put the second bug back. Chapter 4's `parseRetryAfter` clamps the number
of seconds before multiplying. The first version multiplied directly. In
`internal/sweep/probe.go`, replace the `return` inside the
`strconv.ParseInt` branch with the old line:

#code(file: "internal/sweep/probe.go", caption: "the old line, for this experiment only")[```go
		return time.Duration(secs) * time.Second, true
```]

(The `maxSecs` constant is now unused, which Go allows for constants.)

#output("ch06/s5-fuzz-retryafter.txt", cmd: "go test -run '^$' -fuzz '^FuzzParseRetryAfter$' -fuzztime 60s ./internal/sweep", size: 6.8pt)

Any number of seconds above about 9.2 billion, multiplied by `time.Second`,
overflows `int64`, and the result can come out negative. The retry policy
caps a server-requested delay with `min(delay, MaxDelay)`, which keeps the
negative value, and a timer with a negative duration fires immediately. The
result is the exact opposite of what the server asked for: "back off for a
very long time" became "retry right now". No server sends that header on
purpose, but a buggy proxy or a deliberately hostile endpoint can, and a
fleet tool should not amplify either. Restore the file:

#output("ch06/s5-restore2.txt", cmd: "git restore internal/sweep/probe.go")

With both fixes in place, a minute of fuzzing finds nothing more:

#output("ch06/s5-fuzz-after.txt", cmd: "go test -run '^$' -fuzz '^FuzzParseTargets$' -fuzztime 60s ./internal/sweep 2>&1 | tail -3")

Millions of executions without a failure are evidence, not proof. The
round-trip and port properties hold for everything the mutator reached,
and a rising "new interesting" count at the end means it was still finding
new paths through `url.Parse`. A longer run could still find something.

#internals(title: [How `go test -fuzz` works])[
  The fuzzing engine is coverage-guided. The fuzz target is built with
  extra instrumentation that records which edges of the control-flow graph
  each input exercises. A coordinator process hands inputs to worker
  processes (`GOMAXPROCS` of them unless `-parallel` says otherwise),
  mutates the inputs that reached new edges, and keeps them in a cache
  corpus under `$(go env GOCACHE)/fuzz`, which is why a second run starts
  where the first stopped (`go clean -fuzzcache` empties it). When an input
  fails, the engine minimises it (shorter inputs that still fail), writes it
  to `testdata/fuzz/<Target>/`, and stops.
]

Good fuzz targets in platform code are anything that parses text written by
a person or another system: inventory and config files, label selectors,
duration and size strings, headers, log lines, and webhook payloads. Encoders
are good targets too, with a round-trip property (`Decode(Encode(x)) == x`),
and so is any rewrite of a working function: fuzz the new implementation
against the old one and fail on any difference. Fuzzing has a blind spot
worth knowing: inputs stay small, so limits such as `bufio.Scanner`'s
64 KiB line length need a table row (Exercise 6.2).

#tip(title: [Fuzzing in CI])[
  Run the seed corpus on every push; it is part of `go test` already. Run
  real fuzzing in a scheduled job, a few minutes per target, and have it
  open a pull request with any new file under `testdata/fuzz`. Fuzzing on
  every push makes CI slower without making it more thorough, because the
  value comes from total fuzzing time, not from fuzzing often.
]

#needspace(14em)
#checkpoint(step: 5, of: 9, title: [Fuzzing the parsers])[
  Your corpus files have other names than the ones below, which are the
  inputs the fuzzer found when this chapter was written.
  #output("ch06/s5-status.txt", cmd: "git status -s -uall")
  Without `-fuzz`, the targets are ordinary tests over the seeds and the
  saved corpus:
  #output("ch06/s5-seeds.txt", cmd: "go test -count=1 -v -run '^Fuzz' ./internal/sweep | grep -E '^(---|    ---|ok)'", size: 6.8pt)
  #troubleshoot(
    ([#ts("s5-regress.txt")], [A saved corpus entry failed: the bug it found is back (here, the parser is still broken).], [Fix the code, not the corpus. `git restore` if you broke it on purpose.]),
    ([#ts("s5-multi.txt")], [`-fuzz` matched two targets. It must match exactly one.], [Anchor it: `-fuzz '^FuzzParseTargets$'`.]),
    ([#ts("s5-pkgs.txt")], [`-fuzz` with a package pattern that matches several packages.], [Name the one package: `./internal/sweep`.]),
    ([#ts("s5-external.txt")], [The fuzz test is in `package sweep_test`, which can't see the unexported `parseRetryAfter`.], [`package sweep`. See "Internal and external test packages".]),
    ([#ts("s5-addtype.txt")], [A seed's type doesn't match the fuzz function's parameter: `f.Add(120)` for a `string`.], [`f.Add("120")`.]),
  )
]

#step(6, 9, "Lab 6: Benchmarks that mean something", label: <sec-test-bench>)

`sweep` spends nearly all of its time waiting on the network, so its CPU
cost rarely matters. Benchmarks become worth writing when an input grows
(a 20,000-line inventory parsed on every pipeline run), when code moves onto
a hot path (a deploy gate decoding `sweep -o jsonl` for every service in a
release), or when something underneath you changes. Go 1.27 changed
something underneath every program that uses `encoding/json`, and that makes
a good worked example.

#goconcept(title: [Benchmarks])[
  A benchmark is a function `BenchmarkXxx(b *testing.B)` in a test file. It
  runs the code under test in a loop, and `go test -bench regexp` runs the
  matching benchmarks after the tests, increasing the iteration count until
  the measurement is stable (about one second by default; `-benchtime`
  changes it). The result line gives the iterations, the time per
  iteration (`ns/op`), and with `-benchmem` the bytes and allocations per
  iteration. `b.ReportMetric` adds a unit of your own. `b.Run` makes
  sub-benchmarks, like `t.Run`. A benchmark measures one machine at one
  moment; comparing two needs statistics, which is what `benchstat` is for.
]

Create `internal/sweep/bench_test.go`. Its helpers build inputs shaped like
real ones:

#src("workbook/ch06/step6/internal/sweep/bench_test.go", region: "head")
#src("workbook/ch06/step6/internal/sweep/bench_test.go", region: "helpers")

Parsing first:

#src("workbook/ch06/step6/internal/sweep/bench_test.go", region: "parse")

#newingo("1.24", title: [`b.Loop`])[
  `for b.Loop() { ... }` replaces `for range b.N`. The benchmark function
  now runs exactly once per `-count`, so setup before the loop (here,
  building a 1,000-line inventory) runs once and isn't timed: `Loop` resets
  the timer on its first call and stops it when it returns `false`. The
  compiler also keeps the arguments and results of calls inside the loop
  alive, so it can't optimise away the work being measured, which used to
  need a package-level sink variable. Go 1.26 removed a side effect of
  that mechanism: the loop body is now inlined normally, so `b.Loop`
  benchmarks no longer show allocations that the `b.N` version didn't have.
]

`b.Elapsed()` and `b.ReportMetric` turn the result into the unit that
matters for an inventory, nanoseconds per line. The reporter benchmarks
render 1,000 results in each format, and a decode benchmark measures the
consumer's side:

#src("workbook/ch06/step6/internal/sweep/bench_test.go", region: "benches")

#output("ch06/s6-bench.txt", cmd: "go test -run '^$' -bench . -benchmem ./internal/sweep | benchfmt")

`benchfmt` is a small `awk` filter in the capture script that re-spaces the
tab-aligned columns to fit the page; run the command without it. The `-10`
suffix is `GOMAXPROCS`. Each line gives the iteration count, time per
operation, the custom metric, bytes allocated per operation and the number
of allocations. Parsing costs a few hundred nanoseconds per inventory line,
so a 20,000-line inventory parses in a few milliseconds: not worth another
thought. The table reporter makes about six allocations per row, which is
worth a look, if only to learn how to look.

=== Where the allocations come from

A memory profile from the benchmark says which functions allocate:

#session(
  ("go test -run '^$' -bench 'Report/table' -benchmem -memprofile mem.out ./internal/sweep \\
  > /dev/null", none),
  ("go tool pprof -sample_index=alloc_objects -top -nodecount=8 mem.out", "ch06/s6-pprof.txt"),
)

`alloc_objects` counts allocations rather than bytes, which is what matters
for garbage-collector pressure. The largest share is attributed to
`tableReporter.Close` itself, and the compiler's escape analysis says why.
`-gcflags=-m` prints its decisions. The grep below keeps the three lines of
the `fmt.Fprintf` call that prints a row; `grep -n 'fmt.Fprintf(tw' internal/sweep/report.go` gives their numbers in your copy.

#output("ch06/s6-escape.txt", cmd: read("/book/output/ch06/s6-escape-cmd.txt").trim(), size: 6.4pt)

Every argument to `fmt.Fprintf` is converted to an `interface{}`, and a
string or a `Duration` stored in an interface escapes to the heap; `~r0` is
the compiler's name for a function's result, here `symbol` and `truncate`.
(`r.Attempts` escapes too, but the runtime keeps preallocated values for
integers below 256, so small counts don't actually allocate.) The rest are
`tabwriter` buffering each line, `Duration.String` formatting the latency,
and `truncate` converting long details to runes and back.

Is it worth fixing? A version built on `strconv.AppendInt` and a reused byte
buffer would cut most of those allocations, and the benchmark would look
better. But the table is printed once per sweep, after seconds of network
I/O, and 1,000 rows cost well under a millisecond. The profile is the
evidence that settles the argument: leave `fmt.Fprintf`, which is easy to
read, where it is. Exercise 6.7 builds the faster version anyway and asks
what it would take to accept it.

=== Comparing two implementations with `benchstat`

Go 1.27 made `encoding/json` a thin layer over the new `encoding/json/v2`
engine. The release notes say marshalling performance is "broadly at
parity" and unmarshalling "significantly faster", and they keep the old
implementation available, for now, behind `GOEXPERIMENT=nojsonv2`. That
makes an honest A/B test possible: the same benchmark code, compiled twice.

#session(
  ("go test -c -o v2.test ./internal/sweep", none),
  ("GOEXPERIMENT=nojsonv2 go test -c -o v1.test ./internal/sweep", none),
  ("for i in $(seq 10); do \\
  ./v1.test -test.run '^$' -test.bench 'Report|Decode' -test.benchmem >> v1.txt; \\
  ./v2.test -test.run '^$' -test.bench 'Report|Decode' -test.benchmem >> v2.txt; \\
done", none),
  ("go run golang.org/x/perf/cmd/benchstat@latest v1.txt v2.txt", "ch06/s6-benchstat.txt"),
)

Three practices are built into that session. Both binaries are compiled
first, so neither pays for a build during the measurement. The runs are
_interleaved_, v1 then v2, ten times, so drift over the session (thermal
throttling, a backup starting, another build) affects both sides equally
instead of all landing on whichever ran second. And `benchstat` does the
arithmetic: for each benchmark it prints the median, a 95% confidence
interval as a percentage (`±`), the change, and a p-value from a
Mann-Whitney U test. A `~` means the difference is not statistically
significant.

Read the three tables from the bottom up. The allocation counts are exact
(`± 0%`), because they don't depend on how busy the machine is, and they
tell a clear story. The v2 engine decodes JSON Lines with about a fifth of
the allocations of v1, and writes the indented document with well under
half. But it makes two allocations per JSON Lines record where v1 made one:
the release notes' "broadly at parity" hides a regression for exactly the
format `sweep` streams. `Report/table` doesn't use JSON at all, and
`benchstat` correctly reports no difference: that row is the control, and
a `~` there is what you want to see.

The time table is harder to read, because the intervals are wide: this
laptop was running other builds during the measurement. Where the
allocation change is large, the time change follows it and reaches
significance anyway. Where it isn't, `benchstat` says `~` and you should
believe it. For a decision such as "is upgrading worth it for our JSON
Lines consumer", the allocation columns and a quieter machine would both
matter.

#warning(title: [One run is an anecdote])[
  While this chapter was being written, single runs of the two binaries
  disagreed with each other from one try to the next, sometimes by a
  factor of two in either direction. The `±` column explains why: on a busy
  laptop the spread between runs reaches 30% and more. Never compare two
  single runs (the troubleshooting table shows what `benchstat` says about
  them), and never compare numbers taken on different machines or on
  different days.
]

=== Why laptop and CI numbers differ

Wide intervals come from the machine, not from JSON. Here is the parser
benchmark, five times in a row, in one session on one laptop:

#output("ch06/s6-count.txt", cmd: "go test -run '^$' -bench 'ParseTargets' -count 5 ./internal/sweep | benchfmt")

Same code, same input, same machine, minutes apart, and the time per line
moves by tens of percent. That is the everyday reality of developer
machines and shared CI runners, and it is only one of the differences
between them.

- *Frequency and cores.* Laptops boost their clock until they get hot, then
  throttle. Apple silicon also mixes performance and efficiency cores, and
  a benchmark goroutine can migrate between them mid-run.
- *Neighbours.* A hosted CI runner is a virtual machine on shared hardware.
  Other tenants compete for caches and memory bandwidth, and a vCPU may be
  a hyperthread rather than a core.
- *Hardware drift.* Two runs of the same CI job can land on different CPU
  generations, and `GOMAXPROCS` (the `-10` suffix) changes with the runner
  size.
- *State.* A laptop has warm caches, a cold CI runner has none, and either
  may be running an indexer, an antivirus scan or a container.

The rules that follow are short. Compare only results from one machine in
one session. Use `-count` of at least 10, interleave A and B, and let
`benchstat` decide what is significant. Treat differences of a few percent
on shared hardware as noise. To track performance over time, either use a
dedicated, quiet machine, or run the base branch and the pull request in the
same CI job, on the same runner, and compare them to each other rather than
to history.

#needspace(14em)
#checkpoint(step: 6, of: 9, title: [Benchmarks that mean something])[
  #output("ch06/s6-status.txt", cmd: "git status -s -uall")
  The benchmarks' setup code runs as part of every `go test`, which is
  why a broken helper fails the build even when no benchmark runs; the
  numbers above are your real check. Delete `mem.out`, the `.test`
  binaries and the `.txt` results when you are done (`.gitignore` already
  keeps the first two out of `git status`).
  #block(breakable: false)[
  #troubleshoot(
    ([#ts("s6-benchpath.txt")], [`-bench` takes a regular expression, and here it took the package path, so `go test` tested the current directory.], [`-bench . ./internal/sweep`.]),
    ([#ts("s6-onerun.txt")], [`benchstat` given one run of each side: with a single sample there is no interval and no test.], [`-count 10`, or ten interleaved runs.]),
    ([#ts("s6-memprofile.txt")], [Profiling flags need exactly one package, because each package is a separate test binary.], [Name the package: `./internal/sweep`.]),
    ([#ts("s6-pprof-inuse.txt")], [`pprof` defaults to `inuse_space`: memory still live when the profile was written, which for a benchmark is almost nothing.], [`-sample_index=alloc_objects` or `alloc_space`.]),
  )
  ]
]

#step(7, 9, "Lab 7: Coverage across unit and end-to-end tests", label: <sec-test-coverage>)

`go test -cover` measures what unit tests execute. The testscript suite runs
a separate binary in separate processes, so by default it is invisible to
coverage, and a team can't tell whether the end-to-end tests are exercising
the code or just the happy path. Since Go 1.20 a binary can be built with
coverage instrumentation, so any run of it (a script, a manual smoke test,
a staging job) produces coverage data. @fig-test-coverage shows how the
pieces fit together.

#fig(caption: [Integration coverage. Every instrumented process writes its counters into `GOCOVERDIR`; `covdata` merges directories and converts the result to the classic profile format for `go tool cover`.])[
  #diagram(
    spacing: (22pt, 12pt),
    dnode((0, 0), [`go test -cover`\ `-test.gocoverdir`], kind: "default"),
    dnode((0, 1), [testscript suite\ `sweep` built with `-cover`], kind: "default"),
    dnode((0, 2), [manual or staging run\ `GOCOVERDIR=dir sweep`], kind: "muted"),
    dnode((1, 0), [`cov/unit`], kind: "accent"),
    dnode((1, 1), [`cov/e2e`], kind: "accent"),
    dnode((2, 1), [`covdata merge`\ `cov/all`], kind: "dark"),
    dnode((3, 0), [`covdata percent`], kind: "good"),
    dnode((3, 1), [`covdata textfmt`\ → `cover -func`, `-html`], kind: "good"),
    dedge((0, 0), (1, 0), "-|>"),
    dedge((0, 1), (1, 1), "-|>"),
    dedge((0, 2), (1, 1), "--|>"),
    dedge((1, 0), (2, 1), "-|>"),
    dedge((1, 1), (2, 1), "-|>"),
    dedge((2, 1), (3, 0), "-|>"),
    dedge((2, 1), (3, 1), "-|>"),
  )
] <fig-test-coverage>

The end-to-end harness needs one change: build `sweep` with `-cover` when
`GOCOVERDIR` is set. Replace `buildSweep` in `sweepscript/script_test.go`:

#src("workbook/ch06/step7/sweepscript/script_test.go", region: "build")

testscript passes `GOCOVERDIR` on to every process a script starts, so each
run of `sweep` in a script writes its counters there.

=== One binary, one run

Start with a single run against the fake fleet from Chapter 4. Start
`go run ./cmd/fleet` in a second terminal, and make a two-line inventory:

#output("ch06/s7-cat.txt", cmd: "cat cov.txt")
#session(
  ("go build -cover -o sweep-cover ./cmd/sweep", "ch06/s7-build.txt"),
  ("mkdir -p cov/run && GOCOVERDIR=cov/run ./sweep-cover cov.txt", "ch06/s7-run.txt"),
)

The run looks like any other. The difference is in `cov/run`:

#session(
  ("ls cov/run", "ch06/s7-ls.txt"),
  ("go tool covdata percent -i=cov/run", "ch06/s7-percent.txt"),
)

`go build -cover` instruments every package of the main module that the
binary links (`-coverpkg` narrows or widens that). Each process writes one
_counters_ file named after the binary's hash, its process ID and a
timestamp, and the first process writes one _meta-data_ file per binary
that describes the code (the book shortens the 32-digit hash to
`<hash>` in every listing). If
`GOCOVERDIR` is unset, the binary runs normally and prints a warning, as
the troubleshooting table shows. A single run with two targets already
reaches a fair share of the code; the zeros are as telling, and the next
step makes them precise.

=== Unit and end-to-end, merged

The unit tests write raw coverage data with the test binary's
`-test.gocoverdir` flag, which the `testing` package defines but
`go help testflag` doesn't list. `-args` passes it through to every test
binary, and the path must be absolute, because each test binary runs in its
own package directory. The testscript suite needs only `GOCOVERDIR`:

#output("ch06/s7-unit.txt", cmd: "mkdir -p cov/unit && go test -cover ./cmd/sweep ./internal/sweep ./conc ./retry ./lifecycle \\
  -args -test.gocoverdir=\"$PWD/cov/unit\"")
#output("ch06/s7-e2e.txt", cmd: "mkdir -p cov/e2e && GOCOVERDIR=$PWD/cov/e2e go test -count=1 ./sweepscript")
#output("ch06/s7-e2e-percent.txt", cmd: "go tool covdata percent -i=cov/e2e")

Merging takes a comma-separated list of input directories:

#session(
  ("mkdir -p cov/all && go tool covdata merge -i=cov/unit,cov/e2e -o=cov/all", "ch06/s7-merge.txt"),
  ("go tool covdata percent -i=cov/all", "ch06/s7-all-percent.txt"),
  ("go tool covdata textfmt -i=cov/all -o=cov/all.out", "ch06/s7-textfmt.txt"),
  ("go tool cover -func=cov/all.out | sort -k3 -n | head -12", "ch06/s7-func.txt"),
)

Compare the three `percent` listings. The end-to-end suite alone covers more
of `cmd/sweep` than the unit tests do, because it runs `main` and the real
flag parsing, which no unit test calls; the unit tests cover more of
`internal/sweep`, because they reach error paths that need a fake to
trigger. The merge is higher than either, and the difference between the
merge and each input is the code only one layer reaches.

The function list, sorted by coverage, is where the map becomes useful.
The caching resolver's `LookupHost`, `cached` and `store` have never run,
in any test: every target in every test is an IP address, so `sweep`'s
DNS cache, the code that keeps a sweep of 500 URLs on 20 hosts down to 20
lookups, is untested. Exercise 6.4 fixes that. The `Error` methods in
`retry` show that no test ever prints a retry error's message, and the
DNS prober's 50% is its whole error handling: no test has ever made a
lookup fail, so the rule that a missing name is a permanent failure,
not worth a retry, is unchecked. None of that is visible from a single percentage.

#production(title: [Use coverage as a map, not a target])[
  A coverage percentage as a merge gate invites tests that execute code
  without checking anything. Use merged coverage to answer specific
  questions instead. Which error paths have never run? Does the end-to-end
  suite reach the code a change touched? Did a refactor orphan a branch?
  `go tool cover -html=cov/all.out` shows the answers line by line. If you
  do want a gate, gate on coverage of the _changed_ lines in a pull
  request, which can't be satisfied by testing something else.
]

#needspace(14em)
#checkpoint(step: 7, of: 9, title: [Coverage across layers])[
  If the end-to-end run fails with "coverage meta-data emit failed", run it
  again, and read Lab 8, which explains it. When you are done, stop the
  fleet and clean up with `rm -rf cov sweep-cover cov.txt`. (`cov/` and
  `sweep-cover` are in `.gitignore` anyway.) The list is the same as after
  Lab 6, because the one file this lab changed was already new:
  #output("ch06/s7-status.txt", cmd: "git status -s -uall")
  #troubleshoot(
    ([#ts("s7-nocoverdir.txt")], [A `-cover` binary ran without `GOCOVERDIR`. It works normally and records nothing.], [Set `GOCOVERDIR` to an existing directory.]),
    ([#ts("s7-relative.txt")], [A relative `-test.gocoverdir`: each test binary runs in its package directory, where `cov/unit` doesn't exist.], [Use an absolute path: `"$PWD/cov/unit"`.]),
    ([#ts("s7-mergeout.txt")], [`covdata merge` writes into an existing directory only.], [`mkdir -p` the output directory first.]),
    ([#ts("s7-nocover.txt")], [The harness built `sweep` without `-cover`, so the scripts wrote no data.], [Add the `GOCOVERDIR` check to `buildSweep`.]),
  )
]

#step(8, 9, "Lab 8: Flaky tests", label: <sec-test-flaky>)

A flaky test passes and fails on the same code. One flaky test in a suite of
a thousand, failing 1% of the time, is enough to teach a team that red
builds don't mean anything, and from then on real failures get retried
instead of read. Flakiness has a small number of causes. In this lab you
reproduce the common ones on purpose, in a small package of broken tests,
and then diagnose a real one that the coverage runs of Lab 7 can hit.

*Time.* Sleeps instead of synchronisation, and timeouts tuned on a fast
laptop that fire on a loaded CI runner or under `-race`. The fixes are the
ones used throughout this chapter: `synctest` for timers, and waiting for
an observable event (`waitreq`, `Fleet.WaitFor`) instead of sleeping.

*Order and shared state.* Package-level variables, caches, environment
variables and the working directory survive from one test to the next. A
test that passes alone and fails after another test has run is not
independent. Create a package `flaky` in your module, starting with its
documentation and a check registry kept in a package-level map, like the
ones many tools keep:

#src("workbook/ch06/step8/flaky/doc.go")
#src("workbook/ch06/step8/flaky/registry.go")

#goconcept(title: [Build constraints])[
  A `//go:build` line at the top of a file, before the `package` clause and
  followed by a blank line, decides whether the file is part of a build.
  `//go:build linux` limits a file to Linux, `//go:build !race` leaves it
  out of `-race` builds, and a made-up tag such as `flakydemo` leaves the
  file out unless you ask for it with `go test -tags flakydemo`. Tags are
  how slow, platform-specific or deliberately broken tests stay out of
  `go test ./...`. Their risk is the opposite one: nothing runs a tagged
  file unless some command names the tag, so a CI job must own every tag.
]

The tests are deliberately broken, so they only build with that tag.
Create `flaky/flaky_test.go`:

#src("workbook/ch06/step8/flaky/flaky_test.go", region: "head")
#src("workbook/ch06/step8/flaky/flaky_test.go", region: "order")

Two flags find order dependence. `-count=2` runs each test twice in the same
process, so state left by the first run meets the second, and both tests
fail:

#output("ch06/s8-count.txt", cmd: "go test -tags flakydemo -count=2 -run 'TestRegistry|TestRegister' ./flaky")

`-shuffle=on` randomises the order and prints the seed, and passing the seed
back replays the failing order exactly:

#output("ch06/s8-shuffle.txt", cmd: "go test -tags flakydemo -count=1 -shuffle=on -run 'TestRegistry|TestRegister' ./flaky")
#output("ch06/s8-replay.txt", cmd: "go test -tags flakydemo -count=1 -shuffle=" + read("/book/output/ch06/s8-seed.txt").trim() + " -run 'TestRegistry|TestRegister' ./flaky")

The fix is to stop sharing: make the registry a value that `main` creates
and passes down, so each test makes its own.

*Lifetimes in parallel tests.* The `defer` trap from Lab 1 fails every time,
which makes it easy to fix, but the same mistake with a fixture that closes
slowly fails only sometimes. Add this test:

#src("workbook/ch06/step8/flaky/flaky_test.go", region: "defer")
#output("ch06/s8-defer.txt", cmd: "go test -tags flakydemo -count=1 -run 'TestEndpoints' ./flaky")

And process-wide settings in a parallel test are refused outright:

#src("workbook/ch06/step8/flaky/flaky_test.go", region: "setenv")
#output("ch06/s8-setenv.txt", cmd: "go test -tags flakydemo -count=1 -run 'TestProxyFromEnvironment' ./flaky 2>&1 | head -2 | fold -s -w 88")

*Ports.* A test that listens on a fixed port fails when anything else on
the runner holds it, including another package's tests running in
parallel. Listen on port 0 and read the address back, as `httptest` does.
The `closedPort` helper in Chapter 4's tests and `refusedAddr` in Lab 4
listen on port 0, close the listener and hand the address out as
"refused", which leaves a small window in which another process could take
the port. It is a reasonable
trade for a test helper; it is not a pattern for anything that must be
reliable.

=== A flake in the toolchain

The strangest flake in this chapter came from the coverage runtime. While
it was being written, the testscript suite with `GOCOVERDIR` set failed
twice in its first fifteen runs, in the `help` script, whose `cmp stderr`
found an unexpected first line: "error: coverage meta-data emit failed".
Reading `internal/coverage/cfile/emit.go` in the Go source explains it. The
first process to exit writes the meta-data file through a temporary file
named after the meta-data hash and `time.Now().UnixNano()`, then renames it
into place. On macOS that clock reading has microsecond granularity, so two
processes that exit in the same microsecond pick the _same_ temporary name,
one rename wins, and the other fails. The data survives, because both
processes write identical meta-data, but the error lands on stderr, where
the script compares it.

A dozen suite runs is a slow way to study a bug. Shrink it to the smallest
program that still reproduces it: build `sweep` with `-cover`, start eight
copies at once into a fresh `GOCOVERDIR`, and repeat until one of them
complains. Create `flaky/covrace.sh` and make it executable
(`chmod +x flaky/covrace.sh`):

#src("workbook/ch06/step8/flaky/covrace.sh")
#output("ch06/s8-covrace.txt", cmd: "flaky/covrace.sh")

The fix in the harness is to give each script its own coverage directory,
so processes from different scripts never share a temporary name. Add this
function to `sweepscript/script_test.go`:

#src("workbook/ch06/step8/sweepscript/script_test.go", region: "coverdir")

and call it from `Setup`, right after `PATH` is set. Here is `TestScripts`
with the call in place:

#src("workbook/ch06/step8/sweepscript/script_test.go", region: "run")

Thirty runs of the suite with coverage on, each into a fresh directory:

#output("ch06/s8-after.txt", cmd: "for i in $(seq 30); do \\
  rm -rf cov/e2e && mkdir -p cov/e2e && \\
  GOCOVERDIR=$PWD/cov/e2e go test -count=1 ./sweepscript > /dev/null 2>&1 \\
    && echo pass || echo FAIL; \\
done | sort | uniq -c")

The coverage data is now in one directory per script, named after the
script's work directory, and the merge from Lab 7 lists them:

#output("ch06/s8-ls.txt", cmd: "ls cov/e2e")
#session(
  ("mkdir -p cov/all && go tool covdata merge -i=\"cov/unit,$(echo cov/e2e/* | tr \" \" ,)\" -o=cov/all", "ch06/s8-merge.txt"),
  ("go tool covdata percent -i=cov/all", "ch06/s8-all-percent.txt"),
)

The general lesson is about method rather than coverage: shrink a flake to
the smallest program that still reproduces it, then read the code that
fails, even when that code is the toolchain's.

=== Detecting flakes before they spread

`-count=N` and `-shuffle=on` catch leaked state and order dependence; log
the shuffle seed in CI so any failure can be replayed. `-race` catches
unsynchronised access that only sometimes corrupts a result, and
`-cpu 1,2,8` runs every test once per `GOMAXPROCS` value to shake out
assumptions about parallelism. For a single suspect test,
`golang.org/x/tools/cmd/stress` runs the test binary repeatedly under load
and keeps the output of every failure. Across a whole organisation, the
cheapest detector is CI that records which tests failed and then passed on
the same commit, and reports that list every week.

=== A CI strategy for slow and Docker-dependent tests

Not every test belongs in every pipeline run. The goal is a fast loop that
catches most bugs on every push, plus slower jobs that catch the rest
before release:

#table(
  columns: (auto, 1fr, auto),
  table.header([When], [What runs], [Budget]),
  [Every push], [`go vet`, `golangci-lint`, `go test -race -shuffle=on ./...`: units, components, goldens, fuzz seed corpora, the `run`-level CLI tests, and the testscript suite], [2 minutes],
  [Every pull request], [The testscript suite with `GOCOVERDIR` and a merged coverage report; container tests in a separate job on a Linux runner with Docker], [10 minutes],
  [Nightly], [Fuzzing, several minutes per target; benchmarks on a dedicated runner compared with `benchstat`; long soak runs with `-count=50`; every build tag], [an hour],
)

Three mechanisms keep slow tests out of the fast loop, and this chapter
uses all of them. `testing.Short()` lets a test skip itself under `-short`;
it is simple, but every developer has to remember the flag. A build tag
(`//go:build flakydemo`, or `integration`) removes files from the build
unless the tag is given; it is impossible to run by accident, and equally
easy to forget to run at all. A separate module, like the containers module
in Lab 9, keeps heavy dependencies out of the main module and gives the slow
tests their own `go.mod`, their own `go test ./...` and their own CI job.
Whichever you pick, quarantine a flaky test the day it is found (skip it
with a link to an issue that has an owner), and never let a CI system retry
failures silently.

#needspace(14em)
#checkpoint(step: 8, of: 9, title: [Flaky tests])[
  #output("ch06/s8-status.txt", cmd: "git status -s -uall")
  `go test ./...` doesn't see the broken tests, because nothing names the
  tag; the troubleshooting table shows what that looks like.
  #troubleshoot(
    ([#ts("s8-notags.txt")], [The test file has a build tag, and the command didn't name it.], [`go test -tags flakydemo ./flaky`. See "Build constraints".]),
    ([#ts("s8-defer.txt")], [The parent's `defer` closed the server before its parallel subtests ran.], [`t.Cleanup(srv.Close)`.]),
    ([#ts("s8-setenv.txt")], [`t.Setenv` in a parallel test.], [Don't parallelise tests that change process state.]),
    ([#ts("s8-covrace.txt")], [Several `-cover` processes exited at once into one `GOCOVERDIR`.], [One coverage directory per script: `coverDirPerScript`.]),
  )
]

#step(9, 9, "Lab 9: Real dependencies with testcontainers", label: <sec-test-containers>)

Fakes encode what you believe about a dependency. When the belief is wrong,
the fake is wrong in the same way, and the tests pass. The way out is to
test some paths against the real thing: the real database's wire protocol,
the real readiness sequence, the real error when it goes away. For a tool
like `sweep`, that means pointing the real probers at real servers.

`testcontainers-go` starts Docker containers from Go tests and removes them
afterwards. It brings the Docker client and several dozen modules with it,
and none of that belongs in the `go.mod` of a tool that only needs three
small dependencies. So this lab puts the container tests in a module of
their own, nested inside yours. @fig-test-containers shows the moving parts.

#fig(placement: auto, caption: [A container test. The fleet image is built from a binary cross-compiled on the host, so no base image is pulled. Ryuk, started once per test session, removes the session's containers even if the test process is killed.])[
  #diagram(
    spacing: (30pt, 20pt),
    dnode((0, 0), [`go build`\ `GOOS=linux`], kind: "default"),
    dnode((1, 0), [build context\ `fleet` + `FROM scratch`], kind: "muted"),
    dnode((0, 1), [`go test`\ test process], kind: "dark"),
    dnode((1, 1), [Docker daemon], kind: "accent"),
    dnode((2, 1), [Ryuk reaper\ watches the session], kind: "warn"),
    dnode((1, 2), [fleet container\ `:8080`], kind: "good"),
    dnode((2, 2), [postgres:17-alpine\ `:5432`], kind: "good"),
    dedge((0, 1), (0, 0), "-|>", label: [compile], label-side: left),
    dedge((0, 0), (1, 0), "-|>"),
    dedge((1, 0), (1, 1), "-|>", label: [image build], label-side: left),
    dedge((0, 1), (1, 1), "-|>", label: [API]),
    dedge((1, 1), (2, 1), "-|>"),
    dedge((1, 1), (1, 2), "-|>", label: [run], label-side: left),
    dedge((1, 1), (2, 2), "-|>", label: [run], label-side: left),
    dedge((0, 1), (1, 2), "--|>", label: [probes via\ mapped port], label-side: right),
  )
] <fig-test-containers>

=== A nested module

#goconcept(title: [Nested modules and `replace`])[
  A directory with its own `go.mod` is a separate module, even inside
  another module's tree. The outer module's `./...` stops at it, so
  `go test ./...` in `sweep` never sees the container tests and never needs
  their dependencies. The inner module imports `sweep/internal/sweep` like
  any other code would, which raises two questions. Where is module `sweep`?
  It was never published, so a `replace sweep => ../` directive points the
  `go` command at the parent directory. And may it import `internal`
  packages? Yes: the rule is about directories, and `containers` lives
  under `sweep`, the directory that contains `internal`. The book's
  repository uses the same layout for `examples/ch06/containers`.
]

Create the module next to `sweepscript`, at the top of your project:

#session(
  ("mkdir containers && cd containers", none),
  ("go mod init sweep/containers", "ch06/s9-modinit.txt"),
  ("go get go@1.27.0", "ch06/s9-gogo.txt"),
  ("go mod edit -require=sweep@v0.0.0 -replace=sweep=../", "ch06/s9-edit.txt"),
)

`go mod init` writes the `go` line of the toolchain you are running; `go get go@1.27.0` sets it to the parent module's, so the two modules agree on the
language version. The version in `sweep@v0.0.0` is a placeholder: with a
`replace` to a directory, the `go` command ignores it. Create
`containers/doc.go`, which says what the module is for:

#src("workbook/ch06/step9/containers/doc.go")

=== Skip, don't fail

Container tests need a Docker daemon, which a laptop on a plane, a macOS CI
runner or a locked-down build agent may not have. The suite must degrade to
"skipped", never to "failed". Create `containers/containers_test.go`,
starting with its imports and a guard every test calls first:

#src("workbook/ch06/step9/containers/containers_test.go", region: "head")
#src("workbook/ch06/step9/containers/containers_test.go", region: "skip")

`SkipIfProviderIsNotHealthy` asks the Docker provider for a health check and
calls `t.Skip` if it can't get one (it also recovers from a panic in the
provider). `-short` skips everything without contacting Docker at all,
which keeps the fast loop fast.

Don't try to test the skip by pointing `DOCKER_HOST` at a socket that
doesn't exist. testcontainers looks for a daemon in several places in turn
(its own properties file, `DOCKER_HOST`, the Docker context, the default
socket `/var/run/docker.sock`, a rootless socket) and uses the first one
that answers, so with Docker Desktop running, a bad `DOCKER_HOST` is
quietly skipped over and the tests still run. To see the skip, stop the
daemon.

=== Images without a registry

Pulling images from Docker Hub through Docker Desktop's proxy timed out
repeatedly on the machine this book was written on. A test that depends on a
pull inherits that flakiness, plus rate limits and registry outages. The
fleet image avoids the registry entirely: the test cross-compiles your
`cmd/fleet` from Chapter 4 for Linux and wraps it in a `FROM scratch`
image, the same trick the kind end-to-end test in Chapter 20 uses.

#src("workbook/ch06/step9/containers/containers_test.go", region: "image")

`GOARCH` follows the host, because Docker Desktop on Apple silicon runs
arm64 Linux and GitHub's standard Linux runners are amd64. `go build` runs
in the test's module, `sweep/containers`, and finds `sweep/cmd/fleet`
through the `replace`. The image has no shell and no libc, so it builds in
a second and its only content is the program under test. A helper runs
`sweep`'s real probers against a list of targets:

#src("workbook/ch06/step9/containers/containers_test.go", region: "sweeponce")

and the first test runs the fleet image and checks three of its paths:

#src("workbook/ch06/step9/containers/containers_test.go", region: "fleet")

`testcontainers.Run` builds the image, starts the container and waits until
`/ok` answers on port 8080. Two habits in this test are worth copying.
`CleanupContainer` is registered _before_ the error check, because `Run`
can return a container that started and then failed its wait strategy, and
that container still needs removing. And the test never uses a fixed host
port: `PortEndpoint` returns whatever port Docker mapped, so parallel test
runs on one machine don't collide.

=== A real database going away

The second test uses `postgres:17-alpine`. If the image is in the local
cache, testcontainers doesn't pull it (run `docker pull postgres:17-alpine`
once beforehand). The test checks the database, stops it, and checks again:

#src("workbook/ch06/step9/containers/containers_test.go", region: "postgres")

The wait strategy encodes a piece of PostgreSQL folklore that a fake would
never teach you. On first start, the official image's entrypoint runs
`initdb`, starts a temporary server (on a Unix socket only) to apply init
scripts, stops it, and then starts the real server, so "database system is
ready to accept connections" appears twice. Waiting for the first
occurrence produces a test that passes on a fast laptop and fails on a
loaded CI runner when the probe lands in the gap.

Now let the `go` command fill in the dependencies:

#session(
  ("go get github.com/testcontainers/testcontainers-go@v0.44.0 2>&1 | tail -3", "ch06/s9-goget.txt"),
  ("go mod tidy", "ch06/s9-tidy.txt"),
)

`tail` keeps the last of about sixty lines, one per module added. All of
them are recorded in `containers/go.mod`; your `sweep/go.mod` is unchanged.
With `-short`, nothing touches Docker:

#output("ch06/s9-short.txt", cmd: "go test -count=1 -short -v ./... | grep -E '^ *(=== RUN|--- |ok|PASS|FAIL|containers_test)'", size: 6.8pt)

And with Docker running, the real thing. testcontainers logs every step to
stderr; without those lines, the run looks like this:

#output("ch06/s9-run.txt", cmd: "go test -count=1 -v ./...", size: 6.8pt)

An image build, two containers and a database stop took a few seconds. The
log line from the PostgreSQL test shows the real error after the stop:
Docker's port forwarder refuses the connection, `sweep` classifies
"connection refused" as retryable, and gives up after three attempts.
testcontainers' own log, filtered from the same run, shows the other moving
parts:

#output("ch06/s9-log.txt", title: "testcontainers log, excerpt")

Before the first container, testcontainers started Ryuk, a reaper container
that removes everything labelled with the test session's ID if the test
process dies without cleaning up. The `testcontainers/ryuk` image does come
from Docker Hub, once. Where pulls are unreliable, mirror the Ryuk image into
your own registry, or disable it with `TESTCONTAINERS_RYUK_DISABLED=true`
and rely on `CleanupContainer`, accepting that a killed test run can leave
containers behind.

#warning(title: [Container tests are integration tests])[
  They are slower (seconds, not milliseconds), they need a daemon, and they
  can fail for reasons that have nothing to do with your code: disk full,
  a stale image, a port forwarder that is slow to release. Keep them few
  and focused on what fakes can't show, put them behind `-short` or a
  separate module, and run them in their own CI job so a Docker problem
  doesn't block a one-line fix to a parser.
]

#needspace(14em)
#checkpoint(step: 9, of: 9, title: [Real dependencies])[
  Back in the top directory of your project (`cd ..`), the outer module
  is unchanged except for the files the labs added, and its tests don't
  reach into `containers`:
  #output("ch06/s9-status.txt", cmd: "git status -s -uall")
  #output("ch06/s9-test.txt", cmd: "go vet ./... && go test -race ./...")
  The test files in your `sweep` now match the ones the book's repository
  runs against its production `sweep`, line for line.
  #troubleshoot(
    ([#ts("s9-noreplace.txt")], [The `replace` directive is missing, so `go` treats `sweep` as a module to download, and a path without a dot can't be one.], [`go mod edit -replace=sweep=../`.]),
    ([#ts("s9-goos.txt")], [The binary was built for the host OS (here macOS), and a Linux container can't run it.], [`GOOS=linux` in the build environment, with `CGO_ENABLED=0`.]),
  )
]

== A test strategy for a platform team <sec-test-strategy>

Platform tools have an unusual property: their users are other engineers'
pipelines. A regression in a service shows up as an error rate; a
regression in a deploy gate shows up as a release that shipped when it
shouldn't have, weeks before anyone connects the two. The nine labs follow
the contracts, layer by layer, and the same order works for any tool:

+ *Exit status and streams.* Pin them end to end, against the real binary,
  for every documented status (Lab 4). This is the contract every caller
  depends on.
+ *Machine-read output.* Golden files for every format another program
  parses, reviewed like API changes (Lab 3).
+ *Behaviour against dependencies.* Fakes at the consumer's interface for
  logic such as retries, limits and classification; protocol-level fakes
  such as `sweeptest` and Chapter 20's `ddfake` for clients (Lab 2); a few
  container tests for what fakes can't know (Lab 9).
+ *Input from humans.* Table tests for the documented syntax and fuzz
  targets for everything else (Labs 1 and 5).
+ *Visibility.* Merged unit and end-to-end coverage, read as a map of what
  has never run (Lab 7), and a pipeline that surfaces flakes instead of
  retrying them (Lab 8).

#production(title: [At 200 engineers and 1,000 services])[
  The test code that pays off most is shared fakes. When every team writes
  its own fake of the internal deployment API, the fakes drift from the real
  API and from each other, and each one encodes a slightly different
  misunderstanding. Make the team that owns an API also own its fake (a
  `xxxtest` package next to the client, like `httptest` next to `http` and
  `sweeptest` next to `sweep`), and run the fake and the real service
  through the same contract tests, so they can't drift apart without a test
  failing. Keep test-time budgets too. A root-module suite that creeps from
  two minutes to twenty gets run less, then skipped, and the end result is
  worse than having fewer tests.
]

#interview(title: [“How would you test a CLI tool?”])[
  Start from the contract: arguments, stdin, stdout, stderr, exit status,
  signals. Structure `main` as a thin wrapper around
  `run(ctx, args, stdin, stdout, stderr) int`, so most behaviour is
  unit-testable without a process. Test parsers with tables and fuzzing,
  output formats with golden files, and dependencies through small
  interfaces with fakes. Then test the real binary end to end with
  `testscript`: exact exit codes, nothing on stdout for usage errors, a real
  `SIGINT` producing a partial report. Build that binary with `-cover` and
  merge the coverage, so you know what the end-to-end layer reaches.
]

#interview(title: [“How would you test a Kubernetes controller?”])[
  The same layers with different names. Pure functions (desired-state
  builders, status calculations) get table tests. The reconciler runs
  against envtest, a real API server and etcd without nodes, with external
  APIs replaced by protocol-level fakes like `ddfake`, and with assertions
  on the resulting objects, conditions and events rather than on calls.
  Idempotency gets its own test: reconcile twice and assert nothing
  changed. A kind cluster runs the real image end to end, including RBAC
  and the webhook configuration, which envtest doesn't exercise. Chapter 20
  builds all three, and its kind test caught a bug the other two missed.
]

#takeaways(
  [Every external dependency needs a seam (an interface, a writer, a context, an argument list), and every layer of the pyramid catches bugs the others can't: many fast unit tests, fewer component tests with fakes, a handful of end-to-end and real-dependency tests.],
  [Table tests should name cases by their input, compare with `cmp.Diff`, and use `t.Parallel` only for cases that share nothing. `t.Context` and `t.Chdir` (Go 1.24) remove two common hacks.],
  [Prefer fakes at the consumer's interface; mocks couple tests to call sequences. Reach for a mocking library only when the interaction is the behaviour.],
  [Golden files pin machine-read output. Make inputs deterministic first; scrub structurally when you can't; review `-update` diffs like API changes.],
  [Test the real binary with `testscript`: exact exit codes, separated streams, stdin, and real signals, in parallel and with no shell.],
  [Fuzz every parser of human or foreign input, with properties taken from its contract. Here it found two real bugs, and the corpus keeps them from coming back.],
  [Benchmarks need `b.Loop`, `-benchmem`, interleaved runs and `benchstat` on one machine; profiles decide whether an allocation matters.],
  [Merge `GOCOVERDIR` data from unit and end-to-end runs and read it as a map of code that has never run.],
  [Flakes come from time, shared state, lifetimes and ports. `-count`, `-shuffle` and `-race` find them; shrinking one to the smallest reproduction explains it.],
  [`testcontainers-go` tests what fakes can't know. Keep it in a nested module, build images from host-compiled binaries to avoid registries, and skip cleanly without Docker.],
)

#exercise-set(6,
  (
    tier: "warm-up",
    title: [An empty inventory],
    body: [
      `sweep` exits 0 when its inventory has no targets: it checks nothing,
      finds nothing down, and the deploy gate passes. An empty file is
      almost always a mistake (a truncated download, a wrong path, a template
      that rendered nothing). Make `sweep` treat an inventory with no
      targets, from files or from stdin, as a usage error: exit status 2,
      `sweep: no targets in the inventory` on stderr, nothing on stdout.
      The acceptance test is a testscript script; copy it into
      `sweepscript/testdata/script/`, watch it fail, then fix `run`.
    ],
    hint: [The check belongs in `run`, right after the targets are read. Which existing test in `cmd/sweep` now has a case to add?],
    tests: "workbook/ch06/exercises/ex1",
  ),
  (
    tier: "warm-up",
    title: [A line too long],
    body: [
      `ParseTargets` reads lines with `bufio.Scanner`, whose limit is
      64 KiB per line. Fuzzing never reaches that limit, because the fuzzer
      keeps inputs small. Feed the parser a 70 KiB line and the error is
      `reading targets: bufio.Scanner: token too long`, with no line number,
      unlike every other inventory error. Make it report the line, like the
      others (`line 3: too long (limit 64 KiB)`), together with any errors
      found before it.
    ],
    hint: [`errors.Is(err, bufio.ErrTooLong)` after the loop. Which line was the scanner on when it gave up?],
    tests: "workbook/ch06/exercises/ex2",
  ),
  (
    tier: "warm-up",
    title: [A stronger property],
    body: [
      `FuzzParseRetryAfter` checks that an accepted delay is never
      negative. RFC 9110 says more: `Retry-After` is either an HTTP date or
      `delay-seconds`, one or more ASCII digits. Add that property to the
      fuzz target (an accepted value that is not a valid HTTP date must be
      all digits) and fuzz. What does the fuzzer find, and why did the old
      property miss it? Fix `parseRetryAfter` so the acceptance test, which
      pins the grammar, passes. A value of digits too long for an `int64`
      is valid and means "a very long time".
    ],
    hint: [`strconv.ParseInt` accepts more than digits. `http.ParseTime` tells you whether a value is a date.],
    tests: "workbook/ch06/exercises/ex3",
  ),
  (
    tier: "core",
    title: [Cover the resolver],
    body: [
      Merged coverage shows that `CachingResolver.LookupHost`, the cache that
      lets `sweep` resolve each hostname once, never runs in a test: every
      test target is an IP address. Make it testable without a DNS server,
      by changing `CachingResolver` to depend on a one-method interface
      declared at the consumer, and make the acceptance tests pass. They
      check that 50 concurrent lookups of one name cause exactly one
      resolver call, that the TTL is honoured, in virtual time, and that a
      dial goes to the resolved address. What did the change cost the
      production code?
    ],
    hint: [`*net.Resolver` must still satisfy the interface; `main` passes one.],
    tests: "workbook/ch06/exercises/ex4",
  ),
  (
    tier: "core",
    title: [Certificates that expire on demand],
    body: [
      `sweep`'s `TLSProber` reports a certificate that expires within
      `-min-cert-validity` as down, permanently and after one attempt.
      Chapter 4 tests that with a fake dialer. Test it over a real TLS
      handshake instead: add `sweeptest.NewTLSServer(t, notAfter)`, which
      starts the fake fleet over TLS with a self-signed certificate that
      expires at `notAfter` and returns the server and a pool that trusts
      it, and make the acceptance test pass. Then answer: what would the
      same test in a container (Lab 9) check that this one doesn't?
    ],
    hint: [`httptest.NewUnstartedServer`, a `tls.Config` with your certificate, `StartTLS`. `crypto/x509` makes certificates; a self-signed one is its own parent.],
    tests: "workbook/ch06/exercises/ex5",
  ),
  (
    tier: "core",
    title: [A flake budget],
    body: [
      Design a nightly CI job (for any CI system) that runs your module's
      tests with `-shuffle=on -count=5`, records the shuffle seed of every
      failure, and opens an issue with the exact replay command. Write the
      job, then introduce a deliberate order dependency like Lab 8's
      registry and check that the job would catch it. Then answer the hard
      part: how do you stop the job itself from becoming the thing everyone
      ignores?
    ],
    hint: [`go test -json` reports each test's result and output as JSON events; `-shuffle` prints its seed before the tests run.],
  ),
  (
    tier: "stretch",
    title: [Benchmark the alternative],
    body: [
      Lab 6 decided not to optimise the table reporter. Do it anyway:
      rewrite `tableReporter.Close` so it makes at most two allocations per
      row, with byte-identical output (the golden files from Lab 3 must stay
      green). The acceptance test bounds the allocations with
      `testing.AllocsPerRun`. Compare old and new with interleaved runs and
      `benchstat`, then time a real sweep of 300 targets with each. Write
      down the threshold at which you would accept the faster, harder-to-read
      version.
    ],
    hint: [`tabwriter` buffers every cell. Compute the column widths in one pass, then append each row into one reused `[]byte`.],
    tests: "workbook/ch06/exercises/ex7",
  ),
)
