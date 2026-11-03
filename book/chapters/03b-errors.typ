#import "../template/book.typ": *
#import "03-lib.typ": ts

#step(4, 8, "An exit-code contract", label: <sec-err-step-codes>)

Every failure so far exits 1, and every message ends in the raw cause chain.
This step separates the three things a failure has to tell its audiences:
an exit code for the program that ran `deployctl`, a message and hint for the
person, and the chain for whoever debugs it. The code that does this is not
specific to deploying, so it goes in a package of its own, `pkg/clierr`,
which every command-line tool in the book shares.

=== Exit codes are an API <sec-err-exit>

When a process exits, its parent receives a status. On Unix the exit code
part of that status is 8 bits wide: the parent sees `code & 0xff`, so
`os.Exit(256)` reports success. That sounds like trivia until someone writes
`os.Exit(len(failed))`. Create `lab/exitcount/main.go`:

#src("workbook/ch03/step4/lab/exitcount/main.go")

#session(
  ("go build -o exitcount ./lab/exitcount", none),
  ("./exitcount", "ch03/s4-exitcount.txt"),
  ("echo $?", "ch03/s4-exitcount.code"),
)

Two hundred and fifty-six failures, exit status 0, and the pipeline moves on.
An exit code is a small enumeration, not a count.

No standard covers every value, but several conventions are old enough that
shells, CI systems and other people's scripts assume them:

#table(
  columns: (auto, 1fr),
  table.header([Status], [Convention]),
  [0], [Success. The only value every caller agrees on.],
  [1], [General failure. `grep` and `diff` use it for "the answer is no" (no match, files differ), which is a successful run with a negative result.],
  [2], [Misuse: bad flags or arguments (`grep`, `diff`, bash builtins). Go's runtime also exits 2 after an unrecovered panic, and the `flag` package exits 2 on a parse error with `ExitOnError`.],
  [64–78], [`sysexits.h` from 4.3BSD: 64 `EX_USAGE`, 69 `EX_UNAVAILABLE`, 70 `EX_SOFTWARE`, 75 `EX_TEMPFAIL` ("user is invited to retry"), 77 `EX_NOPERM`, 78 `EX_CONFIG`. Mail software still uses them; few other programs do, but the numbers are documented and unclaimed.],
  [126, 127], [Set by the shell, not the program: the command was found but could not be executed (126), or was not found (127).],
  [128 + _n_], [The shell's report for a child killed by signal _n_: 130 for `SIGINT`, 137 for `SIGKILL` (including the kernel's OOM killer), 143 for `SIGTERM`. A program that catches the signal and exits on its own picks this value to say "I stopped because of signal _n_".],
  [255], [Often `exit(-1)` truncated to 8 bits; `ssh` uses it for its own connection errors, so a remote command's 255 is ambiguous.],
)

`clierr` commits to seven values. It keeps the meanings of 0, 1, 2 and 128 +
_n_ that every tool in the book shares, and adds three codes that callers
need to make different decisions, borrowing the `sysexits.h` numbers so they
neither collide with the shell's reserved ranges nor need inventing:

#table(
  columns: (auto, auto, 1fr),
  table.header([Code], [Meaning], [What a pipeline should do]),
  [0], [Success], [Continue.],
  [1], [Ran, and the answer is no: checks or targets failed], [Fail the step. Retrying without a change rarely helps; the output says what failed.],
  [2], [Bad flags, arguments or configuration], [Fail fast and never retry. A human has to change the command or the config.],
  [70], [Internal error: a bug. A crash report was saved], [Fail, and treat it as a defect in the tool: count it, alert on it, file it.],
  [75], [Timed out or dependency unavailable], [Retry with backoff. It is the only code that promises a second try can succeed.],
  [77], [Authentication or permission denied], [Fail fast. Retrying an expired token can lock the account.],
  [130, 143], [Interrupted by `SIGINT`, `SIGTERM`], [Usually a cancelled job; retry if the cancellation wasn't deliberate.],
)

Every code earns its place by changing what a caller does. That is the test
for adding one. "Config file is YAML instead of JSON" and "config file is
missing" are different messages but the same decision, so they share 2.
"Token expired" and "eu-west-1 is unhealthy" lead to different decisions (do
not retry, retry later), so they get different codes.

=== The contract in code

Create `pkg/clierr/code.go`. The package comment says what the package is
for, and the contract is a named type with documented constants:

#src("workbook/ch03/step4/pkg/clierr/code.go", region: "head")
#src("workbook/ch03/step4/pkg/clierr/code.go", region: "codes")

`Code` is its own type rather than a bare `int`, so a function that returns
one documents what it returns, and `String` gives each value a short name
for logs and test failures:

#src("workbook/ch03/step4/pkg/clierr/code.go", region: "string")

The comment on `ExitInterrupted` is the reason step 5 can return 143 for
`SIGTERM` without a constant of its own.

=== An error with two audiences

`pkg/clierr/error.go` holds the error type the rest of the package is built
around:

#src("workbook/ch03/step4/pkg/clierr/error.go", region: "imports")
#src("workbook/ch03/step4/pkg/clierr/error.go", region: "error")

`Message`, `Hint` and `Docs` are written for the person at the terminal, in
their terms. `Err` is the cause chain, written by and for programmers. The
two are separate because they change for different reasons. "The deploy API
rejected your token" is true whether the cause is an HTTP 401, a gRPC
`Unauthenticated` status, or an expired file on disk.

`Error()` still returns the whole thing, message and cause, so an `*Error`
that ends up in a log or gets wrapped again by `fmt.Errorf` loses nothing.
`ID` is a stable string a user can search for and a support engineer can
recognize at a glance. A zero `Code` means "work it out from the cause",
which lets code create an `*Error` for its message and hint without
second-guessing whether the underlying failure was a timeout or a
permission problem.

