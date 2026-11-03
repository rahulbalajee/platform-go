#import "../template/book.typ": *

#chapter(3, "Errors, Exit Codes, and Failure as a Feature", label: <ch-errors>,
  abstract: [
    A platform tool spends most of its life succeeding quietly. People
    remember how it fails: whether the message says what to do next, whether
    the pipeline can tell an expired token from a flaky region, whether a bug
    leaves a report behind or a wall of goroutines. This chapter treats
    failure as part of a tool's interface and builds one error layer that
    every command-line tool in the book shares.
  ],
  learn: (
    [How `%w`, `errors.Is`, `errors.As` and Go 1.26's `errors.AsType` walk error chains and trees],
    [Sentinel, typed, opaque and behavioural errors, and how retry decisions use them],
    [Context errors and causes, and a `net/http` detail that breaks `errors.Is(err, context.Canceled)`],
    [Exit codes as an API: conventions, shells, `pipefail`, CI systems and Kubernetes Jobs],
    [Messages for people versus records for operators: hints, error IDs, request IDs, redaction],
    [Where panics belong, where to recover them, and how to turn a crash into a bug report],
    [Testing error paths with `errors.Is`, golden files and the real binary],
  ),
  build: [
    *`pkg/clierr`*, the error and exit-code layer: a documented exit-code
    contract, errors that carry a message, hint and docs link apart from the
    cause chain, and `Run`/`Main`, which report once, log with `log/slog`,
    honour signal causes, and turn panics into crash reports.

    #v(4pt)
    *`deployctl`*, a deploy CLI that fails in every way a real one does: a
    bad flag, a missing config file, a rejected token, a partial rollout, a
    timeout, #kbd("Ctrl-C"), and a genuine bug.
  ],
)

== Failure is part of the interface <sec-err-interface>

It is 02:10 and the release pipeline is red. The deploy step's log ends with
two lines:

#code(file: "ci.log")[```
deploy: Post "https://deploy.internal/v1/deploy": context deadline exceeded
Error: Process completed with exit code 1.
```]

The engineer on call has three questions, and the output answers none of
them. Did anything get deployed? Is it safe to re-run the job? Is the deploy
API slow, is the token expired, or is the tool broken? The pipeline has the
same questions and even less to go on. It can retry the step, fail the run,
or page someone, and the only input it has is the number 1. The same tool
exits 1 for a typo in a flag and for a rejected token. When it panics, Go
exits with 2, which this pipeline treats the same way.

A tool's failure behaviour is an interface with four consumers, and each one
needs something different from the same event:

- The *person at the terminal* needs a sentence in their own terms and the
  next step: your token was rejected, export a fresh one.
- The *script or CI system* that ran the tool needs a stable exit code it can
  branch on, and machine-readable detail if it wants more.
- The *operator* debugging the tool, or the API behind it, needs the full
  cause chain and request IDs in a log they can search.
- The *maintainer* fixing a bug needs a stack trace and the exact build that
  produced it, as a file the user can attach to an issue. The user should
  not get 80 lines of goroutine dump instead of an explanation.

@fig-err-audiences shows how `deployctl`, the CLI built in this chapter,
serves all four from the single `error` its `run` function returns.

#fig(caption: [One failure, four audiences. The run function returns one error; `clierr` decides the exit code and writes each audience its own view of it, exactly once.])[
  #diagram(
    spacing: (26pt, 10pt),
    dnode((0, 1.5), [`run` returns\ one `error`], kind: "dark"),
    dnode((1, 1.5), [`clierr.Program.Run`\ `CodeOf` · report once], kind: "accent"),
    dnode((2, 0), [*person*: stderr\ message · hint · docs link], kind: "default"),
    dnode((2, 1), [*script / CI*: exit status\ plus JSON with `-o json`], kind: "default"),
    dnode((2, 2), [*operator*: `slog` record\ cause chain · types · IDs], kind: "default"),
    dnode((2, 3), [*maintainer*: crash file\ build info · stack], kind: "warn"),
    dedge((0, 1.5), (1, 1.5), "-|>"),
    dedge((1, 1.5), (2, 0), "-|>"),
    dedge((1, 1.5), (2, 1), "-|>"),
    dedge((1, 1.5), (2, 2), "-|>"),
    dedge((1, 1.5), (2, 3), "--|>", label: text(size: 6.5pt)[panics only], label-side: right),
  )
] <fig-err-audiences>

=== Errors are values

Go returns errors as ordinary values next to results instead of throwing
exceptions that unwind the stack. An error is anything with an
`Error() string` method. It can carry fields, wrap another error, sit in a
slice, be joined with others, and be inspected by code that has no idea
where it came from. Rob Pike's 2015 post "Errors are values" makes the point
that you can program with errors like any other value. Most of this chapter
does that: it builds error values with enough structure for each audience to
get what it needs.

The flip side is that the language doesn't make you do anything useful with
them. Platform tools fail their users in the same four ways again and again:

#code(file: "dont-ship.go", caption: "four habits that make failures useless")[```go
// 1. Swallowed: the deploy "succeeds" with a region missing.
if err := deploy(ctx, target); err != nil {
	log.Printf("deploy %s: %v", target, err)
}

// 2. Log and return: one failure, reported at every layer it crosses.
if err != nil {
	log.Printf("load config: %v", err)
	return err
}

// 3. Exit from deep inside: no defers, no cleanup, no summary.
if err != nil {
	log.Fatalf("config: %v", err) // os.Exit(1)
}

