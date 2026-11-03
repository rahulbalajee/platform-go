#import "../template/book.typ": *
#import "03-lib.typ": ts

#chapter(3, "Errors, Exit Codes, and Failure as a Feature", label: <ch-errors>,
  abstract: [
    A platform tool spends most of its life succeeding quietly. People
    remember how it fails: whether the message says what to do next, whether
    the pipeline can tell an expired token from a flaky region, whether a bug
    leaves a report behind or a wall of goroutines. In this chapter you build
    a deploy CLI from an empty directory, break it in every way a real one
    breaks, and grow the error layer that every command-line tool in the book
    shares, one working step at a time.
  ],
  learn: (
    [How `%w`, `errors.Is`, `errors.As` and Go 1.26's `errors.AsType` walk error chains and trees],
    [Sentinel, typed, opaque and behavioural errors, and how retry decisions use them],
    [Context errors and causes, and a `net/http` detail that breaks `errors.Is(err, context.Canceled)`],
    [Exit codes as an API: conventions, shells, `pipefail`, CI systems and Kubernetes Jobs],
    [Messages for people versus records for operators: hints, error IDs, request IDs, `log/slog`, redaction],
    [Where panics belong, where to recover them, and how to turn a crash into a bug report],
    [Testing error paths with `errors.Is`, golden files and the real binary],
  ),
  build: [
    *`deployctl`*, a deploy CLI that fails in every way a real one does: a
    bad flag, a missing config file, a rejected token, a partial rollout, a
    timeout, #kbd("Ctrl-C"), and a genuine bug. You build it in eight steps,
    against a fake deployment API that runs on your machine.

    #v(4pt)
    *`clierr`*, the error and exit-code layer it grows along the way: a
    documented exit-code contract, errors that carry a message, hint and
    docs link apart from the cause chain, and a `Program` that reports once,
    logs with `log/slog`, honours signals, and turns panics into crash
    reports. The last step is the production code in `pkg/clierr`.
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

@fig-err-audiences shows how `deployctl`, the CLI you build in this chapter,
serves all four from the single `error` its `run` function returns.

#fig(caption: [One failure, four audiences. The run function returns one error; `clierr` decides the exit code and writes each audience its own view of it, exactly once. The numbers are the build steps that add each part.])[
  #diagram(
    spacing: (26pt, 10pt),
    dnode((0, 1.5), [`run` returns\ one `error` #h(2pt) *1*], kind: "dark"),
    dnode((1, 1.5), [`clierr.Program.Run`\ `CodeOf` · report once #h(2pt) *4*], kind: "accent"),
    dnode((2, 0), [*person*: stderr\ message · hint · docs link #h(2pt) *4*], kind: "default"),
    dnode((2, 1), [*script / CI*: exit status #h(2pt) *4*\ plus JSON with `-o json` #h(2pt) *6*], kind: "default"),
    dnode((2, 2), [*operator*: `slog` record\ cause chain · types · IDs #h(2pt) *6*], kind: "default"),
    dnode((2, 3), [*maintainer*: crash file\ build info · stack #h(2pt) *7*], kind: "warn"),
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
they swallow errors, log them and return them too, exit from deep inside, and
use one exit code for every failure. The swallowed error turns a partial
failure into a reported success, and the
pipeline promotes a release that is missing from one region. Log-and-return
writes the same failure once per layer, so the log shows four errors for one
problem and the outermost copy usually lacks the detail the innermost one
had. `log.Fatal` calls `os.Exit`, which runs no deferred functions: lock files
stay locked, temporary credentials stay on disk, and the summary the user
needed never prints. A single exit code throws away the one piece of
structured information every caller is guaranteed to receive. In code, the
four habits look like this:

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

The rules that replace these habits fit in three sentences. Handle an error
or return it, never both. Add the context you have when you return it.
Decide what the user sees, and what the process exits with, in exactly one
place at the top of the program. You will write the fourth habit yourself in
step 1, on purpose, and spend the rest of the chapter replacing it.

== What we're building <sec-err-building>

`deployctl` rolls one version of a service out to a list of targets (regions,
clusters, whatever your platform calls them) through a deployment API, and
reports what happened. Here is the finished tool, built in step 8, against
the fake API you will run on your machine. Two of the four targets deploy;
one is locked by another deploy and one fails its health check:

#output("ch03/s8-tour.txt", cmd: "./deployctl -config prod.json deploy v1.4.2; echo \"exit status $?\"")

Results stream to standard output as they arrive. The one error report goes
to standard error, last, so it is the last thing on the screen: a headline in
the user's terms, one line per failed target in the API's own words, a hint
that is a command you can run, a stable ID you can search for, and a docs
link. The exit status, 1, means "ran, and the answer is no". A rejected token
looks different in every part, including the number:

#output("ch03/s8-tour-auth.txt", cmd: "DEPLOYCTL_TOKEN=expired ./deployctl -config prod.json deploy v1.4.2; echo \"exit status $?\"")

Nothing was deployed, the hint says what to do and quotes the request ID the
API's owners will ask for, and 77 tells a pipeline that retrying would only
lock the account. The rest of the chapter builds every piece of this, and
breaks each piece on the way to show what it protects against.

=== The plan

#table(
  columns: (auto, 1.25fr, 1fr),
  table.header([Step], [What it adds], [Go you meet there]),
  [1 #h(3pt) Errors are values], [A fake deployment API, a sequential deploy that stops at the first failure, wrapping with context], [the `error` interface, `%w` and `%v`, `errors.Is`, `errors.Unwrap`],
  [2 #h(3pt) Sentinels, types, behaviours], [`APIError` with request IDs, retries for temporary failures, a token check before deploying, `init`], [sentinel errors, error types, type assertions, `errors.As` and `AsType`, behaviour interfaces],
  [3 #h(3pt) One error, many failures], [A parallel rollout that reports every failed target, config validation that reports every problem], [`errors.Join`, multiple `%w`, error trees, goroutines and channels again],
  [4 #h(3pt) An exit-code contract], [`pkg/clierr`: codes, `Error` with message, hint and docs, a `Program` that reports once; golden files], [named types as enums, exit statuses, shells and `pipefail`],
  [5 #h(3pt) Causes and signals], [`-timeout` with a cause that is a whole user-facing error; #kbd("Ctrl-C") and `SIGTERM` as exit codes], [`context.WithTimeoutCause`, `context.Cause`, `os/signal`],
  [6 #h(3pt) People and operators], [`-o json`, a JSON operator log with the cause chain, secrets that refuse to print], [`log/slog`, `fmt.Formatter`, `slog.LogValuer`],
  [7 #h(3pt) Panics and crash reports], [Panics become exit 70 and a crash file with build info; panics on worker goroutines], [`defer`, `panic` and `recover`, `runtime/debug`, goleak],
  [8 #h(3pt) Testing error paths], [Exit codes and stderr from the real binary, signals included], [`os/exec`, `TestMain`, golden files],
)

After the build, @sec-err-production covers what the exit codes tell you
once hundreds of pipelines depend on them.

=== How to work through the steps

Every step lists the files to create and the regions to replace, in full.
Type them, run the checkpoint commands at the end of the step, and compare
your output with the book's. Timings, request IDs and the order of
concurrent results will differ from run to run; everything else should
match. If it doesn't, the troubleshooting table under each checkpoint lists
failures we produced on purpose by breaking a copy of that step, with the
exact message each one prints. Most of them are the bugs this chapter is
about, so the tables double as a catalogue of how error handling goes wrong.

If you get stuck, the repository has every step as a complete module under
`workbook/ch03/step1` to `step8`, and each one passes `go vet`, `go test -race` and `golangci-lint`. Diff your directory against the step you are on.
The last step is the production code: the repository's `pkg/clierr` and the
programs under `examples/ch03` are the same files with longer import paths,
and a check in CI keeps them identical.

You need Go 1.27, the `golangci-lint` setup from Chapter 1, two terminal
windows, `jq` in step 6 and `git` in step 7. One command in step 4 checks a
Kubernetes manifest against a local `kind` cluster; skip it if you don't have
one yet.

#include "03a-errors.typ"
#include "03b-errors.typ"
#include "03c-errors.typ"