Two functions pick what a person sees:

#src("workbook/ch03/step4/pkg/clierr/error.go", region: "usermsg")

`UserMessage` takes the `Message` of the first `*Error` in the tree, or
falls back to the raw `err.Error()` if nobody wrote one. `details` handles
step 3's ugly joined message: when an `*Error`'s cause has an
`Unwrap() []error` method, the report lists the `UserMessage` of each child
on its own line. It asserts on the interface directly, without `AsType`,
because it wants to know about this node, not one further down.

=== Mapping errors to codes

The last part of `code.go` decides the code:

#src("workbook/ch03/step4/pkg/clierr/code.go", region: "codeof")

The order of the checks is the design. An explicit `Code` on an `*Error`
wins over inference, because the code that built the error knew more than a
generic rule can. Inference then uses behaviour (`Timeout()`, which
`net.Error`, `os.ErrDeadlineExceeded` and `context.DeadlineExceeded` all
have) and a well-known sentinel (`fs.ErrPermission`). Anything left is a
plain failure, exit 1. `flag.ErrHelp` maps to 0, because `-h` is a request
that succeeded. @fig-err-codeof shows the whole order; the two rows above the
explicit `Code` arrive in steps 5 and 7, and go on top because a signal or a
bug outranks whatever the interrupted work said about itself.