// 4. One exit code for every kind of failure.
if err := run(); err != nil {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
```]

The swallowed error turns a partial failure into a reported success, and the
pipeline promotes a release that is missing from one region. Log-and-return
writes the same failure once per layer, so the log shows four errors for one
problem and the outermost copy usually lacks the detail the innermost one
had. `log.Fatal` calls `os.Exit`, which runs no deferred functions: lock files
stay locked, temporary credentials stay on disk, and the summary the user
needed never prints. A single exit code throws away the one piece of
structured information every caller is guaranteed to receive.

The rules that replace these habits fit in three sentences. Handle an error
or return it, never both. Add the context you have when you return it.
Decide what the user sees, and what the process exits with, in exactly one
place at the top of the program. The rest of the chapter is about doing that
well.

== Wrapping and inspecting error chains <sec-err-chains>

`fmt.Errorf` with the `%w` verb returns an error whose message includes the
original and whose `Unwrap() error` method returns it. Each layer adds what
it knows, and the message reads from the outside in, like a sentence, as the
first line of the output below shows. The `%v` verb produces the same text with no `Unwrap` method, which cuts the
chain. Both behaviours are useful, and the difference is invisible in the
message:

#src("examples/ch03/chain/main.go", region: "wrap")

#output("ch03/chain-wrap.txt", cmd: "go run ./examples/ch03/chain wrap")

`errors.Is(err, target)` walks the chain and reports whether any error in it
equals `target`, or has an `Is(error) bool` method that says it matches. The
second rule is why `errors.Is(wrapped, fs.ErrNotExist)` is true even though
the innermost error is `syscall.ENOENT`: `syscall.Errno` has an `Is` method
that maps `ENOENT` to `fs.ErrNotExist`, so code can test for "not found"
without caring which operating system produced it. Write your own `Is`
methods the same way: compare shallowly and never call `Unwrap` inside them,
because `errors.Is` already does the walking.

`errors.As` finds the first error in the chain that can be assigned to a
target variable, and sets the variable. It wants a pointer to a variable of
the type you are looking for, and that is easy to get wrong: a non-pointer
target, or a pointer to a type that doesn't implement `error`, panics at run
time. `go vet` catches the common cases with its `errorsas` check.

#newingo("1.26", title: [`errors.AsType`])[
  `func AsType[E error](err error) (E, bool)` is a generic `As`. It returns
  the match instead of filling in a variable, so the result can be scoped to
  an `if`, a wrong type is a compile error rather than a run-time panic, and
  there is no reflection. Use it in new code. The `modernize` analyzer (in
  `go fix` and `golangci-lint`) rewrites `errors.As` calls for you, which is
  why the listing above carries a `nolint` comment. Interface types work as
  long as they embed `error`, because of the constraint on `E`:
  `clierr.CodeOf` later uses `AsType[timeouter]` with
  `type timeouter interface { error; Timeout() bool }`.
]

=== Trees: `errors.Join` and multiple `%w`

Go 1.20 turned chains into trees. `errors.Join(errs...)` returns an error
that wraps all its non-nil arguments (and `nil` if they are all `nil`), and
`fmt.Errorf` accepts several `%w` verbs in one format string. Both produce an
error with an `Unwrap() []error` method instead of `Unwrap() error`.
`errors.Is` and `errors.As` traverse the tree depth first, visiting an error
before its children and the children in order, and stop at the first match.

#src("examples/ch03/chain/main.go", region: "tree")

#output("ch03/chain-tree.txt", cmd: "go run ./examples/ch03/chain tree")

The indentation shows the order `errors.Is` visits the nodes. Three
consequences of the tree shape catch people out:

- `errors.Unwrap` only calls `Unwrap() error`, so it returns `nil` for a
  joined error. A hand-written `for err != nil { err = errors.Unwrap(err) }`
  loop silently stops at the first `Join` and misses everything below it.
- `AsType` returns the _first_ match in depth-first order. When a tree holds
  several errors of the type you want, as `deployctl`'s partial failure does
  later in the chapter, you get the leftmost one. To see them all, walk the
  tree yourself.
- A joined error's message is its children's messages separated by
  newlines. That works in a log and looks broken in a one-line terminal
  message, which is why `clierr` lists the children of a joined cause on
  separate lines.

Walking the tree by hand takes a type switch over the two `Unwrap` shapes.
This is `walk` from the example; `clierr.Chain`, which records the error
types for operator logs, has the same structure:

#src("examples/ch03/chain/main.go", region: "walk")

#newingo("1.27", title: [`go vet` flags wrapped pointers that defeat `errors.As`])[
  The `printf` analyzer now reports `fmt.Errorf("...: %w", p)` when `p` has
  type `*E` and `E` itself implements `error`. Wrapping the pointer means
  `AsType[E]` and `errors.Is` comparisons against `E` values never match:
  #src("examples/ch03/testdata/ptrwrap.go", region: "ptrwrap")
  #session(
    ("go vet examples/ch03/testdata/ptrwrap.go 2>&1 | fold -s -w 80", "ch03/vet-ptrwrap.txt"),
    ("go run examples/ch03/testdata/ptrwrap.go", "ch03/run-ptrwrap.txt"),
  )
  The file sits under `testdata`, which `./...` patterns skip, so the rest
  of the repository still passes `go vet`.
]

=== What to put in the message

Each layer should add the context its caller doesn't have, usually an
operation and a noun: `load config`, `deploy eu-west-1`, `read token file`.
It should not repeat what the wrapped error already says, and it should not
add "failed to" or "error:", because every layer of the chain failed and the
chain is printed on an error path. Keep messages lowercase with no trailing
punctuation, since they get embedded in other messages. Then read the full
chain aloud. `deploy eu-west-1: post /v1/deploy: 503` is a sentence.
`error: failed to deploy: failed to post: 503` is noise.

#warning(title: [Wrapping makes the cause part of your API])[
  Once a package returns `fmt.Errorf("query: %w", err)` with a
  `*pgconn.PgError` underneath, callers start writing
  `errors.AsType[*pgconn.PgError]`, and you can no longer change database
  drivers without breaking them. Wrap with `%w` when you mean callers to
  inspect the cause: your own sentinels and types, or standard ones such as
  `fs.ErrNotExist` and `context.DeadlineExceeded`. At package boundaries,
  use `%v` for implementation details you want to keep the freedom to
  change. The Go blog's 2019 post on Go 1.13 errors makes the same argument.
]

== Sentinel, typed, opaque and behavioural errors <sec-err-kinds>

A caller can do four things with an error: compare it to a known value,
extract a typed error and read its fields, ask it about a behaviour, or just
print it. Each kind of error supports some of those, and each couples caller
and callee in a different way.

#table(
  columns: (auto, 1fr, 1fr, 1fr),
  table.header([Kind], [Example], [Caller checks with], [Costs]),
  [Sentinel], [`io.EOF`, `fs.ErrNotExist`, `sql.ErrNoRows`], [`errors.Is(err, fs.ErrNotExist)`], [Exported forever; carries no data beyond its identity],
  [Typed], [`*fs.PathError`, `*url.Error`, `deployctl`'s `*APIError`], [`errors.AsType[*APIError](err)`, then read fields], [The type and its fields are API; renaming a field breaks callers],
  [Behavioural], [`net.Error`'s `Timeout()`, `APIError.Temporary()`], [`AsType` with an interface that embeds `error`], [Loose coupling, but the meaning of the method must be precise],
  [Opaque], [`errors.New("...")` inline, `fmt.Errorf` with `%v`], [Nothing but printing], [None: maximum freedom for the callee],
)

Start opaque. Promote an error to a sentinel or a type only when a caller has
a real decision to make with it, such as "retry or not", "exit 77 or 1",
"create the file or report it". The decision is the reason for the API.

Behavioural checks are underused. Code that asks "is this a timeout?" should
not need to know whether the timeout came from `net`, `os`, `context`, or an
SDK. Asking for `interface{ Timeout() bool }` works for all of them, which is
how `clierr.CodeOf` maps every kind of timeout to one exit code. Be precise
about the method's meaning, though. `net.Error` once had a `Temporary()`
method, and Go 1.18 deprecated it with the note "Temporary errors are not
well-defined", because callers and implementers disagreed about what it
meant. A behaviour is only useful if everyone agrees what it promises.

`deployctl`'s API client shows the pieces together. `APIError` is a typed
error that keeps what the API said and the request ID, and its `Temporary`
method is narrow and documented: 429 or 5xx.

#src("examples/ch03/deployctl/client.go", region: "apierror")

The client's request loop makes the retry decision once, at the source, from
that behaviour: a transport error or a temporary `*APIError` is returned as
is, and anything else is wrapped in Chapter 4's `retry.Permanent` before it
reaches the retry policy. `retry.Permanent` is transparent: its message is the wrapped error's
message, and `Unwrap` exposes the original, so callers above see an
`*APIError` and never know a retry policy was involved. When the attempts
run out, `retry.Policy.Do` returns an `*retry.ExhaustedError` that also
wraps the last attempt's error. The upshot is that every layer can add its
own meaning (permanent, exhausted after three attempts) without hiding the
original from `errors.Is` and `AsType`. One test case in `pkg/clierr` pins
this: an `ExhaustedError` wrapping a network timeout still maps to the
"temporary failure" exit code.

== Context errors and their causes <sec-err-context>

`ctx.Err()` returns one of two values once a context is done.
`context.Canceled` means someone called `cancel`; `context.DeadlineExceeded`
means a timer fired. `DeadlineExceeded` also has `Timeout()` and
`Temporary()` methods that return `true`, so behavioural timeout checks catch
it alongside network timeouts. Neither value says _who_ cancelled or _why_,
and for a tool that is the important part. Was it #kbd("Ctrl-C")? The
overall `-timeout`? One slow attempt out of three?

Chapter 4 introduced the answer: `context.WithCancelCause` (Go 1.20) and
`WithTimeoutCause` and `WithDeadlineCause` (Go 1.21) record an error as the
cause, and `context.Cause(ctx)` returns it. `sweep` gives every attempt a
`WithTimeoutCause` context whose cause is a package-level
`errAttemptTimeout`, which is how its report can say "attempt timed out after
5s" for a slow target and "cancelled" for a run the user interrupted.

`deployctl` goes one step further. The cause of its overall deadline is a
complete, user-facing `*clierr.Error`, with an exit code, an ID and a hint:

#src("examples/ch03/deployctl/deploy.go", region: "cause")

The cause wraps `context.DeadlineExceeded`. That small detail keeps code
written for plain timeouts working: `errors.Is(err, context.DeadlineExceeded)`
is still true for an error whose chain contains this cause, and so is the
`Timeout()` check. A cause that wraps nothing silently breaks every such
check in the libraries below you.

#warning(title: [`net/http` returns the cause, not `ctx.Err()`])[
  When a request's context is cancelled, the HTTP transport fails the
  request with `context.Cause(ctx)` (look for `context.Cause` in
  `net/http/transport.go`). If the context was cancelled with a cause, the
  error from `client.Do` wraps that cause and not `context.Canceled`. Code
  like `if errors.Is(err, context.Canceled) { /* user gave up */ }` stops
  matching the moment someone upstream starts using causes, for example a
  signal handler built on `WithCancelCause`. Test against the cause itself:
  `errors.Is(err, context.Cause(ctx))`. `deployctl`'s `targetError` does
  this before it labels a target "stopped before the API answered".
]

Here is the deadline firing for real. `staging.json` lists `us-east-1`,
which the fake API deploys in 100 ms, and `ap-south-1`, which takes three
seconds:

#session(
  ("deployctl -config staging.json deploy -timeout 2s v1.4.2", "ch03/timeout.txt"),
  ("echo $?", "ch03/timeout.code"),
)

The headline comes from the cause, the detail line from `targetError`, and
the exit code 75 tells the pipeline that running the step again may succeed.

Signals work the same way. Chapter 4's `lifecycle.NotifyContext` cancels its
context with a `*lifecycle.SignalError` cause that records the signal, and
`clierr` reads it to choose between 130 for `SIGINT` and 143 for `SIGTERM`.
Since Go 1.26, the standard library's `signal.NotifyContext` also sets a
cause, but its type is unexported and its only content is a message such as
"interrupt signal received". You can print it; you can't get the signal
number back out of it, which is why `clierr` sticks with the typed cause.

== Exit codes are an API <sec-err-exit>

When a process exits, its parent receives a status. On Unix the exit code
part of that status is 8 bits wide: the parent sees `code & 0xff`, so
`os.Exit(256)` reports success. That sounds like trivia until someone writes
`os.Exit(len(failed))`:

#src("examples/ch03/exitcount/main.go", region: "exitcount")

#session(
  ("go build -trimpath -o exitcount ./examples/ch03/exitcount", none),
  ("./exitcount", "ch03/exitcount.txt"),
  ("echo $?", "ch03/exitcount.code"),
)

Two hundred and fifty-six failures, exit status 0, and the pipeline moves on.
An exit code is a small enumeration, not a count.

=== The conventions you inherit

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

=== The contract in this book

Chapter 4 committed `sweep` to four values: 0 when every check passed, 1
when some failed, 2 for usage or configuration errors, and 130 when
interrupted. `clierr` keeps those meanings and adds three codes that callers
need to make different decisions, borrowing the `sysexits.h` numbers so they
numbers so they neither collide with the shell's reserved ranges nor need inventing:

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
not retry, retry later), so they get different codes. In code, the contract
is a set of documented constants:

#src("pkg/clierr/code.go", region: "codes")

=== Shells, `set -e` and `pipefail`

Shell scripts are the most common caller of a platform tool, and they are
where exit codes get lost. `set -e` makes a script exit when a command fails,
with exceptions that surprise everyone once: it does not apply to a command
tested by `if`, `while` or `until`, to any command in an `&&` or `||` list
except the last, or to a command whose status is inverted with `!`. And by
default a pipeline's status is the status of its _last_ command:

#session(
  ("deployctl -config prod.json deploy v1.4.2 2>/dev/null | grep -c deployed; echo \"exit $?\"", "ch03/pipe-nopipefail.txt"),
  ("set -o pipefail", none),
  ("deployctl -config prod.json deploy v1.4.2 2>/dev/null | grep -c deployed; echo \"exit $?\"", "ch03/pipe-pipefail.txt"),
)

Two of four targets deployed and the rollout failed, but without `pipefail`
the pipeline exits 0 because `grep` found matches. With `pipefail`, the
status is the last non-zero status in the pipeline. Bash also keeps every
stage's status in the `PIPESTATUS` array if you need to tell them apart.

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
that timed out:

#src("examples/ch03/deployctl/job.yaml", region: "job")

#output("ch03/job-dryrun.txt", cmd: "kubectl apply --dry-run=server -f examples/ch03/deployctl/job.yaml")

The server-side dry run checks the manifest against the API server's
schema and admission chain without creating the Job, which is a cheap test
to keep in CI for every Job template a platform team ships.

At scale, the contract outlives everyone who wrote it. When 200 engineers
have wrapped a tool in scripts, pipeline templates and Job specs, renumbering
a code is a breaking change of the worst kind, because nothing fails to
compile: some job somewhere starts retrying a bad token, or stops retrying a
timeout. Document the codes in `--help` and the README, test them (as
@sec-err-testing does), never reuse a retired number, and add new ones only
when a caller needs a new decision.

== `clierr`: one failure path for every tool <sec-err-clierr>

The package has a small job. A command's run function returns an `error`.
Everything after that, the exit code, the message, the log record and the
crash report, happens in one place, the same way in every tool in the book.
The design has four parts: an error type that carries a message for people,
a function that maps errors to codes, a runner that reports once, and a
`Main` that wires in signals and exits.

=== An error with two audiences

#src("pkg/clierr/error.go", region: "error")

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
permission problem. `deployctl`'s config loader uses that for unreadable
files: the message is the same, and the code comes out as 77 for `EACCES`.

`UserMessage(err)` picks the text for a person: the `Message` of the first
`*Error` in the tree, or `err.Error()` if nobody wrote one. When an
`*Error`'s cause has an `Unwrap() []error` method, the report lists the
`UserMessage` of each child on its own line.

=== Mapping errors to codes

#src("pkg/clierr/code.go", region: "codeof")

@fig-err-codeof shows the order of the checks. A panic wins over everything,
because a bug is a bug even if the code that panicked was about to time out.
A signal wins over whatever error the interrupted work produced. An explicit
`Code` on an `*Error` wins over inference, and inference uses behaviour
(`Timeout()`) and well-known sentinels (`fs.ErrPermission`). Anything left
is a plain failure, exit 1. `flag.ErrHelp` maps to 0, because `-h` is a
request that succeeded.

#fig(placement: auto, caption: [How `CodeOf` and `Run` choose an exit code. The first matching rule wins; `Run` also checks the context's cause, so a signal decides the code even when the work returned a bare `context.Canceled`.])[
  #diagram(
    spacing: (30pt, 7pt),
    dnode((0, 0), [`nil` or `flag.ErrHelp`?], kind: "muted"),
    dnode((0, 1), [`*PanicError` in the tree?], kind: "muted"),
    dnode((0, 2), [`*SignalError` in the tree or\ as the context's cause?], kind: "muted"),
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

=== Report once, at the top

#src("pkg/clierr/program.go", region: "program")

#src("pkg/clierr/program.go", region: "run")

`Run` is where the "handle or return, never both" rule pays off. Nothing
below it prints errors or exits; everything below it returns. `Run` computes
the code, overrides it if the context was cancelled by a signal, builds a
report, logs it, prints it, and returns the code. The deferred `recover`
turns a panic on this goroutine into a `*PanicError`, which then goes
through the same `report` path, so a crash is just one more kind of failure
with its own code and its own output (@sec-err-panics).

`Run` returns the code instead of exiting, so tests can call it with a fake
`Stderr` and assert on both. `Main` adds the process-wide pieces:

#src("pkg/clierr/program.go", region: "main")

It installs Chapter 4's two-stage signal handling, runs, stops the signal
handler, and exits. `os.Exit` skips deferred functions, so everything that
must happen before exit happens explicitly before that last line. The
`fatalOutput` call is covered in @sec-err-stacks.

=== Wiring a command

Here is all of `deployctl`'s `main`:

#src("examples/ch03/deployctl/main.go", region: "main")

`run` has the signature Chapter 4 recommended for testability, with one
change: it returns an `error`, not an `int`. Choosing the code is no longer
its job. It tells the `Program` how to report (`p.JSON`, `p.Logger`) once it
has parsed the flags that decide that, which works because `Run` reads those
fields only after `run` returns.

`sweep` would adopt the package in the same way. Its `main` becomes
`p.Main(...)` around its existing `run`, the "some targets down" path returns
an `*Error` with `Code: clierr.ExitFailure`, the usage paths return
`Code: clierr.ExitUsage`, and the interrupted path needs no code at all,
because `Run` reads the signal cause from the context. All four of `sweep`'s
documented codes keep their meaning. It gains 70 for panics, and 75 for an
expired `-deadline` once its deadline cause wraps `context.DeadlineExceeded`
the way `deployctl`'s does.

=== A bug the captures found

The first version of `deployctl` opened its `-log` file in `run` and closed
it with `defer`. The log file had every debug record and never the failure
itself. `run` returned its error, the deferred `Close` ran, and only then did
`Run` write the "command failed" record, into a closed file, with the write
error ignored. Anything the report depends on must outlive the run function,
so `Program` has a `Cleanup` hook that runs after the report, in the spirit
of `testing.T.Cleanup`:

#src("pkg/clierr/program.go", region: "cleanup")

== Every failure mode, for real <sec-err-tour>

The fake deployment API in `examples/ch03/fakeapi` gives each target fixed
behaviour: `eu-west-1` answers 503 because its health check keeps failing,
`sa-east-1` answers 409 because another deploy holds the lock, `ap-south-1`
is slow, and everything else deploys in 100 ms. Every request needs a bearer
token and every response carries an `X-Request-Id`. The capture script
starts it on `127.0.0.1:8787`, exports `DEPLOYCTL_TOKEN` and runs each
command below from a directory holding `prod.json` (four targets) and
`staging.json` (two). Each block shows the combined stdout and stderr and
then the exit status.

=== A bad flag: 2

#session(
  ("deployctl -config prod.json deploy -parallel=many v1.4.2", "ch03/badflag.txt"),
  ("echo $?", "ch03/badflag.code"),
)

Two lines, and the second tells the user how to find out more. That takes
some work, because the `flag` package reports the error itself: with
`ContinueOnError`, `FlagSet.Parse` writes the message and the whole usage
text to the flag set's output before it returns the error, and then the
program reports the same error a second time. `deployctl`'s `parse` helper
sends the flag set's output to `io.Discard`, wraps a parse error in an
`*Error` with `ExitUsage` and a "run -h" hint, and on `flag.ErrHelp` prints
the usage to stdout itself. Help goes to stdout with status 0, because the user asked for it and may
pipe it into `less`. An error goes to stderr with status 2. Mixing those up
is a small thing that people notice every day.

=== A missing config file: 2

#session(
  ("deployctl deploy v1.4.2", "ch03/noconfig.txt"),
  ("echo $?", "ch03/noconfig.code"),
)

The loader in `config.go` gives every config failure the same ID and docs
link, and a hint that matches the specific failure. Missing, malformed and
incomplete files are all exit 2. An unreadable file
gets `Code: 0`, so `CodeOf` infers 77 from `fs.ErrPermission` and keeps the
same message. Validation collects every problem with `errors.Join` rather
than stopping at the first, for the reason Chapter 4 gave: nobody wants to
fix a config file one error per run.

=== A rejected token: 77

#session(
  ("DEPLOYCTL_TOKEN=expired deployctl -config prod.json deploy v1.4.2", "ch03/auth.txt"),
  ("echo $?", "ch03/auth.code"),
)

`deployctl` calls `GET /v1/whoami` before it touches a single target and
turns a 401 or 403 into an `*Error` with code 77. The preflight call is a
design decision as much as an error-handling one.
Without it, a bad token would produce the same 401 once per target, in the
middle of a rollout, and the user would get a "partial failure" of 40
identical lines. Failing up front with one clear message also makes 77 a
reliable signal: the pipeline can stop retrying, and nothing was changed.
The hint carries the request ID, which is what the API's owners need to
find this request among millions in their logs.

=== A partial rollout: 1

#session(
  ("deployctl -config prod.json deploy v1.4.2", "ch03/partial.txt"),
  ("echo $?", "ch03/partial.code"),
)

Two targets deployed, two failed, and each failure says why in the API's own
words. The rollout runs on Chapter 4's `conc.Stream`, turns each failed
target's error into a one-line `*Error` with the target's name, and builds
a single error at the end:

#src("examples/ch03/deployctl/deploy.go", region: "outcome")

Two choices here need defending. First, a partial failure is exit 1 even
if one of the failures was a timeout: a pipeline that retries the whole
step on 75 would redo the targets that already succeeded and run into the
409 again. When the context itself ended, the cause becomes the
headline instead, because then the whole rollout was cut short rather than
two targets failing. Second, the hint is a command the user can run. "Fix
the failing targets" alone is advice; `-only sa-east-1,eu-west-1` is the next
action.

Each worker calls `clierr.Safe`, because `Run`'s `recover` cannot see a
panic on a worker goroutine (@sec-err-panics). A bug in one target's code
path becomes that target's error, and the `*PanicError` in the tree still
makes the whole run exit 70.

=== Interrupted: 130

The last run sends `SIGINT`, the signal #kbd("Ctrl-C") sends, one second in,
while `ap-south-1` is still deploying. `lifecycle` prints its one-line
notice and cancels the context with a `*SignalError` cause. The in-flight
request fails with that cause (the `net/http` behaviour from
@sec-err-context), `targetError` recognizes it, `rolloutError` writes the
"interrupted" headline, and `Run` sees the signal cause and exits 130:

#session(
  ("deployctl -config staging.json deploy v1.4.2 & sleep 1; kill -INT $!; wait $!", "ch03/interrupt.txt"),
  ("echo $?", "ch03/interrupt.code"),
)

Sending `SIGTERM` instead, as Kubernetes does when it deletes a pod, gives
the same report and exit status 143.

== Messages for people, records for operators <sec-err-messages>

The terminal output above follows a handful of rules. They are worth writing
down, because every team reinvents them after enough support tickets.

#table(
  columns: (1fr, 1fr),
  table.header([Before], [After]),
  [`Error: rpc error: code = Unauthenticated desc = token expired`], [`the deploy API rejected your token (HTTP 401)` with a hint: export a fresh `DEPLOYCTL_TOKEN`],
  [`open deployctl.json: no such file or directory`], [`config file deployctl.json not found` with a hint: run `deployctl init`, or pass `-config FILE`],
  [`context deadline exceeded`], [`deploy did not finish within 2s`, plus which targets were still running],
  [`failed to deploy: error: 2 errors occurred`], [`deploy of v1.4.2 failed on 2 of 4 targets`, one line per target with its reason],
  [A 60-line goroutine dump], [`internal error: ...`, `this is a bug in deployctl`, the path to a crash report, and where to file it],
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
logs one record per failure with `slog.Logger.LogAttrs` at error level. The
attributes are typed rather than formatted into the message: `exit_code` as
an integer, `error_id`, the full `error` string with every layer of
context, `ctx_cause` when the context was cancelled, and `chain`, the
dynamic types in the error tree. `clierr.Chain` builds that list by walking
the tree in the same order as `errors.Is` and recording `%T` for each node.

`deployctl -log FILE` sends that log, plus debug records for every API
call, to a JSON file, which is the usual arrangement for a CLI: people read
the terminal, CI keeps the log file as an artifact.

#session(
  ("deployctl -config prod.json -log deploy.log deploy v1.4.2 >/dev/null 2>&1", none),
  ("jq -c 'select(.level == \"DEBUG\") | {msg, method, path, token}' deploy.log | head -n 3", "ch03/log-debug.txt"),
)

The debug records show the token as `[REDACTED]`; the end of this section
explains why. The failure itself is one record:

#output("ch03/log-error.txt", cmd: "jq 'select(.level == \"ERROR\") | {msg, exit_code, error_id, chain}' deploy.log")

The `chain` field is the tree from @fig-err-tree, flattened in the order
`errors.Is` walks it. It answers questions that the message can't: whether
a failure came through the retry policy (`*retry.ExhaustedError`), whether
it was ever classified as permanent, and which layer produced it. Use
consistent attribute keys (`error`, `error_id`, `exit_code`) across every
tool, so one log query finds failures from all of them.

=== JSON for programs

With `-o json`, the per-target results on stdout become JSON lines and the
error report on stderr becomes one JSON object with the same fields people
see. A wrapper script can then branch on `id` instead of parsing English:

#output("ch03/json.txt", cmd: "deployctl -config prod.json -o json deploy v1.4.2 2>&1 >/dev/null | jq .error")

The redirection order matters: `2>&1 >/dev/null` points stderr at the pipe
first, then discards stdout. Note also what `$?` would report for that line:
`jq`'s status, 0, unless `pipefail` is set. Text or JSON, the report goes
out in a single `Write` call, so it can't interleave with anything else
writing to stderr.

#fig(placement: auto, caption: [The partial-failure error from `deployctl` as a tree. People see the accented `*clierr.Error` messages; `CodeOf` and the operator log read the whole tree.])[
  #diagram(
    spacing: (40pt, 9pt),
    dnode((0.5, 0), [`*clierr.Error` · `DPL-PARTIAL`\ "deploy of v1.4.2 failed on 2 of 4 targets"], kind: "accent"),
    dnode((0.5, 1), [`*errors.joinError`], kind: "muted"),
    dnode((0, 2), [`*clierr.Error`\ "sa-east-1: deploy already in progress …"], kind: "accent"),
    dnode((1, 2), [`*clierr.Error`\ "eu-west-1: health check failing …"], kind: "accent"),
    dnode((0, 3), [`*retry.permanentError`], kind: "muted"),
    dnode((1, 3), [`*retry.ExhaustedError` · 3 attempts], kind: "muted"),
    dnode((0, 4), [`*main.APIError` · 409\ request `req-…`], kind: "default"),
    dnode((1, 4), [`*main.APIError` · 503\ request `req-…`], kind: "default"),
    dedge((0.5, 0), (0.5, 1), "-|>"),
    dedge((0.5, 1), (0, 2), "-|>"),
    dedge((0.5, 1), (1, 2), "-|>"),
    dedge((0, 2), (0, 3), "-|>"),
    dedge((1, 2), (1, 3), "-|>"),
    dedge((0, 3), (0, 4), "-|>"),
    dedge((1, 3), (1, 4), "-|>"),
  )
] <fig-err-tree>

=== Secrets don't belong in errors

Errors travel further than any other data in a program: into logs, error
trackers, CI logs that whole organisations can read, and chat. A token that
gets into an error message has been published. The usual leaks are URLs
with credentials in the query string, request dumps with an
`Authorization` header, and `%+v` of a config struct.

The standard library helps a little. `net/http` replaces the password in
`user:password@host` URLs with `***` in the errors its client returns, and
`url.URL.Redacted` masks it (as `xxxxx`) for your own messages. Neither knows about
`?token=` query parameters or headers. The more reliable fix is to make the
secret refuse to print:

#src("pkg/clierr/error.go", region: "secret")

`deployctl` holds its token as a `clierr.Secret`, and its debug log records
the token on every call. That is the mistake this type exists to survive,
and the log above shows `[REDACTED]`. `Format` covers every `fmt` verb,
including `%#v` and `%x`; `LogValue` covers `slog`; `MarshalText` covers
JSON. `TestSecretNeverPrints` pins all of them, including a `Secret` inside
`fmt.Errorf` and inside a JSON-encoded struct.

#warning(title: [Redaction is a backstop, not a strategy])[
  `Secret` protects the paths it knows about. It can't stop
  `string(tok)` being concatenated into a URL, or a panic value that
  contains a token ending up in a crash report. Keep secrets out of error
  construction entirely: say "the token in DEPLOYCTL_TOKEN was rejected",
  never the token. Error trackers and log pipelines should scrub known
  patterns as a second line of defence, and a leaked token is rotated, not
  deleted from the log.
]

