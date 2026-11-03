#import "../template/book.typ": *

#chapter(6, "Testing Tools That Touch the Real World", label: <ch-testing>,
  abstract: [
    Platform tools are mostly side effects: they dial sockets, read files a
    human wrote, print tables a human reads and JSON a pipeline parses, exit
    with a status that decides whether a release ships, and react to
    #kbd("Ctrl-C"). Each of those is a contract, and each is easy to break
    without noticing. This chapter takes `sweep`, the fleet checker from
    Chapter 4, and builds the test suite a tool like it deserves, from
    table-driven unit tests to the real binary under real signals, real
    containers, fuzzing, benchmarks and merged coverage. Along the way the
    fuzzer finds two real bugs.
  ],
  learn: (
    [Where the seams are in a tool that touches networks, clocks, files and processes, and what each layer of the test pyramid buys you],
    [Table-driven tests that read well and fail clearly, and the `testing` features added in Go 1.24 to 1.27],
    [Golden files with `-update`, and how to keep them deterministic],
    [End-to-end tests of the real binary with `testscript`: exit codes, stdout and stderr, stdin, signals],
    [Fakes over mocks, interfaces at the consumer, and when a mocking library is worth it],
    [Real dependencies with `testcontainers-go`, without depending on a registry],
    [Fuzzing, benchmarking with `b.Loop` and `benchstat`, and integration coverage with `GOCOVERDIR`],
    [Why tests become flaky, how to catch it, and how to tier a CI pipeline],
  ),
  build: [
    A complete test suite for *`sweep`*: unit, golden, fake-driven, fuzz,
    end-to-end, container and benchmark tests, with coverage merged across
    all of them. Two parser bugs found by fuzzing are fixed on the way.

    #v(4pt)
    *`sweeptest`*, a fake fleet of HTTP endpoints in the spirit of
    `net/http/httptest`, reused by the unit tests, the end-to-end scripts, a
    demo server and a container image.
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
that lets a test take control of it, and the technique this chapter uses.

#figure(
  table(
    columns: (auto, 1fr, 1fr),
    table.header([The world], [Seam in `sweep`], [Technique]),
    [Network], [The one-method `Prober` interface; an injected `*http.Client` and dial function], [Hand-written fakes, `httptest` servers, the `sweeptest` fake fleet, containers],
    [Clock], [None needed: timers and sleeps go through the `time` package], [`testing/synctest` bubbles (Chapter 4)],
    [Filesystem], [Inventory paths come from arguments; output goes to an `io.Writer`], [`t.TempDir`, `t.Chdir`, golden files],
    [Process], [`run(ctx, args, stdin, stdout, stderr) int` instead of `os.Exit` in `main`], [Calling `run` directly; `testscript` against the built binary],
    [Signals], [`lifecycle.NotifyContext` turns signals into a context cause], [A real `SIGINT` from a test script],
    [Real services], [Probers dial real addresses], [`testcontainers-go`],
  ),
  caption: [What `sweep` touches, and how its tests take control.],
  kind: table,
) <tab-test-seams>

Every row has the same shape. Production code takes the dependency as a
parameter (an interface, a writer, a context, a list of arguments) instead
of reaching for a global, and the test passes something it controls. When
code does reach for a global (`os.Args`, `os.Stdout`, `time.Now`,
`http.DefaultClient`), the test has to fight it with environment hacks or
not test it at all.

=== The pyramid for tools

The test pyramid is an old idea: many fast, narrow tests at the bottom, a few
slow, broad ones at the top. For CLIs and controllers the layers have
concrete names, shown in @fig-test-pyramid.

#fig(caption: [The test pyramid for a CLI such as `sweep`, with the time one test takes on a laptop and roughly how many a mature tool has. A controller has the same layers: reconcile helpers, envtest with faked external APIs, and a kind cluster on top.])[
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
class of bug the others can't, and the rest of this chapter goes up the
pyramid one layer at a time, then back down to fuzzing, benchmarks and
coverage.

== Table-driven tests done well <sec-test-tables>

A table-driven test lists cases as data and runs the same assertions over
each. Go programmers write them reflexively. Writing them _well_ comes down
to four things: names that work as filters, a failure message that says
what was expected, a comparison that shows a diff, and parallelism used only
where it is safe. Here is the test for `ParseTargets`:

#src("internal/sweep/target_test.go", region: "table")

*Names are paths.* `t.Run` turns spaces into underscores and keeps slashes,
so a name like `tcp/ipv6 literal` puts the case in a group. The `-run` flag
splits its pattern on slashes and matches each level separately, so you can
run one group of one test:

#output("ch06/table-run.txt", cmd: "go test -count=1 -v -run '^TestParseTargets$/^(tcp|tls)$' ./internal/sweep")

Choose names that describe the _input_, not the expected outcome. "tcp/ipv6
literal" says what is special about the case; "returns correct host" says
nothing when it fails.

*Compare a projection with `go-cmp`.* `Target` holds a `*url.URL`, and
comparing whole URLs drags every parser detail into the test. The test maps
each target to a small `parsed` struct with only the fields the behaviour is
about, and compares slices of those with `cmp.Diff`. The output is a
readable diff, conventionally labelled `(-want +got)`, rather than
`reflect.DeepEqual`'s bare `false`. `cmp.Diff` also refuses to compare
unexported fields unless you tell it how (`cmpopts.IgnoreUnexported`,
`cmp.AllowUnexported`, or a `cmp.Transformer`), which is a feature: a test
that silently compares a struct's private cache is a test that breaks on
refactors.

*Error cases get their own table.* Mixing "want a value" and "want an error"
in one table leads to cases with half their fields meaningless.
`TestParseTargetsRejects` maps a case name to an input and a substring of
the expected error. Because it is a map, the iteration order is random,
which costs nothing and gives every run a free shuffle. Two of its cases,
`port out of range` and `port zero`, were added after the fuzzer in
@sec-test-fuzz found the bug they pin down.

=== `t.Parallel` and its traps

