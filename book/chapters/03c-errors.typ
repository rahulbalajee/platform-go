#import "../template/book.typ": *
#import "03-lib.typ": ts

#step(7, 8, "Panics and crash reports", label: <sec-err-step-panics>)

Everything so far handles failures the program expected. This step is about
the ones it didn't: bugs. Go reports a bug at run time with a panic, and an
unhandled panic prints a goroutine dump and exits 2, which the contract
already uses for "you typed a bad flag". This step gives bugs their own
exit code, 70, and replaces the dump with four lines for the user and a
crash file for the maintainer.

=== When to panic <sec-err-panics>

A panic is for a state the program should never be in: a nil map the code
assumed was initialised, an index past the end of a slice, an enum value
nobody wrote a case for. Those are bugs, and continuing means running on
assumptions that just proved false. `regexp.MustCompile` and `template.Must`
follow the same rule: they panic only on inputs that are constants in the
program. Anything a user or the environment can cause (a missing file, bad
input, a network failure, a permission error) is an error and goes up the
stack as a value.

#goconcept(title: [`defer`, `panic` and `recover`])[
  `panic(v)` stops the normal flow of the current goroutine. The runtime
  calls `panic` for you on a nil pointer dereference, an out-of-range index,
  a write to a nil map and similar bugs, with a `runtime.Error` as `v`. The
  goroutine then _unwinds_: it returns from each function on its stack in
  turn, running each one's deferred calls on the way, as it would on a
  normal return. If the unwinding reaches the top of the goroutine, the
  program prints the panic value and the stack and exits with status 2. All
  of it, not just that goroutine.

  `recover()` stops the unwinding, but only when it is called _directly_ by
  a deferred function during a panic; anywhere else it returns `nil` and
  does nothing. It returns the panic value, and the function whose deferred
  call recovered returns normally to its caller, with whatever its named
  results hold:

  #code(file: "sketch")[```go
  func safely(f func()) (err error) {
  	defer func() {
  		if v := recover(); v != nil {
  			err = fmt.Errorf("recovered: %v", v) // sets the named result
  		}
  	}()
  	f()
  	return nil
  }
  ```]

  Three rules follow. `recover` only sees panics on its own goroutine. It
  must be in the deferred function itself, not in a helper that function
  calls. And the stack trace is only available while unwinding, so capture
  it inside the deferred function. _Coming from Java or Python:_ this is not
  `try`/`catch`. It is a last line of defence at a few boundaries, never a
  way to handle errors you expected.
]

=== `recover` only works on its own goroutine

A deferred `recover` in `main` does nothing for a panic on any other
goroutine. Create `lab/gopanic/main.go`:

#src("workbook/ch03/step7/lab/gopanic/main.go")

#session(
  ("go build -trimpath -o gopanic ./lab/gopanic", none),
  ("./gopanic", "ch03/s7-gopanic.txt"),
  ("echo $?", "ch03/s7-gopanic.code"),
)

Neither line in `main` prints. The panic unwinds the worker goroutine, finds
no `recover` there, and the runtime kills the process with status 2. That is
the same status the contract uses for a usage error, so a pipeline can't
tell "you typed a bad flag" from "the tool crashed". The `[recovered, repanicked]` suffix is `sync.WaitGroup.Go` at work: its wrapper recovers the
panic only to panic again without calling `Done`, so that `Wait` can't
return and let `main` exit with status 0 before the crash completes. The
shorter `[recovered, repanicked]` form of the message is new in Go 1.25;
older releases printed the panic value twice.

The rule that follows: every goroutine that runs code which might panic
needs its own boundary, or a panic there takes the whole process down. That
is often what you want in a daemon (more on that below). In a CLI it means
you lose the report.

=== Recovering at boundaries

There are three boundaries in a typical platform tool. *The top of `main`*,
where `Program.Run` will recover panics on the main goroutine. *Goroutines
you start*, where work crosses onto another goroutine; there, a panic must
become an error that can travel back to `Run` like any other failure.
Create `pkg/clierr/panic.go`:

#src("workbook/ch03/step7/pkg/clierr/panic.go")

The stack is captured inside the deferred function, while the panicking
frames are still on the stack. Capture it after `Safe` returns and you get a
stack trace of the code that called `Safe`, which shows nothing useful.
`Unwrap` returns the panic value when it is an error, so
`errors.AsType[runtime.Error]` can find the runtime's own error inside.

*Requests in a server* are the third boundary. `net/http` recovers panics in
handlers for you, on the theory that one bad request shouldn't take down a
server handling thousands of good ones. It logs the panic and a stack trace
to the server's `ErrorLog` and drops the connection, or resets the stream on
HTTP/2. Create `lab/httppanic/main.go`, a server with two handlers, `/boom`,
which writes to a nil map, and `/abort`, which panics with
`http.ErrAbortHandler`. It calls each once, and its log writer keeps the
first line of each entry and counts the rest:

#src("workbook/ch03/step7/lab/httppanic/main.go")

#output("ch03/s7-httppanic.txt", cmd: "go run ./lab/httppanic")

The client gets no status code at all, just `EOF`, which load balancers and
retry logic treat as a transport failure. Panicking with
`http.ErrAbortHandler` aborts the response the same way without the log
entry, which is meant for handlers that detect the client is gone. The usual
fix for the missing status code is a recovery middleware that writes a 500
with a request ID before the connection closes; Chapter 13 covers HTTP
middleware.

#internals(title: [Why `errgroup` doesn't carry panics back to `Wait`])[
  `golang.org/x/sync/errgroup` deliberately lets a panic in `g.Go` crash the
  process. The comment in its source lists the reasons: propagating panics
  to `Wait` delays them arbitrarily, "turns f's panic stack into a mere
  value, hiding it from crash-monitoring tools", and risks deadlocks that
  hide the panic entirely if the panic left the program unable to reach
  `Wait`. `clierr.Safe` accepts those costs for a CLI and mitigates the
  second: it records the stack at recovery time, and `Run` writes it to a
  crash file. For a long-running daemon, the errgroup authors' choice is
  usually the better one. Crash, let Kubernetes restart the pod with a clean
  heap, and let the crash loop alert someone, rather than keep serving with
  state that a bug just corrupted.
]

=== A crash becomes a report

`CodeOf` gets the panic check, at the very top: a bug is a bug even if the
code that panicked was about to time out.

#src("workbook/ch03/step7/pkg/clierr/code.go", region: "codeof")

`Program` gains three fields: a `Version` for the report, a `CrashDir`, and
a `BugURL` that tells users where to send it. `Run` recovers on its own
goroutine and sends the `*PanicError` through the same `report` path as any
other failure, so a crash is just one more kind of failure with its own code
and its own output:

#src("workbook/ch03/step7/pkg/clierr/program.go", region: "imports")
#src("workbook/ch03/step7/pkg/clierr/program.go", region: "program")
#src("workbook/ch03/step7/pkg/clierr/program.go", region: "run")
#src("workbook/ch03/step7/pkg/clierr/program.go", region: "report")

`Run`'s result is now named, so the deferred function can set it, as in the
box above. Note the two `defer` lines: deferred calls run last in, first
out, so the recovery and its report happen first and the cleanups after
them, which is what step 6's log file needs. In `report`, a panic keeps code
70 even if a signal arrived, and gets a crash file.

The report and the operator record both gain a crash file field:

#src("workbook/ch03/step7/pkg/clierr/program.go", region: "reportstruct")
#src("workbook/ch03/step7/pkg/clierr/program.go", region: "print")
#src("workbook/ch03/step7/pkg/clierr/program.go", region: "log")

`crash` writes the file and rewrites the report around it:

#src("workbook/ch03/step7/pkg/clierr/program.go", region: "crash")
#src("workbook/ch03/step7/pkg/clierr/program.go", region: "crashdir")

The file is created with `os.CreateTemp`, which matters more than it looks.
`/tmp` is shared by every user on the machine. A predictable name such as
`/tmp/deployctl-crash.txt` lets another user create a symlink there in
advance and have your process overwrite a file of their choosing.
`CreateTemp` picks a random name and opens it with `O_EXCL` and mode 0600. If
even that fails, on a read-only file system for example, the stack goes to
stderr after all, because a crash nobody can diagnose is worse than an ugly
terminal.

=== Stack traces and diagnostics <sec-err-stacks>

Go errors don't carry stack traces, by design. Capturing a stack would cost
a call to `runtime.Callers` and an allocation on every error, including the
many errors that are expected and handled a few frames up: `io.EOF` at the
end of every stream, `fs.ErrNotExist` when probing for an optional file.
Good wrapping gives you something better than a stack for most failures: a
_logical_ trace in the program's own vocabulary
(`deploy eu-west-1: post /v1/deploy: 503`) that survives refactoring and
reads well in a log. The once-popular `github.com/pkg/errors` package records
a stack trace in every error it creates or wraps. When Go 1.13 brought
wrapping into the standard library, it took the wrapping half of that design
and left stacks out on purpose.

Stacks earn their cost where the logical trace runs out: panics, and
internal errors that mean an invariant broke. `clierr` captures them only
for panics, with `runtime/debug.Stack`, which formats the current
goroutine's stack the way the runtime prints it in a crash. The crash report
pairs the stack with the build, read with `debug.ReadBuildInfo` (Chapter 1
introduced it):

#src("workbook/ch03/step7/pkg/clierr/program.go", region: "crashreport")

The header is what turns "it crashed" into a reproducible bug report: the
module version, the toolchain, the platform and the exact commit, including
whether the working tree had uncommitted changes. Build release binaries
with `-trimpath`, so the frames show module paths instead of the build
machine's home directory: better for reproducibility, and a crash report
doesn't reveal the build machine's user name.

#newingo("1.24", title: [Version stamping from version control])[
  `go build` sets the main module's version from the VCS tag or commit, with
  a `+dirty` suffix when the working tree has uncommitted changes, and
  `debug.ReadBuildInfo` reports it. Before Go 1.24, a binary built from a
  checkout reported `(devel)` and you had to stamp a version yourself with
  `-ldflags "-X main.version=..."`. `-buildvcs=false` turns the stamping
  off.
]

=== The panics `recover` can't see

Some failures never reach a deferred `recover`: a panic on a goroutine
without `Safe`, concurrent map writes, running out of memory, every
goroutine blocked forever. The runtime prints its report to stderr and exits
with status 2. `runtime/debug.SetCrashOutput` (Go 1.23) names an additional
file that receives the same report. `Main` opens a fresh file in the crash
directory at start-up, points the runtime at it, and deletes it on a normal
exit:

#src("workbook/ch03/step7/pkg/clierr/program.go", region: "main")
#src("workbook/ch03/step7/pkg/clierr/program.go", region: "fatal")

The cost is creating and removing one empty file per run, which is
negligible next to process start-up. The benefit is that when a tool dies in
a cron job or a CI step whose stderr was truncated or discarded, the full
runtime report is still on disk. A test in step 8 checks that a run which
ends normally, even one that recovered a panic, leaves no such file behind.

`GOTRACEBACK` controls how much the runtime's own report contains: `single`
(the default) shows the failing goroutine, `all` adds every goroutine the
program created, `system` adds runtime frames, and `crash` is `system` plus
a `SIGABRT` on Unix so the kernel can write a core dump. For daemons under
Kubernetes, `GOTRACEBACK=all` is a cheap setting that makes the pod's last
log lines far more useful.

=== A bug to crash on

`deployctl` needs a bug. `status` prints what each target runs and what it
ran before, and it dereferences `r.Previous` without checking it. The bug is
deliberate and documented with a `BUG(ch03)` comment, so `go doc` lists it.
Create `cmd/deployctl/status.go`:

#src("workbook/ch03/step7/cmd/deployctl/status.go")

Register it in `run` and the usage text, and give the `Program` a bug URL:

#src("workbook/ch03/step7/cmd/deployctl/main.go", region: "main")
#src("workbook/ch03/step7/cmd/deployctl/main.go", region: "run")
#src("workbook/ch03/step7/cmd/deployctl/main.go", region: "usage")

The rollout's workers are goroutines `Run` can't see into, so each one calls
`Safe`. A bug in one target's code path becomes that target's error, the
other targets finish, and the `*PanicError` in the tree still makes the
whole run exit 70:

#src("workbook/ch03/step7/cmd/deployctl/deploy.go", region: "deployone")
#src("workbook/ch03/step7/cmd/deployctl/deploy.go", region: "targeterr")

=== Tests, and a leak check

Code that starts goroutines should prove it stops them. goleak, from Uber,
fails a test binary that ends with goroutines still running. Add it to the
module:

#session(
  ("go get go.uber.org/goleak@v1.3.0", "ch03/s7-goget.txt"),
  ("go mod tidy", "ch03/s7-tidy.txt"),
)

`clierr_test.go` gets it in a `TestMain`, a row for `CodeOf`, and three
tests: a panic on `Run`'s goroutine becomes a crash file and no stack on
stderr, `Safe` carries a panic across goroutines with its stack, and a crash
directory that can't be written falls back to stderr:

#src("workbook/ch03/step7/pkg/clierr/clierr_test.go", region: "imports")
#src("workbook/ch03/step7/pkg/clierr/clierr_test.go", region: "testmain")
#src("workbook/ch03/step7/pkg/clierr/clierr_test.go", region: "codeofpanic")
#src("workbook/ch03/step7/pkg/clierr/clierr_test.go", region: "panic")
#src("workbook/ch03/step7/pkg/clierr/clierr_test.go", region: "safe")
#src("workbook/ch03/step7/pkg/clierr/clierr_test.go", region: "fallback")

`TestMain` replaces the test binary's default `main`; `goleak.VerifyTestMain`
runs the tests and then fails if any goroutine is left. The `deployctl` test
runs the buggy command through `Run`:

#src("workbook/ch03/step7/cmd/deployctl/run_test.go", region: "step7")

#needspace(12em)
#checkpoint(step: 7, of: 8, title: [Panics and crash reports])[
  #output("ch03/s7-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch03/s7-test.txt", cmd: "go vet ./... && go test ./...")
  The crash report reads the commit from version control, so commit your
  work first, then build with `-trimpath` and run the buggy command against
  the restarted fake API:
  #session(
    ("git init -q && git add . && git commit -qm \"deployctl, step 7\"", "ch03/s7-git.txt"),
    ("go build -trimpath ./cmd/deployctl", "ch03/s7-build.txt"),
    ("./deployctl -config staging.json status", "ch03/s7-panic.txt"),
    ("echo $?", "ch03/s7-panic.code"),
  )
  The user gets four lines: what happened, that it is not their fault, where
  the details are, and where to send them. Exit status 70 tells the pipeline
  this is a bug in the tool and not something a retry or a config change
  will fix. The stack went to a file; on macOS, `$TMPDIR` is a directory of
  your own rather than `/tmp`, and the path in the report says which:
  #output("ch03/s7-crashfile.txt", cmd: "head -n 20 $TMPDIR/deployctl-crash-*.txt")
  The capture shortens the long hexadecimal argument values so they fit the
  page; everything else is as written. The run ended through `Main`, so the
  file for the runtime's own crash output was removed:
  #output("ch03/s7-nofatal.txt", cmd: "ls $TMPDIR/deployctl-fatal-*")
  #troubleshoot(
    ([#ts("s7-catch.txt")], [`recover` moved into a helper that the deferred function calls. There it returns `nil`, and the panic kills the test binary.], [Call `recover()` directly in the deferred function.]),
    ([#ts("s7-tmp.txt")], [A crash file at a fixed path in `/tmp`, which another user can pre-create as a symlink. `gosec` flags it.], [`os.CreateTemp(p.crashDir(), ...)`.]),
    ([#ts("s7-nowait.txt")], [The test joins the errors before the workers have finished, without `wg.Wait()`, so it reads them too early.], [Wait for the goroutines before reading what they wrote.]),
  )
]

#step(8, 8, "Testing error paths", label: <sec-err-step-testing>)

Error paths are the code that runs least often and matters most when it
does. They need the same tests as the happy path, at three levels. The
first two are already in place: tests that assert on error _identity_ with
`errors.Is` and `errors.AsType` rather than on wording (steps 1 to 7), and
golden files for the exact text people read (steps 4 and 6). The third level
is the one only a process has: the exit code, the bytes on stderr, and what
happens on a real signal. This step tests those by building the binary and
running it.

=== Exit codes from the real binary <sec-err-testing>

#goconcept(title: [`TestMain` and running binaries from tests])[
  If a test package defines `func TestMain(m *testing.M)`, the test binary
  calls it instead of running the tests directly; `m.Run()` runs them and
  returns the status to exit with. It is the place for set-up that every
  test in the package shares, such as building a binary once. `os/exec`
  runs it: `exec.CommandContext(ctx, path, args...)` builds a `*exec.Cmd`,
  whose `Dir`, `Env`, `Stdout` and `Stderr` fields set up the process, and
  `cmd.Run()` starts it and waits. A non-zero exit is an error of type
  `*exec.ExitError`, and its `ExitCode()` method returns the status, or -1
  if the process was killed by a signal. Chapter 6 covers both in depth.
]

Create `cmd/deployctl/main_test.go`. It only runs on Unix, because it sends
real signals:

#src("workbook/ch03/step8/cmd/deployctl/main_test.go", region: "head")

`TestMain` builds `deployctl` once into a temporary directory. Building once
matters: `go run` in every test would compile the program dozens of times,
and it would also put `go run`'s own process between the test and
`deployctl`. `go run` exits 1 whenever the program fails, whatever status
the program chose, so the one thing these tests check would be lost. Note
that the build is a plain `go build`: `go test -race` does not make this
binary race-enabled. If the build fails, no test runs and the package fails
with the compiler's message on stderr:

#src("workbook/ch03/step8/cmd/deployctl/main_test.go", region: "testmain")

Each test gets a directory with config files that point at its own fake API
server, and a command that runs there with a valid token. Crash reports go
to that directory too, through `TMPDIR`, so a test can look for them:

#src("workbook/ch03/step8/cmd/deployctl/main_test.go", region: "env")

A small helper runs a command and pulls the status out of the
`*exec.ExitError` that `cmd.Run` returns for a non-zero exit, using
`errors.AsType` like any other typed error:

#src("workbook/ch03/step8/cmd/deployctl/main_test.go", region: "exitcode")

`TestExitCodes` is the contract as a table: argument lists, environment
overrides, expected codes, and golden stderr files where the exact text
matters:

#src("workbook/ch03/step8/cmd/deployctl/main_test.go", region: "table")
#src("workbook/ch03/step8/cmd/deployctl/main_test.go", region: "golden")

The partial-failure case passes `-parallel 1`, so the targets fail in input
order and the golden file is stable. Anything a golden file can't hold
stable, such as a request ID or a timing, has to stay out of it or be
masked; Exercise 3.3 runs into that. Two more tests do things a table can't.
One runs the buggy `status` command and checks that the crash report exists,
that no stack reached stderr, and that no `-fatal-` file was left behind:

#src("workbook/ch03/step8/cmd/deployctl/main_test.go", region: "crash")

The other reads stdout until `us-east-1` has deployed, sends a real `SIGINT`,
and expects 130 and an accurate "1 of 2 targets not updated":

#src("workbook/ch03/step8/cmd/deployctl/main_test.go", region: "interrupt")

The last two check the codes the contract _infers_: an unreadable config
file is 77 through `fs.ErrPermission`, and with `-o json` stderr is one JSON
document a program can parse:

#src("workbook/ch03/step8/cmd/deployctl/main_test.go", region: "more")

Write the golden files the first time with `-update`, read each one, and
commit them with the test.

#needspace(12em)
#checkpoint(step: 8, of: 8, title: [Testing error paths])[
  #output("ch03/s8-tree.txt", cmd: "find . -name '*.go' -o -name '*.golden' | sort")
  #output("ch03/s8-test.txt", cmd: "go vet ./... && go test -race ./...")
  The contract, one subtest per row:
  #output("ch03/s8-exitcodes.txt", cmd: "go test -count=1 -v -run TestExitCodes ./cmd/deployctl 2>&1 | grep -E '^(--- |    --- |ok)'")
  #output("ch03/s8-catgolden.txt", cmd: "cat cmd/deployctl/testdata/partial.golden")
  #troubleshoot(
    ([#ts("s8-golden.txt")], [A user-facing message changed. The golden file shows the old and new text side by side.], [If the change is intended, `go test ./cmd/deployctl -update`, and review the diff of `testdata` like code.]),
    ([#ts("s8-assert.txt")], [A type assertion for `*exec.ExitError`. It works today, and stops working the day a helper wraps the error.], [`errors.AsType[*exec.ExitError](err)`.]),
    ([#ts("s8-nosignal.txt")], [`Main` doesn't install the signal handler, so `SIGINT` kills the process: no report, and `ExitCode()` is -1.], [Restore `notifyContext` in `Main`.]),
  )
]

=== Promoted to the repository

Step 8 is the production code. The repository's `pkg/clierr` is this step's
`pkg/clierr`, and `examples/ch03` holds `deployctl`, `fakeapi` and the labs,
with `github.com/rahulbalajee/platform-go/...` import paths. The file
`workbook/ch03/SYNC` lists the pairs, and CI fails if they drift apart. Other
tools in the book adopt `clierr` the way `deployctl` did: their `main`
becomes `p.Main(...)` around their existing `run`, the usage paths return
`Code: clierr.ExitUsage`, and an interrupted run needs no code at all,
because `Run` reads the signal cause from the context.

== Failure policy in production <sec-err-production>

=== Error budgets for tools

Exit codes are also telemetry. If every CI job records the exit status of
the platform tools it calls, the distribution tells you things no single
failure does. A rising share of 70s is a bug in the tool, and it should page
the team that owns the tool, not the team whose pipeline it broke. A steady
trickle of 75s is a dependency that is slower than its callers assume. A lot
of 2s after a release means the new flags or config format confused people,
which is a documentation bug. Treat the tool like a service: give it an
error budget, for example "fewer than 0.1% of runs end in 70", and spend
engineering time when it is exceeded.

At 1,000 services and 200 engineers, these numbers are the only way to see
the tool's quality at all. Nobody files a ticket for a confusing error
message. They ask a colleague, add a workaround to their pipeline, and the
workaround outlives everyone involved.

=== Failing safe and failing open

A deploy gate (Chapter 4's `sweep` run before promotion, or a policy check)
has three outcomes, not two: the check passed, the check failed, or the
check could not be evaluated because the metrics backend was down or the
gate itself crashed. What the pipeline does in the third case is a policy
decision. Make it on purpose, in the pipeline, rather than by accident in
the tool.

#production(title: [Fail closed by default, and make the exception visible])[
  A gate that protects production should fail closed: if it can't evaluate,
  the deploy doesn't proceed. That only works if "couldn't evaluate" is
  distinguishable from "evaluated and failed", which is what 75 versus 1
  gives you. The pipeline can retry on 75, stop on 1, and stop and alert on
  70. Failing open, proceeding when the gate can't evaluate, is sometimes the
  right trade for advisory checks such as cost estimates or lint, but make
  it explicit: an `--allow-unavailable` flag that is logged on every use, and
  a break-glass path for incidents that leaves an audit record. The worst
  version is the accidental one, a gate wrapped in `|| true` because it was
  flaky, which has been failing open silently for months.
]

The same thinking applies inside the tool. `deployctl` checks credentials
before changing anything, so 77 always means "nothing happened". It reports
partial progress precisely, so a re-run with `-only` is safe. It treats an
unknown error as a failure (1), never as success. Those are all choices
about which way the tool fails when something unexpected happens.

#interview(title: [“How do you handle errors in Go?”])[
  A senior answer goes past `if err != nil`. Errors are values, so design
  them for their consumers. Inside the code, wrap with `%w` to add context,
  handle or return but never both, and inspect with `errors.Is` and
  `errors.AsType` (Go 1.26), never by matching strings. Choose the error kind
  by the caller's decision: sentinels for identity, types for data,
  behaviours such as `Timeout()` for retry logic, opaque errors by default.
  Know that `Join` and multiple `%w` build trees that `Is` and `As` search
  depth first. Use context causes so a timeout and a #kbd("Ctrl-C") read
  differently. At the edge, translate once: a message and hint for people, a
  structured log record for operators, and a documented exit code for
  machines. Panics are for bugs; recover at goroutine and request
  boundaries, keep the stack, and remember a `recover` only works on its
  own goroutine. Then give one production example, such as a deploy tool
  whose pipeline retries on 75 and stops on 77.
]

#takeaways(
  [Failure has four audiences: the person (message, hint, docs), the caller (exit code, JSON), the operator (structured log with the cause chain) and the maintainer (crash report). Serve each from one error, reported once at the top.],
  [Wrap with `%w` to add context; `errors.Is` and `errors.AsType` (Go 1.26) walk the chain. `Join` and multiple `%w` make trees that are searched depth first, and `errors.Unwrap` doesn't see into them.],
  [Pick the error kind by the decision the caller makes: sentinel, type, behaviour, or opaque by default. Wrapping a dependency's error type makes it part of your API.],
  [Use context causes, and make a cause wrap `context.DeadlineExceeded` when it reports a timeout. `net/http` fails with `context.Cause(ctx)`, so test against the cause.],
  [An exit code is a small, documented enumeration that pipelines branch on. Keep 0/1/2, add codes only for new decisions (70 bug, 75 retry, 77 auth), never renumber, and set `pipefail`.],
  [Panics are for bugs. Recover at boundaries (main, goroutines via `Safe`, requests), capture the stack at the point of recovery, write it to a file, and tell the user what to do.],
  [Test error identity with `errors.Is`/`AsType`, user-facing text with golden files, and exit codes by running the real binary, signals included.],
)

#exercise-set(3,
  (
    tier: "warm-up",
    title: [Predict the exit code],
    body: [
      Without running anything, predict what `clierr.CodeOf` returns for each
      error, using @fig-err-codeof: (a) `fmt.Errorf("upload: %w", os.ErrDeadlineExceeded)`; (b) `&clierr.Error{Code: clierr.ExitUsage, Err: context.DeadlineExceeded}`; (c) `fmt.Errorf("deploy: %v", context.DeadlineExceeded)`; (d) `&clierr.Error{Message: "stopped", Err: &clierr.SignalError{Signal: syscall.SIGTERM}}`; (e)
      `errors.Join(&fs.PathError{Op: "open", Path: "a", Err: fs.ErrNotExist}, context.DeadlineExceeded)`. Then add the five as rows
      to `TestCodeOf` and check. One of them is a trap; explain it.
    ],
    hint: [`AsType` stops at the _first_ error of the type it is looking for. Which errors in (e) have a `Timeout` method?],
  ),
  (
    tier: "warm-up",
    title: [Did you mean?],
    body: [
      `deployctl deplyo` says `unknown command "deplyo"`. Make the hint start
      with `did you mean "deploy"? ` when a real command (`init`, `deploy`,
      `status`) is at most two edits away (insertions, deletions or
      substitutions of one byte), followed by the existing `run "deployctl -h" for usage`. With nothing that close, the hint must not change. The
      exit code stays 2.
    ],
    hint: [Write the edit distance as a function of two strings first, with a table test of its own.],
    tests: "workbook/ch03/exercises/ex2",
  ),
  (
    tier: "core",
    title: [Every request ID],
    body: [
      `errors.AsType` finds only the first match. Add a generic
      `clierr.All[E error](err error) []E` that returns every error of type
      `E` in the tree, in the order `errors.As` would visit them. Then use it
      in `rolloutError` so the `DPL-PARTIAL` hint ends with `; quote req-..., req-... if you ask for help`, listing the request ID of every
      failed target, in the order the failures are listed. `TestExitCodes`
      will fail afterwards, for a reason worth understanding; fix the test,
      not the feature.
    ],
    hint: [Start from `clierr.Chain`. For the golden file: what is different in every run?],
    tests: "workbook/ch03/exercises/ex3",
  ),
  (
    tier: "core",
    title: [Say where],
    body: [
      A config file with a JSON mistake reports `config file prod.json is not valid JSON` and a hint that tells the user to read the cause, which the
      report no longer prints. Make the hint say where: `line L, column C: `
      (both counted from 1, for the last byte the decoder read) followed by
      the decoder's own message for a syntax error, or by the field's name
      in quotes and what it should be for a value of the wrong type, such as
      `"targets" must be a list, not a string`. The ID and the exit code
      don't change.
    ],
    hint: [`*json.SyntaxError` and `*json.UnmarshalTypeError` both have an `Offset`. It counts bytes read, not bytes before the problem.],
    tests: "workbook/ch03/exercises/ex4",
  ),
  (
    tier: "core",
    title: [Honour `Retry-After`],
    body: [
      A 503 or 429 can carry a `Retry-After` header that says how many
      seconds to wait. Add a `RetryAfter time.Duration` field to `APIError`,
      filled from the header (seconds, or an HTTP date), and make `do` wait
      that long instead of its own backoff when it is set. If the wait would
      end after the context's deadline, don't start it: return a
      `*RetryError` for the attempts made so far, at once.
    ],
    hint: [The acceptance tests run in a `synctest` bubble, so "at once" means exactly zero elapsed time. `ctx.Deadline()` tells you whether there is a deadline.],
    tests: "workbook/ch03/exercises/ex5",
  ),
  (
    tier: "core",
    title: [`%w` or `%v`?],
    body: [
      Three places in `deployctl` decide whether a cause becomes part of the
      error's API: `send` wraps the JSON decoder's error with `%w`, `do`
      returns `net/http`'s `*url.Error` as it is, and `loadConfig` keeps the
      `*fs.PathError` in `clierr.Error.Err`. For each, say what a caller can
      depend on today, what would break if it switched to `%v` (or to a
      wrapped copy of the message), and which choice you would make if
      `Client` moved into a package other teams import. Then name one error
      in `deployctl` that should stay opaque, and say why.
    ],
    hint: [Who calls each function today? Which of them make a decision based on the cause, and which only print it?],
  ),
  (
    tier: "stretch",
    title: [Stop after N failures],
    body: [
      A rollout to forty regions should not keep going after the fifth
      failure. Add `-max-failures N` to `deploy` (0, the default, means no
      limit; negative is a usage error). Once N targets have failed, start no
      more. Targets already running finish normally. Targets never started
      are reported as `skipped` in the results, their errors wrap a new
      sentinel `ErrSkipped`, they are included in the `-only` hint, and the
      headline ends with `; S skipped`. With `-parallel 1`, no target may
      start after the limit is reached, however the goroutines are
      scheduled.
    ],
    hint: [The race is between "the loop saw the Nth failure" and "the starter took a free slot". Who frees the slot decides who wins.],
    tests: "workbook/ch03/exercises/ex7",
  ),
)