== Panics: when to crash and where to recover <sec-err-panics>

A panic is for a state the program should never be in: a nil map the code
assumed was initialised, an index past the end of a slice, an enum value
nobody wrote a case for. Those are bugs, and continuing means running on
assumptions that just proved false. `regexp.MustCompile` and `template.Must`
follow the same rule: they panic only on inputs that are constants in the
program. Anything a user or the environment can cause (a missing file, bad
input, a network failure, a permission error) is an error and goes up the
stack as a value.

=== `recover` only works on its own goroutine

`recover` stops a panic only when it is called from a deferred function on
the goroutine that is panicking. A deferred `recover` in `main` does nothing
for a panic on any other goroutine:

#src("examples/ch03/gopanic/main.go", region: "gopanic")

#session(
  ("go build -trimpath -o gopanic ./examples/ch03/gopanic", none),
  ("./gopanic", "ch03/gopanic.txt"),
  ("echo $?", "ch03/gopanic.code"),
)

Neither line in `main` prints. The panic unwinds the worker goroutine, finds
no `recover` there, and the runtime kills the process with status 2. That is
the same status the book's contract uses for a usage error, so a pipeline
can't tell "you typed a bad flag" from "the tool crashed". The
`[recovered, repanicked]` suffix is `sync.WaitGroup.Go` at work: its wrapper
recovers the panic only to panic again without calling `Done`, so that
`Wait` can't return and let `main` exit with status 0 before the crash
completes. The shorter `[recovered, repanicked]` form of the message is new
in Go 1.25; older releases printed the panic value twice.