Both loops call `t.Parallel()`, which pauses the subtest and resumes it
alongside the other parallel subtests once the parent function returns.
Since Go 1.22 each loop iteration has its own `tc`, so the old
`tc := tc` copy is gone. Three traps remain, and @sec-test-flaky shows the
first two failing for real:

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
throughout this chapter.

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

`t.Chdir` is how `TestRunGolden` in @sec-test-golden passes the inventory
to `sweep` as a relative path, the way a user types it. It comes with a
trap of its own: after the `Chdir`, every relative path in the test resolves
against the new directory, including `testdata/`. The golden helper in
`cmd/sweep` resolves golden files against the package directory captured at
start-up for that reason.

Two smaller additions help end-to-end tests. Go 1.25's `t.Attr(key, value)`
emits a key and value into the test log (an `attr` action in
`go test -json`), a clean way to hand CI a container ID or a trace link.
Go 1.26's `t.ArtifactDir()` is a directory for files a failing test wants to
leave behind, such as a container's logs; with `go test -artifacts` it
survives under `-outputdir`, otherwise it is removed after the test.

The flags you will use most are `-run` and `-skip` (regular expressions per
subtest level), `-count=1` (bypass the test result cache, which otherwise
replays a passing result when nothing changed), `-race`, `-short`, and
`-timeout`, whose expiry panics and dumps every goroutine, which is how you
find a hung test. `-count=N` and `-shuffle` are flake detectors and appear in
@sec-test-flaky.

== Golden files <sec-test-golden>

`sweep` has four output formats, and two of them are machine-read. The JSON
document feeds dashboards, the JSON-lines stream feeds `jq` filters and the
deploy gate, and the table is read by people who will notice when a column
moves. Asserting on output with `strings.Contains` checks that some text is
present. It can't tell you that a field was renamed, a column re-ordered, or
a long error truncated in a new place.

A _golden file_ stores the exact expected output next to the test. The test
renders the output and compares it byte for byte. When the output changes
on purpose, you rerun the test with `-update`, which rewrites the file, and
the change to the golden file shows up in the pull request, where a reviewer
can see precisely how the output changed.

#src("internal/sweep/report_test.go", region: "golden")

The helper is about twenty lines and doesn't need a library. Two details matter. The
comparison is by lines: an early version passed two strings to `cmp.Diff`,
which reports long strings as byte ranges, and the failure was unreadable.
And the `-update` flag is a package-level flag, so `go test -update` only
works for packages that define it. Run it for a single package
(`go test ./internal/sweep -update`), never across the module, and never in
CI.

=== Determinism first, scrubbing second

A golden file is only useful if the output is identical on every run, on
every machine. Output from a real sweep contains three things that change:
latencies, the elapsed time, and the order in which results arrive. The
first rule is to remove them at the source, by feeding the reporter fixed
input instead of running a sweep:

#src("internal/sweep/report_test.go", region: "fixture")

Every value is pinned, including the 42 ms latency and the 2.14 s elapsed
time, and the results are listed in a scrambled _completion_ order on
purpose. The table and JSON reporters sort by input index, so their golden
files prove the sorting works. The JSON-lines reporter streams in completion
order, so its golden file pins that order instead. `TestReportersGolden`
renders the fixture through each of the four reporters and hands the bytes
to `golden`. The golden table is a file anyone can read in review:

#src("internal/sweep/testdata/golden/report-table.golden")

Now the payoff. Suppose someone decides that `latency_ns` is an awkward name
and renames the JSON field to `latency_ms`, leaving the value in
nanoseconds. Every `jq` filter and the deploy gate that read the field
silently get `null`. The capture script makes exactly that edit to
`runner.go` and runs the JSON case:

#output("ch06/golden-diff.txt", cmd: "go test -count=1 -run 'TestReportersGolden/^json$' ./internal/sweep 2>&1 | head -15")

The rename turns into a red test with a diff that names the field. If the
rename is intended, `-update` accepts it and the reviewer sees five changed
lines in `report-json.golden`, which is the moment to ask who consumes that
field.

When the output comes from a real run, you can't pin everything. The
end-to-end golden test in `cmd/sweep` runs the whole CLI against the fake
fleet from @sec-test-fakes over real sockets, so ports are chosen by the
kernel and timings are real. Here the rule is to scrub what varies,
structurally where possible:

#src("cmd/sweep/golden_test.go", region: "scrub")

`TestRunGolden` writes an inventory into a temporary directory, calls `run`
with `-o json`, and compares `scrubJSON(stdout)` and `scrubText(stderr)`
with two golden files. `scrubJSON` decodes the document, zeroes the two timing fields and encodes
it again. Regular expressions over JSON break on escaped quotes and
reordered keys; decoding into `map[string]any` and re-encoding also sorts the
keys, so the result is canonical. Scrubbing the _table_ by regular
expression would be a trap: `tabwriter` sizes each column to its widest
cell, so replacing `1ms` with a placeholder changes the padding on every
row. If an output format aligns columns, scrub the data before it is
formatted, or test a structured format instead. The scrubbed stderr is a
single line:

#src("cmd/sweep/testdata/golden/run-stderr.golden")

#warning(title: [Golden files rot when `-update` becomes a reflex])[
  The failure mode is social. A test goes red, someone runs `-update`
  without reading the diff, and the golden file now enshrines the bug. Keep
  golden files small enough to review (five results, not five hundred),
  give each one a single purpose, and treat a golden diff in a pull request
  like an API change, because for anything machine-read that is what it is.
]

== The binary, end to end, with testscript <sec-test-script>

The `run` function is a seam, and Chapter 4 tests through it. But `run` is
not what CI executes. CI executes a binary, which reads `os.Args`, inherits
an environment, gets signals from the kernel, and reports through an exit
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
doesn't (the tip at the end of this section lists why). `testscript`, from
`github.com/rogpeppe/go-internal`, is the harness the Go team built for
testing the `go` command itself, extracted into a library. A
test is a _txtar_ file: a short script followed by the files it needs. This
one checks the exit-status contract:

#src("examples/ch06/sweepscript/testdata/script/exit_status.txtar")