#fig(placement: auto, caption: [How `CodeOf` and `Run` choose an exit code. The first matching rule wins. The panic row arrives in step 7 and the signal row in step 5, where `Run` also checks the context's cause, so a signal decides the code even when the work returned a bare `context.Canceled`.])[
  #diagram(
    spacing: (30pt, 7pt),
    dnode((0, 0), [`nil` or `flag.ErrHelp`?], kind: "muted"),
    dnode((0, 1), [`*PanicError` in the tree? #h(2pt) *7*], kind: "muted"),
    dnode((0, 2), [`*SignalError` in the tree or\ as the context's cause? #h(2pt) *5*], kind: "muted"),
    dnode((0, 3), [`*Error` with a non-zero `Code`?], kind: "muted"),
    dnode((0, 4), [something with `Timeout() == true`?], kind: "muted"),
    dnode((0, 5), [`fs.ErrPermission`?], kind: "muted"),
    dnode((0, 6), [anything else], kind: "muted"),
    dnode((1, 0), [0 · nothing printed], kind: "good"),
    dnode((1, 1), [70 · crash report], kind: "warn"),
    dnode((1, 2), [128 + _n_ · 130, 143], kind: "accent"),
    dnode((1, 3), [that `Code`], kind: "accent"),
    dnode((1, 4), [75 · retry may work], kind: "accent"),
    dnode((1, 5), [77 · fix credentials], kind: "accent"),
    dnode((1, 6), [1 · failed], kind: "dark"),
    ..range(6).map(i => dedge((0, i), (0, i + 1), "-|>", label: text(size: 6.2pt)[no], label-side: left)),
    ..range(7).map(i => dedge((0, i), (1, i), "-|>", label: if i < 6 { text(size: 6.2pt)[yes] } else { none })),
  )
] <fig-err-codeof>

=== Report once, at the top <sec-err-clierr>

`pkg/clierr/program.go` is where "handle or return, never both" pays off.
Nothing below it prints errors or exits; everything below it returns.

#src("workbook/ch03/step4/pkg/clierr/program.go", region: "imports")
#src("workbook/ch03/step4/pkg/clierr/program.go", region: "program")
#src("workbook/ch03/step4/pkg/clierr/program.go", region: "run")
#src("workbook/ch03/step4/pkg/clierr/program.go", region: "report")

`Run` calls the command's function, and `report` turns its error into a
code and a report. It returns the code instead of exiting, so a test can
call it with a buffer for `Stderr` and assert on both. Success, including a
request for help, prints nothing at all. The report is a plain struct; step
6 gives it JSON tags:

#src("workbook/ch03/step4/pkg/clierr/program.go", region: "reportstruct")
#src("workbook/ch03/step4/pkg/clierr/program.go", region: "print")
#src("workbook/ch03/step4/pkg/clierr/program.go", region: "stderr")

`print` builds the whole report in a `strings.Builder` and writes it with
one call. Two goroutines writing to stderr at once can interleave their
writes, but a single `Write` of a few hundred bytes reaches the terminal in
one piece. The message comes first with the program's name and the ID, then
the details, the hint and the docs link, each on its own line, indented so
the report reads as one block. `indent` keeps a multi-line message from
breaking that layout.

=== Wiring `deployctl` to `clierr`

`main` shrinks to building a `Program` and exiting with what `Run` returns.
Replace the head of `main.go` and `main`, and add a `docs` constant for the
docs links the errors will carry:

#src("workbook/ch03/step4/cmd/deployctl/main.go", region: "head")
#src("workbook/ch03/step4/cmd/deployctl/main.go", region: "docs")
#src("workbook/ch03/step4/cmd/deployctl/main.go", region: "main")

The step 1 checkpoint showed a bad flag reported twice. With
`flag.ContinueOnError`, `FlagSet.Parse` writes the error and the usage text
to the flag set's output _before_ it returns the error, and then `main`
reported the same error again. Replace `run`, and add a usage text and a
`parse` helper that every command uses:

#src("workbook/ch03/step4/cmd/deployctl/main.go", region: "run")
#src("workbook/ch03/step4/cmd/deployctl/main.go", region: "usage")
#src("workbook/ch03/step4/cmd/deployctl/main.go", region: "parse")

`parse` silences the flag set with `io.Discard`, so the report is the only
place an error appears. A parse error becomes an `*Error` with `ExitUsage`
and a hint that names the right `-h`. On `-h`, `parse` prints the usage to
stdout itself and returns `flag.ErrHelp`, which `CodeOf` maps to 0. Help goes
to stdout with status 0, because the user asked for it and may pipe it into
`less`. An error goes to stderr with status 2. Mixing those up is a small
thing that people notice every day.

The config loader gives every failure the same ID and docs link, with a
hint that matches the specific failure. Replace `config.go`'s imports,
`loadConfig` and `initConfig`:

#src("workbook/ch03/step4/cmd/deployctl/config.go", region: "imports")
#src("workbook/ch03/step4/cmd/deployctl/config.go", region: "load")
#src("workbook/ch03/step4/cmd/deployctl/config.go", region: "init")

Missing, malformed and incomplete files are all exit 2. An unreadable file
gets `Code: 0`, so `CodeOf` infers 77 from `fs.ErrPermission` and the message
stays the same; step 8 tests that. The rejected token becomes exit 77, with
the request ID in the hint, where the user will see it. Replace the imports
and `checkAuth` in `client.go`:

#src("workbook/ch03/step4/cmd/deployctl/client.go", region: "imports")
#src("workbook/ch03/step4/cmd/deployctl/client.go", region: "auth")

The preflight check from step 2 is what makes 77 a reliable signal: it
always means "nothing was changed", so the pipeline can stop retrying
without wondering what state it left behind.

=== A partial rollout is exit 1

`deploy.go` changes in five places. The imports gain `clierr`, and `deploy`
uses `parse` and `usageError` with its own usage line:

#src("workbook/ch03/step4/cmd/deployctl/deploy.go", region: "imports")
#src("workbook/ch03/step4/cmd/deployctl/deploy.go", region: "usage")
#src("workbook/ch03/step4/cmd/deployctl/deploy.go", region: "deploy")

`rollout` turns each failure into a one-line `*Error` with the target's
name, and builds the final error with a new function:

#src("workbook/ch03/step4/cmd/deployctl/deploy.go", region: "rollout")
#src("workbook/ch03/step4/cmd/deployctl/deploy.go", region: "outcome")
#src("workbook/ch03/step4/cmd/deployctl/deploy.go", region: "targeterr")

Two choices in `rolloutError` need defending. First, a partial failure is
exit 1, even if one of the failures was a timeout. A pipeline that retried
the whole step on 75 would redo the targets that already succeeded and run
into the same 409 again. Second, the hint is a command the user can run.
"Fix the failing targets" alone is advice; `-only sa-east-1,eu-west-1` is the
next action. `targetError` writes each target's line in the API's own words,
with the status and the number of attempts, and keeps the whole chain under
it in `Err`, where `errors.Is`, the operator log in step 6, and `names` can
still find it. `ctx` is unused for now; step 5 needs it.

=== Tests, and the first golden file

`pkg/clierr/clierr_test.go` tests the package from the outside, as a user
would, so it is in package `clierr_test`. Start with the imports and two
small fixtures, errors with the shapes `CodeOf` has to handle:

#src("workbook/ch03/step4/pkg/clierr/clierr_test.go", region: "imports")
#src("workbook/ch03/step4/pkg/clierr/clierr_test.go", region: "fixtures")

The table for `CodeOf` doubles as documentation of the contract. Each row is
a case someone will one day get wrong: a joined error, an `*Error` that
infers its code, an explicit code that must beat inference, a retry wrapper
around a timeout:

#src("workbook/ch03/step4/pkg/clierr/clierr_test.go", region: "codeof")

Exact text matters in one place, the message a person reads, because that
_is_ the interface. Golden files keep those messages under review without
hard-coding them into test source. `TestReportGolden` runs a partial failure
through `Run` and compares stderr byte for byte with a file in `testdata`:

#src("workbook/ch03/step4/pkg/clierr/clierr_test.go", region: "partial")
#src("workbook/ch03/step4/pkg/clierr/clierr_test.go", region: "golden")
#src("workbook/ch03/step4/pkg/clierr/clierr_test.go", region: "help")

The first run fails, because the golden file doesn't exist yet. `-update`
writes it, and you read it before you commit it, because from now on it is
the specification:

#session(
  ("go test ./pkg/clierr", "ch03/s4-nogolden.txt"),
  ("go test ./pkg/clierr -update", "ch03/s4-update.txt"),
  ("cat pkg/clierr/testdata/partial.text.golden", "ch03/s4-golden.txt"),
)

When a message changes on purpose, `-update` rewrites the file, and the
change shows up in code review as a diff of what users will see. Chapter 6
covers golden files and `testscript` in depth. The command's own tests check
codes, not text. Add `clierr` to `run_test.go`'s imports, and the step 4
table:

#src("workbook/ch03/step4/cmd/deployctl/run_test.go", region: "imports")
#src("workbook/ch03/step4/cmd/deployctl/run_test.go", region: "step4")

=== Shells, `set -e` and `pipefail`

Shell scripts are the most common caller of a platform tool, and they are
where exit codes get lost. `set -e` makes a script exit when a command fails,
with exceptions that surprise everyone once: it does not apply to a command
tested by `if`, `while` or `until`, to any command in an `&&` or `||` list
except the last, or to a command whose status is inverted with `!`. And by
default a pipeline's status is the status of its _last_ command. With the
fake API running, two of four targets deploy:

#session(
  ("./deployctl -config prod.json deploy v1.4.2 2>/dev/null | grep -c deployed; echo \"exit $?\"", "ch03/s4-nopipefail.txt"),
  ("set -o pipefail", none),
  ("./deployctl -config prod.json deploy v1.4.2 2>/dev/null | grep -c deployed; echo \"exit $?\"", "ch03/s4-pipefail.txt"),
)

The rollout failed, but without `pipefail` the pipeline exits 0 because
`grep` found matches. With `pipefail`, the status is the last non-zero status
in the pipeline. Bash also keeps every stage's status in the `PIPESTATUS`
array if you need to tell them apart.