The rule that follows: every goroutine that runs code which might panic
needs its own boundary, or a panic there takes the whole process down. That
is often what you want in a daemon (more on that below). In a CLI it means
you lose the report.

=== Recovering at boundaries

There are three boundaries in a typical platform tool.

*The top of `main`.* `clierr.Program.Run` recovers panics on the main
goroutine and turns them into `*PanicError` values.

*Goroutines you start.* `clierr.Safe` converts a panic into an error at the
point where work crosses onto another goroutine, so it can travel back to
`Run` like any other failure:

#src("pkg/clierr/panic.go", region: "safe")

The stack is captured inside the deferred function, while the panicking
frames are still on the stack. Capture it after `Safe` returns and you get a
stack trace of the code that called `Safe`, which shows nothing useful.

*Requests in a server.* `net/http` recovers panics in handlers for you, on
the theory that one bad request shouldn't take down a server handling
thousands of good ones. It logs the panic and a stack trace to the server's
`ErrorLog` and drops the connection, or resets the stream on HTTP/2. The
`httppanic` example runs a server with two handlers, `/boom`, which writes
to a nil map, and `/abort`, which panics with `http.ErrAbortHandler`, and
calls each once. Its log writer keeps the first line of each entry and
counts the rest:

#output("ch03/httppanic.txt", cmd: "go run ./examples/ch03/httppanic")

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
  second: it records the stack at recovery time and writes it to a crash
  file. For a long-running daemon, the errgroup authors' choice is usually
  the better one. Crash, let Kubernetes restart the pod with a clean heap,
  and let the crash loop alert someone, rather than keep serving with state
  that a bug just corrupted.
]