Each line is a command run by a small interpreter, not a shell. `exec` runs a
program, and `stdout`, `stderr` assert regular expressions against what the
previous command printed (`-count=N` asserts how many times). A leading `!`
negates. The `--` lines start files that are written into a fresh
temporary directory, `$WORK`, before the script runs. `envsubst` and
`exits` are custom commands, shown below. When a script fails, the log
shows every command, its stdout and stderr, and the line that failed.

=== Building the harness

There are two ways to give a script a `sweep` command. `testscript.Main`
re-executes the test binary itself as the command, so `main` runs inside
the test binary:

#code(file: "cmd/sweep/script_test.go", caption: "the in-package variant")[```go
func TestMain(m *testing.M) {
	testscript.Main(m, map[string]func(){"sweep": main})
}
```]

That is the right default, but it needs the test to live in package
`main`, so `go-internal` and its dependency on `golang.org/x/tools` become
dependencies of the root module. This repository keeps its root module's
dependencies few, so the `sweep` scripts live in a small module of their
own, `examples/ch06/sweepscript`, and test the binary the way CI would
build it:

#src("examples/ch06/sweepscript/script_test.go", region: "main")

Building with `go build` has a second advantage: when `GOCOVERDIR` is set,
the binary is built with `-cover`, and @sec-test-coverage uses that to
measure what the scripts exercise. `TestScripts` turns each txtar file into
a subtest:

#src("examples/ch06/sweepscript/script_test.go", region: "run")

`Setup` runs after the archive is unpacked and before the script starts. It
puts the binary first on `PATH` and starts a fake fleet for this script
alone, so scripts can run in parallel without sharing state. The fleet's
address goes into the environment, because the scripts can't know the port
in advance. The `fleetKey` value hands the fleet itself to custom commands.

Three custom commands cover what the built-ins can't express. `exits`
asserts an exact exit status:

#src("examples/ch06/sweepscript/script_test.go", region: "exits")

`waitreq path n` removes the need to sleep: it blocks on the fake fleet
until `path` has served `n` requests. `envsubst` expands `$FLEET` inside
inventory files, since testscript expands variables in command arguments
but not in the files of the archive.

=== A real Ctrl-C

The test that justifies the whole harness sends a real `SIGINT` to a real
process and checks what the user would see. With `-v`, testscript prints
each script's transcript: comments, every command (prefixed `>`), and what
it printed. Here is the `interrupt` script running:

#output("ch06/script-interrupt.txt", cmd: "go -C examples/ch06/sweepscript test -count=1 -v -run 'TestScripts/^interrupt$' ./...", size: 6.6pt)

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

Two more scripts complete the contract. `inventory` checks that every
inventory mistake is reported at once, with line numbers and status 2,
before any target is contacted, and that stdin and multiple files work.
`help` pins the usage text with `cmp stderr usage.txt`, where `usage.txt` is
a file inside the same txtar archive. Running the suite with `-update` sets
`UpdateScripts`, which rewrites that file in place when a flag changes: a
golden file that lives next to its test. The four scripts run in parallel,
each with its own fleet and directory:

#output("ch06/script-run.txt", cmd: "go -C examples/ch06/sweepscript test -count=1 -v ./...")

#tip(title: [Why this beats a shell script in CI])[
  Each script runs in a fresh directory with a controlled environment
  (`HOME` points nowhere, `TMPDIR` is private), so scripts can't leak into
  each other or depend on the developer's machine. They run in parallel
  under `go test`, so `-run`, `-count`, `-shuffle` and `-timeout` all work.
  The harness runs the same way on Linux, macOS and Windows runners, with
  no `bash` or GNU `grep` required (only the signal test is Unix-specific).
  A failure prints the full transcript up to the failing line. And the binary under test can be built with `-cover`, so
  the end-to-end suite counts towards coverage instead of being a black box.
]

== Fakes over mocks <sec-test-fakes>

A _fake_ is a working implementation of an interface with shortcuts: an
in-memory store instead of a database, an HTTP handler instead of a remote
service. A _mock_ is an object programmed with expectations about how it
will be called ("`Probe` will be called three times with these arguments")
that fails the test if the calls differ. Both replace a dependency. They
fail in different situations, and that difference decides which one to
use.

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

=== A hand-written fake

This fake prober follows a script of outcomes per target and records when
each attempt started:

#src("internal/sweep/fake_test.go", region: "fake")

A `Starts(target)` accessor returns the recorded times. The fake is about
forty lines and has no knowledge of how the runner calls it.
The tests say what should _happen_, not what calls should be made. Here is
the runner honouring a server's `Retry-After`:

#src("internal/sweep/fake_test.go", region: "retryafter")

A second test, `TestRunnerRateLimitSpacesAttempts`, gives ten targets on ten
hosts to a runner limited to five attempts per second. Both run in a
`synctest` bubble, so the fake's simulated latency and the
runner's sleeps happen in virtual time and the assertions can be exact: the
retry starts _exactly_ three seconds after the first attempt, and ten
attempts at five per second finish at _exactly_ 1.8 seconds. Neither test
mentions how many times `Probe` was called, in what order, or with which
context. If the runner is refactored to share the rate limiter differently
or to probe hosts in a different order, these tests keep passing as long as
the behaviour holds.

=== Fakes at the protocol level

The `HTTPProber` itself needs a real HTTP server to talk to. `sweeptest` is
a small package in the spirit of `httptest`: a handler with one path per
behaviour a health checker must classify, plus request counting so tests
can wait for traffic instead of sleeping.

#src("internal/sweep/sweeptest/fleet.go", region: "fleet")

It is used by the end-to-end golden test, by every testscript script, by
`examples/ch06/fleetd` (a ten-line server for demos and coverage runs), and
by the container image in @sec-test-containers. Chapter 20's `ddfake`, an
in-memory fake of the Datadog monitors API, is the same idea for a vendor
API: a fake owned next to the code that depends on it, exercised through
the real HTTP client.

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
the CI runner has no internet access.

=== When a mock earns its keep

For contrast, here is how the Retry-After test starts with a generated mock
from `go.uber.org/mock`. It is a sketch; the repository doesn't use it.

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

== Real dependencies with testcontainers <sec-test-containers>

Fakes encode what you believe about a dependency. When the belief is wrong,
the fake is wrong in the same way, and the tests pass. The way out is to
test some paths against the real thing: the real database's wire protocol,
the real readiness sequence, the real error when it goes away. For a tool
like `sweep`, that means pointing the real probers at real servers.

`testcontainers-go` starts Docker containers from Go tests and cleans them
up afterwards. It lives in a nested module, `examples/ch06/containers`,
pinned at v0.44.0, so the Docker client and its dependencies stay out of
the root module. @fig-test-containers shows the moving parts.

#fig(placement: auto, caption: [A container test. The fleet image is built from a binary cross-compiled on the host, so no base image is pulled. Ryuk, started once per test session, removes the session's containers even if the test process is killed.])[
  #diagram(
    spacing: (30pt, 20pt),
    dnode((0, 0), [`go build`\ `GOOS=linux`], kind: "default"),
    dnode((1, 0), [build context\ `fleetd` + `FROM scratch`], kind: "muted"),
    dnode((0, 1), [`go test`\ test process], kind: "dark"),
    dnode((1, 1), [Docker daemon], kind: "accent"),
    dnode((2, 1), [Ryuk reaper\ watches the session], kind: "warn"),
    dnode((1, 2), [fleetd container\ `:8080`], kind: "good"),
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

=== Skip, don't fail

Container tests need a Docker daemon, which a laptop on a plane, a macOS CI
runner, or a locked-down build agent may not have. The suite must degrade
to "skipped", never to "failed":

#src("examples/ch06/containers/containers_test.go", region: "skip")

`SkipIfProviderIsNotHealthy` asks the Docker provider for a health check and
calls `t.Skip` if it can't get one (it also recovers from a panic in the
provider). `-short` skips everything without contacting Docker at all,
which keeps the fast loop fast:

#output("ch06/containers-short.txt", cmd: "go -C examples/ch06/containers test -count=1 -short -v ./...")

=== Images without a registry

Pulling images from Docker Hub through Docker Desktop's proxy has timed out
repeatedly on the machine this book is written on. A test that depends on a
pull inherits that flakiness, plus rate limits and registry outages. The
fleet image avoids the registry entirely: the test cross-compiles `fleetd`
for Linux and wraps it in a `FROM scratch` image, the same trick the kind
end-to-end test in Chapter 20 uses.

#src("examples/ch06/containers/containers_test.go", region: "image")

`GOARCH` follows the host, because Docker Desktop on Apple silicon runs
arm64 Linux and GitHub's standard Linux runners are amd64. The image has no shell
and no libc, so it builds in a second and its only content is the program
under test.

`TestSweepAgainstFleetContainer` runs the image with
`testcontainers.WithDockerfile`, waits until `/ok` answers on port 8080, and
points the real HTTP prober at the mapped port. The PostgreSQL test below
has the same structure, and two habits in both are worth copying. `CleanupContainer` is
registered _before_ the error check, because `Run` can return a container
that started and then failed its wait strategy, and that container still
needs removing. And the test never uses a fixed host port: `PortEndpoint`
returns whatever port Docker mapped, so parallel test runs on one machine
don't collide.

=== A real database going away

The second test uses `postgres:17-alpine`, which was already in the local
image cache (when an image is present, testcontainers doesn't pull it). It
checks the database, stops it, and checks again:

#src("examples/ch06/containers/containers_test.go", region: "postgres")

The wait strategy encodes a piece of PostgreSQL folklore that a fake would
never teach you. On first start, the official image's entrypoint runs
`initdb`, starts a temporary server (on a Unix socket only) to apply init
scripts, stops it, and then starts the real server, so "database system is
ready to accept connections" appears twice. Waiting for
the first occurrence produces a test that passes on a fast laptop and fails
on a loaded CI runner when the probe lands in the gap. Here is the run:

#output("ch06/containers.txt", cmd: "go -C examples/ch06/containers test -count=1 -v ./...", size: 6.8pt)

Two containers, an image build and a database restart cycle took a few
seconds. The log line from the PostgreSQL test shows the real error after
the stop: Docker's port forwarder refuses the connection, `sweep` classifies
"connection refused" as retryable, and gives up after three attempts.
testcontainers' own log, filtered from the same run, shows the other moving
parts:

#output("ch06/containers-log.txt", title: "testcontainers log, excerpt")

The image built from the scratch context in about a second. Before the
first container, testcontainers started Ryuk, a reaper container that
removes everything labelled with the test session's ID if the test process
dies without cleaning up. The `testcontainers/ryuk` image did come
from Docker Hub; that pull took six seconds while this chapter was being
written. Where pulls are unreliable, mirror the Ryuk image into your own
registry, or disable it with `TESTCONTAINERS_RYUK_DISABLED=true` and rely on
`CleanupContainer`, accepting that a killed test run can leave containers
behind.

#warning(title: [Container tests are integration tests])[
  They are slower (seconds, not milliseconds), they need a daemon, and they
  can fail for reasons that have nothing to do with your code: disk full,
  a stale image, a port forwarder that is slow to release. Keep them few
  and focused on what fakes can't show, put them behind `-short` or a
  separate module, and run them in their own CI job so a Docker problem
  doesn't block a one-line fix to a parser.
]

== Fuzzing the parsers <sec-test-fuzz>

Every test so far checks inputs someone thought of. The inputs that break
tools are the ones nobody thought of: an inventory line pasted from a wiki
with a non-breaking space, a header from a misconfigured proxy, a port
number with one digit too many. Go's native fuzzing (Go 1.18) generates
those inputs for you. A fuzz target is a test that takes generated
arguments; `go test -fuzz` runs it millions of times, mutating inputs
and keeping the ones that reach new code, until it finds an input that
fails or the time runs out.

The hard part is not the mechanics. It is deciding what must be true for
_every_ input, because the fuzzer can only find violations of properties
you write down. "Doesn't panic" is the weakest property and still worth
having. Stronger ones come from the function's contract. `ParseTargets`
promises to report every syntax error up front, with a line number, so
anything it accepts must be something the runner can actually probe, and
the lines it accepted must parse to the same targets again:

#src("internal/sweep/target_fuzz_test.go", region: "fuzz")

The seeds added with `f.Add` are the starting corpus and also run as
ordinary subtests on every `go test`. Here is the first fuzzing run, against
the parser as Chapter 4 left it:

#output("ch06/fuzz-targets.txt", cmd: "go test -run '^$' -fuzz '^FuzzParseTargets$' -fuzztime 60s ./internal/sweep", title: "before the fix")

It took well under a second. `url.Parse` accepts any run of digits as a
port, so `ParseTargets` accepted port 100000 (the input also shows that
schemes are case-insensitive). Nothing failed at parse time. At run time the dialer rejects the address with
"invalid port", which `sweep` treats as a transient network error: it
retries three times, reports the target as down, and fails the pipeline
over a typo in an inventory file, with no line number. The fix belongs in
the parser:

#src("internal/sweep/target.go", region: "port")

The fuzzer saved the failing input under `testdata/fuzz/FuzzParseTargets/`,
and that file is committed. It is a plain-text corpus entry:

#src("internal/sweep/testdata/fuzz/FuzzParseTargets/1c0eab32cf38a6eb")

From then on, every `go test` replays it alongside the seeds, as a subtest
named `FuzzParseTargets/1c0eab32cf38a6eb`, so the bug can't return
unnoticed.

=== A second target, a second bug

`parseRetryAfter` reads the `Retry-After` header, which a server sends with a
429 or 503 to say how long to back off. Its contract is simple: an accepted
value is a delay, and a delay is never negative.

#src("internal/sweep/probe_fuzz_test.go", region: "fuzz")

#output("ch06/fuzz-retryafter.txt", cmd: "go test -run '^$' -fuzz '^FuzzParseRetryAfter$' -fuzztime 60s ./internal/sweep", title: "before the fix")

Any number of seconds above about 9.2 billion, multiplied by `time.Second`,
overflows `int64`, and this one came out negative. The retry policy caps a server-requested
delay with `min(delay, MaxDelay)`, which keeps the negative value, and a
timer with a negative duration fires immediately. The result is the exact
opposite of what the server asked for: "back off for a very long time"
became "retry right now". No server sends that header on purpose, but a
buggy proxy or a deliberately hostile endpoint can, and a fleet tool should
not amplify either. The fix clamps before multiplying:

#src("internal/sweep/probe.go", region: "retryafter")

With both fixes in place, a minute of fuzzing finds nothing more:

#output("ch06/fuzz-after.txt", cmd: "go test -run '^$' -fuzz '^FuzzParseTargets$' -fuzztime 60s ./internal/sweep 2>&1 | tail -3")

More than a million executions without a failure is evidence, not proof. The
round-trip and port properties hold for everything the mutator reached, and
the "new interesting" count was still rising at the end, which means it was
still finding new paths through `url.Parse`. A longer run could still find
something.

#internals(title: [How `go test -fuzz` works])[
  The fuzzing engine is coverage-guided. The fuzz target is built with
  extra instrumentation that records which edges of the control-flow graph
  each input exercises. A coordinator process hands inputs to worker
  processes (`GOMAXPROCS` of them unless `-parallel` says otherwise, hence
  "10 workers" on this machine),
  mutates the inputs that reached new edges, and keeps them in a cache
  corpus under `$(go env GOCACHE)/fuzz`. When an input fails, the engine
  minimises it (shorter inputs that still fail), writes it to
  `testdata/fuzz/<Target>/`, and stops. `-fuzz` must match exactly one
  target. Arguments can be strings, byte slices, integers, floats, booleans
  and runes. Without `-fuzz`, a fuzz target is an ordinary test over its
  seeds and the committed corpus, which is why it costs nothing in CI.
]

Good fuzz targets in platform code are anything that parses text written by
a person or another system: inventory and config files, label selectors,
duration and size strings, headers, log lines, and webhook payloads. Encoders
are good targets too, with a round-trip property (`Decode(Encode(x)) == x`),
and so is any rewrite of a working function: fuzz the new implementation
against the old one and fail on any difference.

#tip(title: [Fuzzing in CI])[
  Run the seed corpus on every push; it is part of `go test` already. Run
  real fuzzing in a scheduled job, a few minutes per target, and have it
  open a pull request with any new file under `testdata/fuzz`. Fuzzing on
  every push makes CI slower without making it more thorough, because the
  value comes from total fuzzing time, not from fuzzing often.
]

== Benchmarks that mean something <sec-test-bench>

`sweep` spends nearly all of its time waiting on the network, so its CPU
cost rarely matters. Benchmarks become worth writing when an input grows
(a 20,000-line inventory parsed on every pipeline run), when code moves onto
a hot path (a deploy gate decoding `sweep -o jsonl` for every service in a
release), or when something underneath you changes. Go 1.27 changed
something underneath every program that uses `encoding/json`, and that makes
a good worked example.

#src("internal/sweep/bench_test.go", region: "parse")

#newingo("1.24", title: [`b.Loop`])[
  `for b.Loop() { ... }` replaces `for range b.N`. The benchmark function
  now runs exactly once per `-count`, so setup before the loop (here, building
  a 1,000-line inventory) runs once and isn't timed: `Loop` resets the
  timer on its first call and stops it when it returns `false`. The compiler
  also keeps the arguments and results of calls inside the loop alive, so it
  can't optimise away the work being measured, which used to need a
  package-level sink variable. Go 1.26 removed a side effect of that
  mechanism: the loop body is now inlined normally, so `b.Loop` benchmarks
  no longer show allocations that the `b.N` version didn't have.
]

`b.Elapsed()` and `b.ReportMetric` turn the result into the unit that
matters for an inventory, nanoseconds per line. The reporter benchmarks
render 1,000 results in each format, and a decode benchmark measures the
consumer's side:

#src("internal/sweep/bench_test.go", region: "report")

#output("ch06/bench.txt", cmd: "go test -run '^$' -bench . -benchmem ./internal/sweep")

(The capture script re-spaces the tab-aligned columns to fit the page.)
The `-10` suffix is `GOMAXPROCS`. Each line gives the iteration count, time
per operation, the custom metric, bytes allocated per operation and the
number of allocations (the last two come from `-benchmem`). Parsing costs a
few hundred nanoseconds per inventory line, so a 20,000-line inventory
parses in a few milliseconds: not worth another thought. The table reporter
makes about six allocations per row, which is worth a look, if only to learn
how to look.

=== Where the allocations come from

A memory profile from the benchmark says which functions allocate:

#session(
  ("go test -run '^$' -bench 'Report/table' -benchmem -memprofile mem.out ./internal/sweep \\
  > /dev/null", none),
  ("go tool pprof -sample_index=alloc_objects -top -nodecount=8 mem.out", "ch06/pprof.txt"),
)

`alloc_objects` counts allocations rather than bytes, which is what matters
for garbage-collector pressure. Two thirds of them are attributed to
`tableReporter.Close` itself, and the compiler's escape analysis says why:

#output("ch06/escape.txt", cmd: "go build -gcflags=-m ./internal/sweep 2>&1 | grep 'report.go:9[78]'", size: 6.4pt)

Every argument to `fmt.Fprintf` is converted to an `interface{}`, and a
string or a `Duration` stored in an interface escapes to the heap. (So does
`r.Attempts`, but the runtime keeps preallocated values for integers below
256, so small counts don't actually allocate.) The rest are `tabwriter`
buffering each line and `Duration.String` formatting the latency.

Is it worth fixing? A version built on `strconv.AppendInt` and a reused byte
buffer would cut most of those allocations, and the benchmark would look
better. But the table is printed once per sweep, after seconds of network
I/O, and 1,000 rows cost around half a millisecond. The profile is the
evidence that settles the argument: leave `fmt.Fprintf`, which is easy to
read, where it is.

=== Comparing two implementations with `benchstat`

Go 1.27 made `encoding/json` a thin layer over the new `encoding/json/v2`
engine. The release notes say marshalling performance is "broadly at
parity" and unmarshalling "significantly faster", and they keep the old
implementation available, for now, behind `GOEXPERIMENT=nojsonv2`. That makes an honest A/B test possible: the same
benchmark code, compiled twice.

#session(
  ("go test -c -o v2.test ./internal/sweep", none),
  ("GOEXPERIMENT=nojsonv2 go test -c -o v1.test ./internal/sweep", none),
  ("for i in $(seq 10); do \\
  ./v1.test -test.run '^$' -test.bench 'Report|Decode' -test.benchmem >> v1.txt; \\
  ./v2.test -test.run '^$' -test.bench 'Report|Decode' -test.benchmem >> v2.txt; \\
done", none),
  ("go run golang.org/x/perf/cmd/benchstat@latest v1.txt v2.txt", "ch06/benchstat.txt"),
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

The table reporter is the control. It doesn't touch JSON, and `benchstat`
correctly reports no difference. For this workload, on this machine, the new
engine writes the indented JSON document in about half the time with 63%
fewer allocations, and decodes JSON lines over 40% faster with 78% fewer
allocations. But it _encodes_ JSON lines through `json.Encoder` more than
40% more slowly, with two allocations per result where the old engine made
one. That last row is
not what "broadly at parity" suggests, and it is precisely the kind of
result you only get by measuring your own workload. It changes nothing for
`sweep`: the difference is a fraction of a millisecond per thousand
results. A service that streams JSON lines at volume should measure the v2
API directly (`json.MarshalWrite` and `jsontext.Encoder`) before deciding;
this chapter didn't.

#warning(title: [One run is an anecdote])[
  While drafting this section, a single run of each binary suggested that
  the v2 engine was twice as _slow_ for the indented JSON document, the
  opposite of the result above. The `±` column explains why: on this laptop
  the spread between runs was up to about 30%. Never compare two single
  runs, and never compare numbers taken on different machines or on
  different days.
]

=== Why laptop and CI numbers differ

The wide intervals in that table come from the laptop, not from JSON: the
same two binaries, run alternately within a few minutes, varied by up to
about 30% from one run to the next. That is the everyday reality of developer
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

== Coverage across unit and end-to-end tests <sec-test-coverage>

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
    dnode((1, 1), [`cov/e2e/<script>`], kind: "accent"),
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

Start with a single binary run against `fleetd`, the fake fleet as a
stand-alone server:

#session(
  ("mkdir -p cov/run && go build -cover -o sweep-cover ./cmd/sweep", none),
  ("GOCOVERDIR=cov/run ./sweep-cover cov/inventory.txt", "ch06/cover-run.txt"),
  ("go tool covdata percent -i=cov/run", "ch06/cover-run-percent.txt"),
)

`go build -cover` instruments every package of the main module that the
binary links (`-coverpkg` narrows or widens that). Each process writes one
_counters_ file named after the binary's hash, its process ID and a
timestamp, and the first process writes one _meta-data_ file per binary
that describes the code. If `GOCOVERDIR` is unset, the binary runs normally
and prints a warning that no coverage data was emitted. (In this listing
and the next ones, the capture script shortens the module path
`github.com/rahulbalajee/platform-go/` so the lines fit the page.)

Now the full picture. The unit tests write raw coverage data with the test
binary's `-test.gocoverdir` flag, which the `testing` package defines but
`go help testflag` doesn't list. The testscript suite needs only
`GOCOVERDIR`: its `TestMain` then builds `sweep` with `-cover`, and
testscript passes `GOCOVERDIR` on to every process a script starts.

#session(
  ("go test -cover ./cmd/sweep ./internal/sweep ./pkg/conc ./pkg/retry ./pkg/lifecycle \\
  -args -test.gocoverdir=\"$PWD/cov/unit\"", "ch06/cover-unit.txt"),
  ("GOCOVERDIR=$PWD/cov/e2e go -C examples/ch06/sweepscript test -count=1 ./...", "ch06/cover-e2e.txt"),
)

The end-to-end data is in one directory per script, for a reason
@sec-test-flaky explains. Merging takes a comma-separated list of
directories:

#session(
  ("mkdir -p cov/all && go tool covdata merge -o cov/all -i=\"cov/unit,$(echo cov/e2e/* | tr ' ' ,)\"", none),
  ("go tool covdata percent -i=cov/all", "ch06/cover-all-percent.txt"),
  ("go tool covdata textfmt -i=cov/all -o cov/all.out", none),
  ("go tool cover -func=cov/all.out | sort -k3 -n | head -12", "ch06/cover-func.txt"),
)

The merged numbers say more than either input. `cmd/sweep` rises from 72% to
about 90%, because the scripts drive the real `main`, flag parsing and exit
paths. `pkg/lifecycle` reaches 100%: the lines its own tests can't reach run
when the interrupt script sends a real signal to a real process. And the
list of uncovered functions is a precise to-do list. The TLS and DNS probers have no
test that runs them at all. More surprising, `CachingResolver.LookupHost`,
the singleflight cache from Chapter 4, is at zero: every test target is an
IP literal (`127.0.0.1`), so `DialContext` takes its shortcut for literal
addresses and never resolves a name. No other tool would have shown that.
The gap is the cue for a test that uses a hostname, such as a fake
`*net.Resolver` with a custom `Dial`, or a container on a Docker network
reached by name.

#production(title: [Use coverage as a map, not a target])[
  A coverage percentage as a merge gate invites tests that execute code
  without checking anything. Use merged coverage to answer specific
  questions instead. Which error paths have never run? Does the end-to-end
  suite reach the code a change touched? Did a refactor orphan a branch?
  `go tool cover -html` on the merged profile shows the answers line by
  line. If you do want a gate, gate on coverage of the _changed_ lines in a
  pull request, which can't be satisfied by testing something else.
]

== Flaky tests <sec-test-flaky>

A flaky test passes and fails on the same code. One flaky test in a suite of
a thousand, failing 1% of the time, is enough to teach a team that red
builds don't mean anything, and from then on real failures get retried
instead of read. Flakiness has a small number of causes. Most of the
failures below are reproduced on purpose in `examples/ch06/flaky`, behind a
`flakydemo` build tag; the last one was found by accident.

*Time.* Sleeps instead of synchronisation, and timeouts tuned on a fast
laptop that fire on a loaded CI runner or under `-race`. The fixes are the
ones used throughout this chapter: `synctest` for timers, and waiting for
an observable event (`waitreq`, `Fleet.WaitFor`) instead of sleeping.

*Order and shared state.* Package-level variables, caches, environment
variables and the working directory survive from one test to the next. A
test that passes alone and fails after another test has run is not
independent, and two flags find it. `examples/ch06/flaky` has a check
registry kept in a package-level map, like the ones many tools keep, and two
tests that pass in source order:

#src("examples/ch06/flaky/flaky_test.go", region: "order")

`-count=2` runs each test twice in the same process, so state left by the
first run meets the second, and both tests fail:

#output("ch06/flaky-count.txt", cmd: "go test -tags flakydemo -count=2 -run 'TestRegistry|TestRegister' ./examples/ch06/flaky")

`-shuffle=on` randomises the order and prints the seed, and passing the seed
back replays the failing order exactly:

#session(
  ("go test -tags flakydemo -count=1 -shuffle=on -run 'TestRegistry|TestRegister' ./examples/ch06/flaky", "ch06/flaky-shuffle.txt"),
  ("go test -tags flakydemo -count=1 -shuffle=" + read("/book/output/ch06/flaky-seed.txt").trim() + " -run 'TestRegistry|TestRegister' \\
  ./examples/ch06/flaky", "ch06/flaky-reproduce.txt"),
)

The fix is to stop sharing: make the registry a value that `main` creates
and passes down, so each test makes its own.

*Lifetimes in parallel tests.* The `defer` trap from @sec-test-tables
fails every time, which makes it easy to fix, but the same mistake with a
fixture that closes slowly fails only sometimes:

#src("examples/ch06/flaky/flaky_test.go", region: "defer")
#output("ch06/flaky-defer.txt", cmd: "go test -tags flakydemo -count=1 -run 'TestEndpoints' ./examples/ch06/flaky")

And process-wide settings in a parallel test are refused outright:

#src("examples/ch06/flaky/flaky_test.go", region: "setenv")
#output("ch06/flaky-setenv.txt", cmd: "go test -tags flakydemo -count=1 -run 'TestProxyFromEnvironment' ./examples/ch06/flaky 2>&1 | head -2 | fold -s -w 88")

*Ports.* A test that listens on a fixed port fails when anything else on
the runner holds it, including another package's tests running in
parallel. Listen on port 0 and read the address back, as `httptest` does.
The `closedPort` helper in Chapter 4's tests, which listens on port 0,
closes the listener and hands the address out as "refused", has a small
window in which another process could take the port. It is a reasonable
trade for a test helper; it is not a pattern for anything that must be
reliable.

*The toolchain.* The strangest flake in this chapter came from the coverage
runtime. With `GOCOVERDIR` set, the testscript suite failed twice in its
first fifteen runs on this machine, in the `help` script, whose `cmp stderr`
found an unexpected first line: "error: coverage meta-data emit failed".
Reading `internal/coverage/cfile/emit.go` explains it. The first process to
exit writes the meta-data file through a temporary file named after the
meta-data hash and `time.Now().UnixNano()`, then renames it into place. On
macOS that clock reading has microsecond granularity (every timestamp in the
file names below ends in `000`), so two processes that exit in the same
microsecond pick the _same_ temporary name, one rename wins, and the other
fails. The data survives, because both processes write identical meta-data,
but the error lands on stderr. A short script in the repository reproduces
it in seconds instead of a dozen suite runs: it builds `sweep` with
`-cover`, starts eight copies at once into a fresh `GOCOVERDIR`, and repeats
until one of them complains, then prints the message (with the hash and
paths shortened) and the files that were written:

#output("ch06/covrace.txt", cmd: "examples/ch06/flaky/covrace.sh")

The fix in the harness is to give each script its own coverage directory, so
processes from different scripts never share a temporary name:

#src("examples/ch06/sweepscript/script_test.go", region: "coverdir")

With that change, thirty consecutive runs of the suite with `GOCOVERDIR` set
passed. The general lesson is about method rather than coverage: shrink a
flake to the smallest program that still reproduces it, then read the code
that fails, even when that code is the toolchain's.

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
  [Every push], [`go vet`, `golangci-lint`, `go test -race -shuffle=on ./...` in the root module: units, components, goldens, fuzz seed corpora, the `run`-level CLI tests], [2 minutes],
  [Every pull request], [The testscript suite with `GOCOVERDIR` and a merged coverage report; container tests in a separate job on a Linux runner with Docker], [10 minutes],
  [Nightly], [Fuzzing, several minutes per target; benchmarks on a dedicated runner compared with `benchstat`; long soak runs with `-count=50`], [an hour],
)

Three mechanisms keep slow tests out of the fast loop, and this chapter
uses all of them. `testing.Short()` lets a test skip itself under `-short`;
it is simple, but every developer has to remember the flag. A build tag
(`//go:build flakydemo`, or `integration`) removes files from the build
unless the tag is given; it is impossible to run by accident, and equally
easy to forget to run at all, so a CI job must own each tag. A separate
module, like `examples/ch06/containers`, keeps heavy dependencies out of
the main module and gives the slow tests their own `go.mod`, their own
`go test ./...` and their own CI job. Whichever you pick, quarantine a flaky
test the day it is found (skip it with a link to an issue that has an
owner), and never let a CI system retry failures silently.