#production(title: [What CI systems do with your exit code])[
  *GitHub Actions* fails a step on any non-zero status, but which shell flags
  apply depends on how the step is written. A `run:` step with no `shell:`
  runs as `bash -e {0}` on Linux and macOS runners: no `pipefail`. Writing
  `shell: bash` explicitly runs `bash --noprofile --norc -eo pipefail {0}`.
  Set `defaults.run.shell: bash` at the workflow level so every step gets
  `pipefail`.

  *GitLab CI* can act on specific codes: `retry: {max: 2, exit_codes: [75]}`
  retries only temporary failures (generally available since GitLab 17.5),
  and `allow_failure: {exit_codes: [...]}` marks chosen codes as warnings.
]

Kubernetes Jobs have a pod failure policy, stable since Kubernetes 1.31,
that maps container exit codes to actions: fail the Job at once, ignore the
failure, or count it against `backoffLimit`. With a code contract, the
policy can stop retrying a deploy that can't succeed and keep retrying one
that timed out. Create `job.yaml`:

#src("workbook/ch03/step4/job.yaml")

A server-side dry run checks the manifest against the API server's schema
and admission chain without creating the Job, which is a cheap test to keep
in CI for every Job template a platform team ships:

#output("ch03/s4-job.txt", cmd: "kubectl apply --dry-run=server -f job.yaml")

At scale, the contract outlives everyone who wrote it. When 200 engineers
have wrapped a tool in scripts, pipeline templates and Job specs, renumbering
a code is a breaking change of the worst kind, because nothing fails to
compile: some job somewhere starts retrying a bad token, or stops retrying a
timeout. Document the codes in `-h` and the README, test them (as step 8
does), never reuse a retired number, and add new ones only when a caller
needs a new decision.