=== What a crash looks like with `clierr`

`deployctl status` has a deliberate bug, marked with a `BUG(ch03)` comment
so `go doc` lists it: it prints `r.Previous.Version` for each target without
checking that `r.Previous` is non-nil, and `ap-south-1` has only ever had
one release.

#session(
  ("deployctl -config staging.json status", "ch03/panic.txt"),
  ("echo $?", "ch03/panic.code"),
)

The user gets four lines: what happened, that it is not their fault, where
the details are, and where to send them. Exit status 70 tells the pipeline
this is a bug in the tool and not something a retry or a config change will
fix. The stack trace went to a file:

#src("pkg/clierr/program.go", region: "crash")

The file is created with `os.CreateTemp`, which matters more than it looks.
`/tmp` is shared by every user on the machine. A predictable name such as
`/tmp/deployctl-crash.txt` lets another user create a symlink there in
advance and have your process overwrite a file of their choosing. `CreateTemp`
picks a random name and opens it with `O_EXCL` and mode 0600. If even that
fails, on a read-only file system for example, the stack goes to stderr
after all, because a crash nobody can diagnose is worse than an ugly
terminal.

== Stack traces and diagnostics <sec-err-stacks>

Go errors don't carry stack traces, by design. Capturing a stack would cost
a call to `runtime.Callers` and an allocation on every error, including the many errors that are expected and handled a few
frames up: `io.EOF` at the end of every stream, `fs.ErrNotExist` when probing
for an optional file. Good wrapping gives you something better than a stack
for most failures: a _logical_ trace in the program's own vocabulary
(`deploy eu-west-1: post /v1/deploy: 503`) that survives refactoring and
reads well in a log. The once-popular `github.com/pkg/errors` package records
a stack trace in every error it creates or wraps. When Go 1.13 brought
wrapping into the standard library, it took the wrapping half of that design
and left stacks out on purpose.