== A test strategy for a platform team <sec-test-strategy>

Platform tools have an unusual property: their users are other engineers'
pipelines. A regression in a service shows up as an error rate; a
regression in a deploy gate shows up as a release that shipped when it
shouldn't have, weeks before anyone connects the two. The test strategy
should follow the contracts, layer by layer:

+ *Exit status and streams.* Pin them end to end, against the real binary,
  for every documented status. This is the contract every caller depends on.
+ *Machine-read output.* Golden files for every format another program
  parses, reviewed like API changes.
+ *Behaviour against dependencies.* Fakes at the consumer's interface for
  logic (retries, limits, classification); protocol-level fakes such as
  `sweeptest` and `ddfake` for clients; a few container tests for what fakes
  can't know.
+ *Input from humans.* Table tests for the documented syntax and fuzz
  targets for everything else.
+ *Visibility.* Merged unit and end-to-end coverage, read as a map of what
  has never run.

#production(title: [At 200 engineers and 1,000 services])[
  The test code that pays off most is shared fakes. When every team writes
  its own fake of the internal deployment API, the fakes drift from the real
  API and from each other, and each one encodes a slightly different
  misunderstanding. Make the team that owns an API also own its fake (a
  `xxxtest` package next to the client, like `httptest` next to `http`),
  and run the fake and the real service through the same contract tests,
  so they can't drift apart without a test failing. Keep test-time budgets
  too. A root-module suite that creeps from two minutes to twenty gets run
  less, then skipped, and the end result is worse than having fewer tests.
]