#needspace(12em)
#checkpoint(step: 4, of: 8, title: [An exit-code contract])[
  #output("ch03/s4-tree.txt", cmd: "find . -name '*.go' -o -name '*.yaml' | sort")
  #output("ch03/s4-test.txt", cmd: "go vet ./... && go test ./...")
  Restart the fake API and rebuild. Each kind of failure now has its own
  code and a report in the user's terms:
  #session(
    ("go build ./cmd/deployctl", none),
    ("./deployctl -config prod.json deploy -parallel=many v1.4.2", "ch03/s4-badflag.txt"),
    ("echo $?", "ch03/s4-badflag.code"),
    ("./deployctl deploy v1.4.2", "ch03/s4-noconfig.txt"),
    ("echo $?", "ch03/s4-noconfig.code"),
    ("DEPLOYCTL_TOKEN=expired ./deployctl -config prod.json deploy v1.4.2", "ch03/s4-auth.txt"),
    ("echo $?", "ch03/s4-auth.code"),
  )
  A partial rollout lists each failure on a line of its own, and `-h` prints
  to stdout and exits 0:
  #session(
    ("./deployctl -config prod.json deploy v1.4.2", "ch03/s4-partial.txt"),
    ("echo $?", "ch03/s4-partial.code"),
    ("./deployctl -h", "ch03/s4-help.txt"),
    ("echo $?", "ch03/s4-help.code"),
  )
  #troubleshoot(
    ([#ts("s4-twice.txt")], [`parse` doesn't call `fs.SetOutput(io.Discard)`, so the flag package prints the error (and the usage) before the report does.], [Silence the flag set; the report is the only place an error is printed.]),
    ([#ts("s4-helpexit.txt")], [`deployctl -h` prints nothing at all: `parse` lost its `flag.ErrHelp` branch, and the silenced flag set no longer prints the usage either.], [Print the usage to stdout on `flag.ErrHelp`, then return it.]),
    ([#ts("s4-order.txt")], [`CodeOf` checks `Timeout()` before an explicit `Code`, so inference overrides the code the error's author chose.], [Explicit `Code` first. See "Mapping errors to codes".]),
    ([#ts("s4-details.txt")], [`print` lost the loop over `r.Details`: the report says "2 of 3 targets" and doesn't name them. The golden file notices.], [Restore the loop. Read golden diffs, never `-update` blindly.]),
  )
]

#step(5, 8, "Context causes and signals", label: <sec-err-step-causes>)

`deployctl` can't be stopped cleanly yet. A slow target holds the rollout
for as long as the API takes, and #kbd("Ctrl-C") kills the process wherever
it is, with no report and status 130 chosen by the shell. This step adds a
deadline, `-timeout`, and turns #kbd("Ctrl-C") and `SIGTERM` into a
cancelled context, so both end the rollout with a report and a code. Both
rely on the same feature: a context that remembers _why_ it was cancelled.

=== Context errors and their causes <sec-err-context>

`ctx.Err()` returns one of two values once a context is done.
`context.Canceled` means someone called `cancel`; `context.DeadlineExceeded`
means a timer fired. `DeadlineExceeded` also has `Timeout()` and
`Temporary()` methods that return `true`, so behavioural timeout checks catch
it alongside network timeouts, and `CodeOf` maps it to 75. Neither value
says _who_ cancelled or _why_, and for a tool that is the important part.
Was it #kbd("Ctrl-C")? The overall `-timeout`? One slow attempt out of
three?

#goconcept(title: [Context causes])[
  Chapter 2 introduced `context.Context`: a value passed down the call chain
  that carries a deadline and a cancellation signal. Go 1.20 and 1.21 added
  a _cause_. `context.WithCancelCause(parent)` returns a cancel function
  that takes an error, `cancel(err)`; `context.WithTimeoutCause(parent, d, err)` and `WithDeadlineCause` record `err` if the timer fires. After the
  context is done, `ctx.Err()` still returns `Canceled` or
  `DeadlineExceeded`, so existing code keeps working, and
  `context.Cause(ctx)` returns the recorded error, or `ctx.Err()` if there
  was none. A cause is any error, so it can be a sentinel, a typed error the
  caller can inspect, or, as in this step, a complete user-facing report.
]

`deployctl`'s overall deadline uses a complete, user-facing `*clierr.Error`
as its cause, with an exit code, an ID and a hint. Add a `-timeout` flag to
`deploy` and wrap the rollout's context:

#src("workbook/ch03/step5/cmd/deployctl/deploy.go", region: "deploy")

The cause wraps `context.DeadlineExceeded`. That small detail keeps code
written for plain timeouts working: `errors.Is(err, context.DeadlineExceeded)` is still true for an error whose chain contains
this cause, and so is the `Timeout()` check in `CodeOf`. A cause that wraps
nothing silently breaks every such check in the libraries below you; the
troubleshooting table shows what it does to `deployctl`.

#warning(title: [`net/http` returns the cause, not `ctx.Err()`])[
  When a request's context is cancelled, the HTTP transport fails the
  request with `context.Cause(ctx)` (look for `context.Cause` in
  `net/http/transport.go`). If the context was cancelled with a cause, the
  error from `client.Do` wraps that cause and not `context.Canceled`. Code
  like `if errors.Is(err, context.Canceled) { /* user gave up */ }` stops
  matching the moment someone upstream starts using causes, for example a
  signal handler built on `WithCancelCause`. Test against the cause itself:
  `errors.Is(err, context.Cause(ctx))`.
]

`targetError` does exactly that before it labels a target "stopped before
the API answered", and `rolloutError` makes the context's end the headline
when there was one, because then the whole rollout was cut short rather than
some targets failing:

#src("workbook/ch03/step5/cmd/deployctl/deploy.go", region: "outcome")
#src("workbook/ch03/step5/cmd/deployctl/deploy.go", region: "targeterr")

For a deadline, `rolloutError` copies the code, ID, message and hint from the
cause and keeps the per-target details. For anything else, which in
`deployctl` means a signal, it writes an "interrupted" headline that counts
the targets left behind, and leaves the code at 1: `Run` replaces it with
128 + _n_, as the next section shows.

=== Signals become a cause

Pressing #kbd("Ctrl-C") sends the process `SIGINT`; Kubernetes deleting a
pod, `docker stop` and most process supervisors send `SIGTERM`. By default
either one kills a Go program at once: no deferred calls, no report, and
the shell reports 128 + the signal's number.

#goconcept(title: [Signals and `os/signal`])[
  A signal is the operating system's way to interrupt a process.
  `signal.Notify(ch, os.Interrupt, syscall.SIGTERM)` asks the runtime to
  deliver those signals as values on `ch` instead of applying the default
  action; `signal.Stop(ch)` undoes that, so the next signal gets the default
  again. The runtime never blocks to deliver a signal: if `ch` is full, the
  signal is dropped, which is why `ch` needs a buffer (`go vet` checks).
  `SIGKILL` and `SIGSTOP` can't be caught at all, so a program must expect to
  be killed without warning; signal handling is for stopping _cleanly_ when
  it is asked politely.
]

Create `pkg/clierr/signal.go`:

#src("workbook/ch03/step5/pkg/clierr/signal.go")

`notifyContext` cancels its context with a `*SignalError` cause on the first
signal, after printing a one-line notice to stderr, so the user knows the
keystroke arrived and something is happening. Then it stops catching
signals. A rollout that is stuck shutting down can always be escaped with a
second #kbd("Ctrl-C"), which now gets the default action and kills the
process. That is Chapter 4's two-stage shutdown in its simplest form.
`stop` releases the handler and waits for the goroutine, so nothing is left
running when `Main` exits.

The standard library has `signal.NotifyContext`, and since Go 1.26 it also
sets a cause. Its type is unexported, though, and its only content is a
message such as "interrupt signal received". You can print it; you can't
get the signal number back out of it, which is what `SignalError` is for:
`signalCode` turns it into 130 for `SIGINT` and 143 for `SIGTERM`.

`CodeOf` checks for a `*SignalError` in the tree before anything else
`deployctl` can produce. Replace it:

#src("workbook/ch03/step5/pkg/clierr/code.go", region: "codeof")

Work that was interrupted often returns a bare `context.Canceled`, with no
`SignalError` in its chain, so `report` also looks at the context's cause.
`Program` gets an `Exit` hook for tests, and `Main` puts it all together:

#src("workbook/ch03/step5/pkg/clierr/program.go", region: "program")
#src("workbook/ch03/step5/pkg/clierr/program.go", region: "report")
#src("workbook/ch03/step5/pkg/clierr/program.go", region: "main")
#src("workbook/ch03/step5/pkg/clierr/program.go", region: "exit")

`os.Exit` skips deferred functions, so everything that must happen before
the process ends happens explicitly before `Main`'s last line: `Run`
reports, `stop` releases the signal handler. `deployctl`'s `main` calls
`Main` instead of `Run` and `os.Exit`:

#src("workbook/ch03/step5/cmd/deployctl/main.go", region: "main")

Create `staging.json`, with one fast target and the slow one:

#src("workbook/ch03/step5/staging.json")

=== Tests

`clierr_test.go` gains `syscall` in its imports, two rows for the `CodeOf`
table, and a test that the context's cause decides the code even when the
work returns a bare `context.Canceled`:

#src("workbook/ch03/step5/pkg/clierr/clierr_test.go", region: "imports")
#src("workbook/ch03/step5/pkg/clierr/clierr_test.go", region: "codeofsignal")
#src("workbook/ch03/step5/pkg/clierr/clierr_test.go", region: "signal")

The command's tests do in-process what `Main` does with a real signal:
cancel the context with a `*SignalError` cause. The real signal gets a test
of its own in step 8, against the real binary.

#src("workbook/ch03/step5/cmd/deployctl/run_test.go", region: "imports")
#src("workbook/ch03/step5/cmd/deployctl/run_test.go", region: "step5")

#needspace(12em)
#checkpoint(step: 5, of: 8, title: [Context causes and signals])[
  #output("ch03/s5-tree.txt", cmd: "find . -name '*.go' -o -name '*.json' | sort")
  #output("ch03/s5-test.txt", cmd: "go vet ./... && go test ./...")
  Restart the fake API and rebuild. `ap-south-1` takes three seconds, so a
  two-second deadline fires while it is still deploying:
  #session(
    ("go build ./cmd/deployctl", none),
    ("cat staging.json", "ch03/s5-catstaging.txt"),
    ("./deployctl -config staging.json deploy -timeout 2s v1.4.2", "ch03/s5-timeout.txt"),
    ("echo $?", "ch03/s5-timeout.code"),
  )
  The headline comes from the cause, the detail line from `targetError`, and
  75 tells the pipeline that running the step again may succeed. Now
  interrupt a run one second in, as #kbd("Ctrl-C") would, and then the same
  with `SIGTERM`, as Kubernetes would:
  #session(
    ("./deployctl -config staging.json deploy v1.4.2 & sleep 1; kill -INT $!; wait $!", "ch03/s5-interrupt.txt"),
    ("echo $?", "ch03/s5-interrupt.code"),
    ("./deployctl -config staging.json deploy v1.4.2 & sleep 1; kill -TERM $!; wait $!", "ch03/s5-term.txt"),
    ("echo $?", "ch03/s5-term.code"),
  )
  The notice names the signal, the in-flight request failed with the cause,
  `targetError` recognized it, and `Run` chose 128 + _n_. In a terminal, a
  second #kbd("Ctrl-C") during a slow shutdown kills the process at once,
  because `notifyContext` stopped catching the signal after the first.
  #troubleshoot(
    ([#ts("s5-canceled.txt")], [`targetError` tests `errors.Is(err, context.Canceled)`. `net/http` failed with the cause, so the test is false and the raw chain leaks into the report.], [Test against `context.Cause(ctx)`. See the warning above.]),
    ([#ts("s5-nowrap.txt")], [The deadline's cause doesn't wrap `context.DeadlineExceeded`: `CodeOf` sees no timeout, and `rolloutError` mistakes the deadline for a signal.], [Set `Err: context.DeadlineExceeded` on the cause.]),
    ([#ts("s5-lostcancel.txt")], [The cancel function is discarded, so the timer and the context live until the deadline. `go vet` catches it.], [`ctx, cancel := ...`, then `defer cancel()`.]),
    ([#ts("s5-unbuffered.txt")], [An unbuffered signal channel: a signal that arrives while nobody is receiving is dropped.], [`make(chan os.Signal, 1)`.]),
  )
]

#step(6, 8, "Messages for people, records for operators", label: <sec-err-step-messages>)

The terminal report is now written for people. Two audiences from
@fig-err-audiences are still missing: programs that want to parse the
report, and operators who need the whole chain, which the report no longer
shows. This step adds JSON output and an operator log, and makes sure the
token can't leak into either.

=== Rules for messages <sec-err-messages>

The reports so far follow a handful of rules. They are worth writing down,
because every team reinvents them after enough support tickets.

#table(
  columns: (1fr, 1fr),
  table.header([Before], [After]),
  [`Error: rpc error: code = Unauthenticated desc = token expired`], [`the deploy API rejected your token (HTTP 401)` with a hint: export a fresh `DEPLOYCTL_TOKEN`],
  [`open deployctl.json: no such file or directory`], [`config file deployctl.json not found` with a hint: run `deployctl init`, or pass `-config FILE`],
  [`context deadline exceeded`], [`deploy did not finish within 2s`, plus which targets were still running],
  [`failed to deploy: error: 2 errors occurred`], [`deploy of v1.4.2 failed on 2 of 4 targets`, one line per target with its reason],
  [A 60-line goroutine dump], [`internal error: ...`, `this is a bug in deployctl`, the path to a crash report, and where to file it (step 7)],
)

The rules behind the right-hand column:

- *Say what happened in the user's terms.* Name the thing they control (the
  token, the config file, the version) and leave transport details to the
  log.
- *Say what to do next.* A hint is a command or a concrete action. If you
  can't write one, the error is probably not specific enough yet.
- *Give stable handles.* An error ID such as `DPL-AUTH` survives rewording,
  translation and screenshots, and it is what people paste into search. A
  docs link moves the long explanation out of the terminal. A request ID
  connects the user's failure to the server's logs.
- *Report once, at the end, on stderr.* Progress lines and results go to
  stdout, where they can be piped. The single error report goes last to
  stderr, so it is the last thing on the screen.
- *Don't blame or shout.* No "FATAL", no "invalid input!" for a typo. The
  user is a colleague trying to ship something.

=== A record for operators

People need a sentence; operators need the whole chain, structured. `Run`
will log one record per failure with `log/slog`.

#goconcept(title: [`log/slog`])[
  `log/slog` (Go 1.21) writes _structured_ log records: a message plus typed
  key-value attributes, rather than one formatted string. A `*slog.Logger`
  sends records to a `Handler`, which decides the format:
  `slog.NewJSONHandler(w, opts)` writes one JSON object per line,
  `slog.NewTextHandler` writes `key=value` pairs, and `slog.DiscardHandler`
  (Go 1.24) drops everything. `log.Info("api call", "path", p)` takes
  alternating keys and values; `go vet` checks that they pair up.
  `LogAttrs` with `slog.Int`, `slog.String` and `slog.Any` is the typed,
  allocation-free form. Each record has a level (`Debug`, `Info`, `Warn`,
  `Error`), and a handler's `Level` option filters below it. The `Context`
  variants, such as `DebugContext`, pass a context to the handler, which can
  read request-scoped values from it. A type with a
  `LogValue() slog.Value` method decides how it is logged, which this step
  uses to keep a token out of the log.
]

`clierr.Chain` lists the dynamic types in an error's tree, walking it in the
same order as `errors.Is`, like the lab's `walk`. Add `fmt` and `log/slog`
to `error.go`'s imports, and `Chain` at the end:

#src("workbook/ch03/step6/pkg/clierr/error.go", region: "imports")
#src("workbook/ch03/step6/pkg/clierr/error.go", region: "chain")

`Program` gains two fields a run function sets once it has parsed its
flags, `JSON` and `Logger`, and a hook this section explains in a moment.
Replace `program.go`'s imports, `Program`, `Run` and `report`:

#src("workbook/ch03/step6/pkg/clierr/program.go", region: "imports")
#src("workbook/ch03/step6/pkg/clierr/program.go", region: "program")
#src("workbook/ch03/step6/pkg/clierr/program.go", region: "cleanup")
#src("workbook/ch03/step6/pkg/clierr/program.go", region: "run")
#src("workbook/ch03/step6/pkg/clierr/program.go", region: "report")

The record is written by `log`, with typed attributes rather than values
formatted into the message: `exit_code` as an integer, `error_id`, the full
`error` string with every layer of context, `ctx_cause` when the context
was cancelled, and `chain`. Use the same attribute keys in every tool, so
one log query finds failures from all of them:

#src("workbook/ch03/step6/pkg/clierr/program.go", region: "log")
#src("workbook/ch03/step6/pkg/clierr/program.go", region: "logger")

#fig(placement: auto, caption: [The partial-failure error from `deployctl` as a tree. People see the accented `*clierr.Error` messages; `CodeOf` and the operator log read the whole tree.])[
  #diagram(
    spacing: (40pt, 9pt),
    dnode((0.5, 0), [`*clierr.Error` · `DPL-PARTIAL`\ "deploy of v1.4.2 failed on 2 of 4 targets"], kind: "accent"),
    dnode((0.5, 1), [`*errors.joinError`], kind: "muted"),
    dnode((0, 2), [`*clierr.Error`\ "sa-east-1: deploy already in progress …"], kind: "accent"),
    dnode((1, 2), [`*clierr.Error`\ "eu-west-1: health check failing …"], kind: "accent"),
    dnode((1, 3), [`*main.RetryError` · 3 attempts], kind: "muted"),
    dnode((0, 3), [`*main.APIError` · 409\ request `req-…`], kind: "default"),
    dnode((1, 4), [`*main.APIError` · 503\ request `req-…`], kind: "default"),
    dedge((0.5, 0), (0.5, 1), "-|>"),
    dedge((0.5, 1), (0, 2), "-|>"),
    dedge((0.5, 1), (1, 2), "-|>"),
    dedge((0, 2), (0, 3), "-|>"),
    dedge((1, 2), (1, 3), "-|>"),
    dedge((1, 3), (1, 4), "-|>"),
  )
] <fig-err-tree>

@fig-err-tree shows the tree `chain` will flatten for a partial rollout.
It answers questions that the message can't: whether a failure came through
the retry loop (`*main.RetryError`), how many layers it crossed, and which
layer produced it. The `*clierr.Error` at the top of the tree is the one
`UserMessage` picks, so the headline people see and the record operators
search describe the same failure, from the same value.

=== A bug the captures found

The first version of this step opened the `-log` file in `run` and closed it
with `defer`. The log file had every debug record and never the failure
itself. `run` returned its error, the deferred `Close` ran, and only then did
`Run` write the "command failed" record, into a closed file, with the write
error ignored. Anything the report depends on must outlive the run function.
That is what `Cleanup` above is for: like `testing.T.Cleanup`, it registers
a function that runs after the report, last registered first. `Run`
schedules `runCleanups` with `defer`, so it runs even if the report itself
fails. The troubleshooting table shows the failing test if you use `defer`
instead.

=== JSON for programs

With `-o json`, the per-target results on stdout become JSON lines and the
error report on stderr becomes one JSON object with the same fields people
see. A wrapper script can then branch on `id` instead of parsing English.
The report gets JSON tags, and `print` a JSON branch:

#src("workbook/ch03/step6/pkg/clierr/program.go", region: "reportstruct")
#src("workbook/ch03/step6/pkg/clierr/program.go", region: "print")
#src("workbook/ch03/step6/pkg/clierr/program.go", region: "stderr")

Text or JSON, the report still goes out in one `Write` call, so it can't
interleave with anything else writing to stderr.

=== Secrets don't belong in errors

Errors travel further than any other data in a program: into logs, error
trackers, CI logs that whole organisations can read, and chat. A token that
gets into an error message has been published. The usual leaks are URLs
with credentials in the query string, request dumps with an
`Authorization` header, and `%+v` of a config struct.

The standard library helps a little. `net/http` replaces the password in
`user:password@host` URLs with `***` in the errors its client returns, and
`url.URL.Redacted` masks it (as `xxxxx`) for your own messages. Neither
knows about `?token=` query parameters or headers. The more reliable fix is
to make the secret refuse to print. Add it to the end of `error.go`:

#src("workbook/ch03/step6/pkg/clierr/error.go", region: "secret")

Each method is an interface some package looks for. `fmt` uses `Format` for
every verb when a type has it, including `%#v` and `%x`, which bypass
`String`; `slog` uses `LogValue`; `encoding/json` uses `MarshalText` for a
string-like value. Code that needs the real value writes `string(tok)`,
which is easy to search for in review.

#warning(title: [Redaction is a backstop, not a strategy])[
  `Secret` protects the paths it knows about. It can't stop
  `string(tok)` being concatenated into a URL, or a panic value that
  contains a token ending up in a crash report. Keep secrets out of error
  construction entirely: say "the token in DEPLOYCTL_TOKEN was rejected",
  never the token. Error trackers and log pipelines should scrub known
  patterns as a second line of defence, and a leaked token is rotated, not
  deleted from the log.
]

=== `deployctl` gets `-o` and `-log`

The client holds its token as a `clierr.Secret` and logs every call at
debug level, token included. That is the mistake `Secret` exists to
survive, made on purpose:

#src("workbook/ch03/step6/cmd/deployctl/client.go", region: "imports")
#src("workbook/ch03/step6/cmd/deployctl/client.go", region: "client")
#src("workbook/ch03/step6/cmd/deployctl/client.go", region: "send")
#src("workbook/ch03/step6/cmd/deployctl/client.go", region: "deploycall")

`main.go` gets the two global flags. `run` now receives the `Program`, so it
can tell it how to report once it knows: `p.JSON` for `-o json`, `p.Logger`
for `-log`, and `p.Cleanup` to close the log file after the report:

#src("workbook/ch03/step6/cmd/deployctl/main.go", region: "head")
#src("workbook/ch03/step6/cmd/deployctl/main.go", region: "main")
#src("workbook/ch03/step6/cmd/deployctl/main.go", region: "globals")
#src("workbook/ch03/step6/cmd/deployctl/main.go", region: "run")
#src("workbook/ch03/step6/cmd/deployctl/main.go", region: "usage")
#src("workbook/ch03/step6/cmd/deployctl/main.go", region: "openlog")

This works because `Run` reads `JSON` and `Logger` only after the run
function returns. The log is JSON lines appended to a file, which is the
usual arrangement for a CLI: people read the terminal, CI keeps the log file
as an artifact. `deploy.go` passes the logger to the client and prints JSON
results when asked:

#src("workbook/ch03/step6/cmd/deployctl/deploy.go", region: "imports")
#src("workbook/ch03/step6/cmd/deployctl/deploy.go", region: "deploy")
#src("workbook/ch03/step6/cmd/deployctl/deploy.go", region: "rollout")
#src("workbook/ch03/step6/cmd/deployctl/deploy.go", region: "print")

=== Tests

`clierr_test.go` gets a second golden case: `TestReportGolden` gains a
`partial.json` row and sets `p.JSON` from it, so one test pins both formats:

#src("workbook/ch03/step6/pkg/clierr/clierr_test.go", region: "golden")

Then a test of the operator record, and a test that pins every way `Secret`
could leak, including a `Secret` inside `fmt.Errorf` and inside a
JSON-encoded struct. They need three more imports:

#src("workbook/ch03/step6/pkg/clierr/clierr_test.go", region: "imports")
#src("workbook/ch03/step6/pkg/clierr/clierr_test.go", region: "logrecord")
#src("workbook/ch03/step6/pkg/clierr/clierr_test.go", region: "secret")

The command's test helper now goes through `Program.Run`, as `main` does, so
cleanups registered by `run` happen in tests too:

#src("workbook/ch03/step6/cmd/deployctl/run_test.go", region: "imports")
#src("workbook/ch03/step6/cmd/deployctl/run_test.go", region: "helpers")
#src("workbook/ch03/step6/cmd/deployctl/run_test.go", region: "step6")

#needspace(12em)
#checkpoint(step: 6, of: 8, title: [Messages for people, records for operators])[
  #output("ch03/s6-tree.txt", cmd: "find . -name '*.go' | sort")
  Write the new golden file, read it, then run everything:
  #session(
    ("go test ./pkg/clierr -update", "ch03/s6-update.txt"),
    ("cat pkg/clierr/testdata/partial.json.golden", "ch03/s6-golden.txt"),
  )
  #output("ch03/s6-test.txt", cmd: "go vet ./... && go test ./...")
  Restart the fake API and rebuild. With `-o json`, stdout is JSON lines:
  #session(
    ("go build ./cmd/deployctl", none),
    ("./deployctl -config prod.json -o json deploy v1.4.2 2>/dev/null", "ch03/s6-jsonout.txt"),
  )
  and stderr is one JSON object:
  #output("ch03/s6-json.txt", cmd: "./deployctl -config prod.json -o json deploy v1.4.2 2>&1 >/dev/null | jq .error")
  The redirection order matters: `2>&1 >/dev/null` points stderr at the pipe
  first, then discards stdout. Note also what `$?` would report for that
  line: `jq`'s status, 0, unless `pipefail` is set. Now write a log file and
  look inside. The debug records show the token as `[REDACTED]`:
  #session(
    ("./deployctl -config prod.json -log deploy.log deploy v1.4.2 >/dev/null 2>&1", none),
    ("jq -c 'select(.level == \"DEBUG\") | {msg, method, path, token}' deploy.log | head -n 3", "ch03/s6-logdebug.txt"),
  )
  The failure itself is one record. Its `chain` is the tree in
  @fig-err-tree, flattened in the order `errors.Is` walks it:
  #output("ch03/s6-logerror.txt", cmd: "jq 'select(.level == \"ERROR\") | {msg, exit_code, error_id, chain}' deploy.log")
  #troubleshoot(
    ([#ts("s6-defer.txt")], [`run` closes the log file with `defer`, before `Run` writes the failure record into it.], [`p.Cleanup(closeLog)`. See "A bug the captures found".]),
    ([#ts("s6-leak.txt")], [`Secret` has no `Format` method: `String` covers `%v` and `%s`, but `%x` and `%#v` print the raw bytes.], [Implement `Format`; it covers every verb.]),
    ([#ts("s6-slogkv.txt")], [A key without a value in a `slog` call. The record would get a `!BADKEY` attribute.], [Pass `"token", c.Token`. `go vet` checks the pairs.]),
  )
]