Stacks earn their cost where the logical trace runs out: panics, and
internal errors that mean an invariant broke. `clierr` captures them only
for panics, with `runtime/debug.Stack`, which formats the current
goroutine's stack the way the runtime prints it in a crash. The crash report
pairs the stack with the build, read with `debug.ReadBuildInfo`:

#output("ch03/crashfile.txt", cmd: "head -n 20 /tmp/deployctl-crash-*.txt")

The capture script shortens the long hexadecimal argument values in the
trace so they fit the page; everything else is as written. The header is
what turns "it crashed" into a reproducible bug report: the module version,
the toolchain, the platform and the exact commit, including whether the
working tree had uncommitted changes. The binary was built with `-trimpath`,
which is why the frames show module paths instead of the build machine's
home directory. Release builds should always use it, for reproducibility
and so that a crash report doesn't reveal the build machine's user name.

#newingo("1.24", title: [Version stamping from version control])[
  `go build` now sets the main module's version from the VCS tag or commit,
  with a `+dirty` suffix when the working tree has uncommitted changes. That
  is the `v0.0.0-20261103092110-f4030eafc9cc+dirty` in the report above,
  read with `debug.ReadBuildInfo`. Before Go 1.24, a binary built from a
  checkout reported `(devel)` and you had to stamp a version yourself with
  `-ldflags "-X main.version=..."`. `-buildvcs=false` turns the stamping off.
]