#interview(title: [“How would you test a CLI tool?”])[
  Start from the contract: arguments, stdin, stdout, stderr, exit status,
  signals. Structure `main` as a thin wrapper around
  `run(ctx, args, stdin, stdout, stderr) int`, so most behaviour is
  unit-testable without a process. Test parsers with tables and fuzzing,
  output formats with golden files, and dependencies through small interfaces
  with fakes. Then test the real binary end to end with `testscript`: exact
  exit codes, nothing on stdout for usage errors, a real `SIGINT` producing
  a partial report. Build that binary with `-cover` and merge the coverage,
  so you know what the end-to-end layer reaches.
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
  [Golden files pin machine-read output. Make inputs deterministic first; scrub structurally when you can't; review `-update` diffs like API changes.],
  [Test the real binary with `testscript`: exact exit codes, separated streams, stdin, and real signals, in parallel and with no shell.],
  [Prefer fakes at the consumer's interface; mocks couple tests to call sequences. Reach for a mocking library only when the interaction is the behaviour.],
  [`testcontainers-go` tests what fakes can't know. Build images from host-compiled binaries to avoid registries, and skip cleanly without Docker.],
  [Fuzz every parser of human or foreign input, with properties taken from its contract. Here it found two real bugs in under a second each.],
  [Benchmarks need `b.Loop`, `-benchmem`, interleaved runs and `benchstat` on one machine; profiles decide whether an allocation matters. Merge `GOCOVERDIR` data from unit and end-to-end runs and read it as a map of code that has never run.],
)

#exercises(
  [*Cover the resolver.* Merged coverage shows `CachingResolver.LookupHost` never runs. Write a test that makes it run with a hostname, either through a `*net.Resolver` whose `Dial` points at a tiny fake DNS server, or by refactoring `CachingResolver` to depend on a one-method interface declared at the consumer. Assert that 50 concurrent dials of one hostname cause exactly one lookup. Which design made the test easier, and what did it cost the production code?],
  [*TLS in a container.* Extend `examples/ch06/containers` with a test that starts a server presenting a certificate expiring in three days (generate it in the test with `crypto/x509`) and checks that `sweep`'s `TLSProber` reports it down with `--min-cert-validity 14d`, permanently and after exactly one attempt. Then make it pass without Docker, using `httptest.NewUnstartedServer` with a custom `TLS` config. What did the container version test that the in-process one doesn't?],
  [*A fuzz target with an oracle.* Write `FuzzReporterJSONL`: generate `Result` values from fuzzed fields, render them with the `jsonl` reporter, decode every line, and require the decoded values to equal the originals. Run it with the v1 and v2 JSON engines (`GOEXPERIMENT=nojsonv2`). Do they disagree on any input, for example invalid UTF-8 in `Target`? Which behaviour do you want, and how would you pin it?],
  [*Benchmark the alternative.* Implement the table reporter with `strconv.AppendInt` and a reused buffer, keep `TestReportersGolden` green, and compare the two with interleaved runs and `benchstat`. Then time a real sweep of 300 targets with each. Write down the threshold at which you would accept the faster but harder-to-read version.],
  [*A flake budget.* Add a CI job (any CI system) that runs the root module's tests with `-shuffle=on -count=5` nightly, records the seed of every failure, and opens an issue with the replay command. Then introduce a deliberate order dependency and check that the job catches it within a week of nightly runs. How would you stop the job itself from becoming the thing everyone ignores?],
)