=== The panics `recover` can't see

Some failures never reach a deferred `recover`: a panic on a goroutine
without `Safe`, concurrent map writes, running out of memory, every
goroutine blocked forever. The runtime prints its report to stderr and exits
with status 2. `runtime/debug.SetCrashOutput` (Go 1.23) names an additional
file that receives the same report. `clierr.Program.Main` opens a fresh file
in the crash directory at start-up, points the runtime at it, and deletes it
on a normal exit (the `fatalOutput` call in the `Main` listing in
@sec-err-clierr). The cost is creating and removing one empty file per run, which is
negligible next to process start-up. The benefit is that when a tool dies
in a cron job or a CI step whose stderr was truncated or discarded, the
full runtime report is still on disk. A `deployctl` test in
@sec-err-testing checks that a run which ends normally, even one that
recovered a panic, leaves no such file behind.

`GOTRACEBACK` controls how much the runtime's own report contains: `single`
(the default) shows the failing goroutine, `all` adds every goroutine the
program created, `system` adds runtime frames, and `crash` is `system` plus
a `SIGABRT` on Unix so the kernel can write a core dump. For daemons under
Kubernetes, `GOTRACEBACK=all` is a cheap setting that makes the pod's last
log lines far more useful.

== Testing error paths <sec-err-testing>

Error paths are the code that runs least often and matters most when it
does. They need the same tests as the happy path, at three levels.

=== Assert on identity, not text

A test that checks `err.Error() == "deploy: ..."` breaks whenever anyone
improves a message. Test error _identity_ with `errors.Is` and `AsType`, and
behaviour such as exit codes, in a table:

#src("pkg/clierr/clierr_test.go", region: "codeof")

The table doubles as documentation of the contract. Each row is a case
someone will one day get wrong: a joined error, an `*Error` that infers its
code, a retry wrapper around a timeout, a panic hiding next to a usage
error.

=== Golden files for what people read

Exact text matters in one place, the message a person reads, because that
_is_ the interface. Golden files keep those messages under
review without hard-coding them into test source. `TestReportGolden` runs a
partial failure through `Run` in text and JSON mode and compares stderr
byte for byte with files such as this one:

#src("pkg/clierr/testdata/partial.text.golden", lang: "text")

When a message changes on purpose, `go test ./pkg/clierr -update` rewrites
the files, and the change shows up in code review as a diff of what users
will see. Chapter 6 covers golden files and `testscript` in depth.

=== Exit codes from the real binary

The exit code is produced by the process, not by a function, so the last
level of testing builds the binary and runs it. `TestMain` builds
`deployctl` once into a temporary directory:

#src("examples/ch03/deployctl/main_test.go", region: "testmain")

`TestExitCodes` is a table of argument lists, environment overrides,
expected codes and golden stderr files, run against a real HTTP server built
from the same `fakeapi` handler the captures used:

#output("ch03/exitcodes-run.txt", cmd: "go test -count=1 -v -run TestExitCodes ./examples/ch03/deployctl")

A small helper runs each command and pulls the status out of the
`*exec.ExitError` that `cmd.Run` returns for a non-zero exit, using
`errors.AsType` like any other typed error. Its `ExitCode` method returns -1
when the process was killed by a signal rather than exiting, which a test
should treat as a failure in its own right. The partial-failure case passes
`-parallel 1`, so the targets fail in input order and the golden file is
stable. Two more tests do things a table can't. One reads stdout until
`us-east-1` has deployed, sends a real `SIGINT`, and expects 130 and an
accurate "1 of 2 targets not updated". The other runs the buggy `status`
command and checks that the crash report exists, that no stack reached
stderr, and that no `-fatal-` file was left behind.

#output("ch03/test-ch03.txt", cmd: "go test -race -count=1 ./pkg/clierr ./examples/ch03/... | grep -v 'no test files'")

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

#exercises(
  [*Retry hints from the server.* Teach `deployctl` to honour a `Retry-After` header on 503 responses via `retry.After`, and to put the wait into the `DPL-PARTIAL` hint ("eu-west-1 asked to retry after 30s"). Extend the fake API and the golden file. Should a 503 with `Retry-After` change the exit code from 1 to 75? Argue it both ways, then decide.],
  [*An error catalogue generator.* Error IDs and their docs drift apart. Write a `go generate` tool that scans a module for `clierr.Error` literals with constant `ID` fields and produces the error catalogue in `examples/ch03/README.md`, failing if an ID is used with two different `Docs` links or has no catalogue entry.],
  [*Adopt `clierr` in `sweep`.* Port `cmd/sweep` to `clierr.Program`, keeping its four existing exit codes exactly. Make its `-deadline` cause a `*clierr.Error` that wraps `context.DeadlineExceeded`, and add binary-level tests for 0, 1, 2, 75 and 130. Which of `sweep`'s existing tests needed to change, and why?],
  [*Panic-safe errgroup.* Write `conc.SafeGroup`, an `errgroup.Group` whose `Go` wraps each function with `clierr.Safe`. Then write a test showing the deadlock the errgroup authors warn about: a panic that leaves a mutex locked so that a sibling never returns and `Wait` never completes. How would you bound it?],
  [*Exit-code telemetry.* Add an `--metrics-file` flag to `deployctl` that appends one JSON line per run (command, exit code, error ID, duration). Write a small report tool that reads a week of these files from CI artifacts and prints the code distribution per command. What threshold would you alert on for 70?],
)
