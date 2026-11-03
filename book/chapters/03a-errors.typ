#import "../template/book.typ": *
#import "03-lib.typ": ts

#step(1, 8, "Errors are values", label: <sec-err-step-values>)

The first version deploys to each target in turn and stops at the first
failure. Its error handling is what most Go programs start with: every
function returns an `error`, every layer adds a little context, and `main`
prints whatever arrives and exits 1. That is already better than the four
habits above, and it is the baseline every later step improves on.

Start with an empty module:

#session(
  ("mkdir deployctl && cd deployctl", none),
  ("go mod init deployctl", "ch03/s1-modinit.txt"),
  ("go get go@1.27.0", "ch03/s1-goget.txt"),
)

`go get go@1.27.0` lowers the `go` line in `go.mod` to the first 1.27
release, the minimum this module needs, as Chapter 1 explained. The module
path is plain `deployctl` because nobody will import this program. The
layout follows Chapter 1's conventions: one directory per binary under
`cmd/`, code no other module may import under `internal/`, and a `lab/`
directory for the small programs this chapter uses to show one behaviour at
a time.

=== A deployment API to fail against

You need an API that fails on demand, and a real deployment system is a bad
place to find out how your tool behaves when it does. `internal/fakeapi` is
a small HTTP handler with fixed behaviour per target name. Create
`internal/fakeapi/fakeapi.go`:

#src("workbook/ch03/step1/internal/fakeapi/fakeapi.go")

The package comment is the table that matters for the rest of the chapter:
`eu-west-1` always fails its health check with 503, `sa-east-1` is locked by
another deploy and answers 409, `ap-south-1` is slow, and every other target
deploys in 100 milliseconds. Every request needs a bearer token, and every
response carries an `X-Request-Id` header, as production APIs do; you will
see why that header matters in step 2. `GET /v1/status` returns a row with a
`null` previous release, which step 7 turns into a crash.

`cmd/fakeapi/main.go` serves it on `127.0.0.1:8787` and logs each request:

#src("workbook/ch03/step1/cmd/fakeapi/main.go")

The log line quotes the path with `%q`. A path is attacker-controlled input,
and printed raw it could contain a newline and forge a second log line; the
`gosec` linter from Chapter 1 flags the unquoted version. The `nolint`
comment records that the finding was read and handled, which is the only
kind of `nolint` worth writing.

=== The config file

`deployctl` reads the API address, the service name and the targets from a
JSON file. Create `prod.json` in the module's root:

#src("workbook/ch03/step1/prod.json")

The loader goes in `cmd/deployctl/config.go`:

#src("workbook/ch03/step1/cmd/deployctl/config.go", region: "imports")
#src("workbook/ch03/step1/cmd/deployctl/config.go", region: "config")
#src("workbook/ch03/step1/cmd/deployctl/config.go", region: "load")

`loadConfig` has two ways to fail, and it treats them differently on
purpose. The error from `os.ReadFile` already names the file
(`open deployctl.json: no such file or directory`), so the loader adds only
what it was doing, `load config`. The error from `json.Unmarshal` knows the
byte offset of the problem but not the file, so that one gets the path.
Each layer adds what its caller doesn't know, and nothing else.

#goconcept(title: [The `error` interface])[
  `error` is a built-in interface with one method:

  #code(file: "sketch")[```go
  type error interface {
  	Error() string
  }
  ```]

  Any type with that method is an error, and a function that can fail
  returns one as its last result. Chapter 0 used errors this way; here is
  what is underneath. An interface value is a pair: the dynamic type of what
  it holds, and the value. `err == nil` is true only when both are empty,
  which is why a function must `return nil`, not a nil `*MyError`: that
  would be an interface holding the type `*MyError` and a nil pointer, and
  the caller's `err != nil` would be true.

  Comparing two errors with `==` compares the pairs. Two values made by
  separate calls to `errors.New("x")` are different pointers, so they are
  never equal, which is what makes a package-level
  `var ErrNotFound = errors.New("not found")` work as a unique value callers
  can test for (step 2). Error types usually have pointer receivers and are
  returned as pointers, so each failure is one value that can be found and
  read later. And because `error` is an interface, any package can define
  its own error types without importing yours: the standard library's
  `*fs.PathError`, `*url.Error` and `*json.SyntaxError` are all just types
  with an `Error` method.
]

#goconcept(title: [`%w` and wrapping])[
  `fmt.Errorf("load config: %w", err)` returns a new error whose message is
  the formatted string and which also remembers `err`: it has an
  `Unwrap() error` method that returns it. Each layer that wraps adds one
  link, so an error becomes a _chain_ you can read from the outside in:
  `load config: open deployctl.json: no such file or directory` is three
  errors, the outermost from `loadConfig`, then the `*fs.PathError` from
  `os.Open`, then the operating system's `ENOENT`.

  `errors.Is(err, target)` walks that chain and reports whether any link is
  `target`; `errors.Unwrap(err)` takes one step. The `%v` verb formats the
  same text without the `Unwrap` method, so it _cuts_ the chain: the message
  is identical, and `errors.Is` can no longer see past it. That is sometimes
  what you want (@sec-err-chains explains when), and usually a bug. Since
  Go 1.20 a format string may contain several `%w` verbs, which makes a
  tree instead of a chain; step 3 needs that.
]

=== Talking to the API

The client goes in `cmd/deployctl/client.go`. For now it has one job: send
a request and turn anything but a 2xx answer into an error.

#src("workbook/ch03/step1/cmd/deployctl/client.go", region: "imports")
#src("workbook/ch03/step1/cmd/deployctl/client.go", region: "client")
#src("workbook/ch03/step1/cmd/deployctl/client.go", region: "do")

Most errors in `do` are returned without any context added, and the comment
on the one from `client.Do` says why: it fails with a `*url.Error`, whose message
already says which request failed and how (the troubleshooting table at the
end of this step shows one), so wrapping it in `deploy request: ...` would
only repeat that.

A status code is data, not an error, to `net/http`: a 503 comes back with
`err == nil`. The client decides what counts as failure, and for now it
makes an _opaque_ error with `fmt.Errorf` and no `%w`: a message and
nothing a caller can inspect. Step 2 replaces it with a type that keeps the
status code and the request ID. `defer resp.Body.Close()` returns the
connection to the pool whichever way the function exits. Chapter 2's box on
`http.Client` explains why the body must always be closed; the `bodyclose`
linter checks it.

The last region holds the one method callers use, and the constructor:

#src("workbook/ch03/step1/cmd/deployctl/client.go", region: "deploycall")

=== The deploy command

`cmd/deployctl/deploy.go` parses the `deploy` command's arguments, loads the
config, and deploys to each target in turn:

#src("workbook/ch03/step1/cmd/deployctl/deploy.go", region: "imports")
#src("workbook/ch03/step1/cmd/deployctl/deploy.go", region: "deploy")

Each failure leaves `deploy` with context only this function has: which
version, which target. Read the whole message aloud when you add a layer.
The first of these is a sentence, and the second is noise:

#code(file: "two messages")[```
deploy v1.4.2 to eu-west-1: POST /v1/deploy/eu-west-1: 503 Service Unavailable
error: failed to deploy: failed to post: 503
```]

Every layer of an error chain failed, so "failed to" and "error:" add
nothing, and they get repeated once per layer. Keep messages lowercase with
no trailing punctuation, because they end up inside other messages.

This version stops at the first failed target. That is a real decision with
real consequences: a rollout to forty regions that hits one bad region at
number three leaves thirty-seven untouched and reports one line. Step 3
deploys to every target and reports every failure.

=== One place that reports

`cmd/deployctl/main.go` holds `main` and `run`. Start with the package
comment, the imports and `main`:

#src("workbook/ch03/step1/cmd/deployctl/main.go", region: "head")
#src("workbook/ch03/step1/cmd/deployctl/main.go", region: "main")

`main` is where the rule "handle or return, never both" ends. Everything
below it returns its error and prints nothing; `main` prints it once, with
the program's name in front so the user knows which tool is talking, and
exits. Then the flags every command shares, and `run`:

#src("workbook/ch03/step1/cmd/deployctl/main.go", region: "globals")
#src("workbook/ch03/step1/cmd/deployctl/main.go", region: "run")

`run` is Chapter 1's testable shape: arguments, environment and output come
in as parameters, and an error comes out. It never calls `os.Exit`, so a
test can call it many times in one process. The last region formats
durations for people:

#src("workbook/ch03/step1/cmd/deployctl/main.go", region: "elapsed")

`main` is also where this version is weakest, and the weakness is the
fourth habit from the start of the chapter: every failure exits 1. A typo
in a flag, a missing config file, a rejected token and a broken region all
look the same to a pipeline. The message is the raw chain, written for
programmers. And the flag package, as you will see at the checkpoint,
prints some errors itself before `main` prints them again. Step 4 fixes all
three.

=== Seeing the chain

`lab/chain` is a small program that shows what `errors.Is` sees, using a
real error from the operating system. Create `lab/chain/main.go`:

#src("workbook/ch03/step1/lab/chain/main.go")

#output("ch03/s1-chain.txt", cmd: "go run ./lab/chain")

The two errors print the same message. Only the one made with `%w` still
has the `*fs.PathError` inside it, and `errors.Is` finds
`fs.ErrNotExist` there even though the innermost error is
`syscall.ENOENT`: `syscall.Errno` has an `Is` method that says `ENOENT`
matches `fs.ErrNotExist`, so code can test for "not found" without caring
which operating system produced it. When you write an `Is` method of your
own, compare shallowly and never call `Unwrap` inside it; `errors.Is` does
the walking.

=== Tests

`cmd/deployctl/run_test.go` runs the command in-process against the fake
API, served by `net/http/httptest` on a random local port:

#src("workbook/ch03/step1/cmd/deployctl/run_test.go", region: "imports")
#src("workbook/ch03/step1/cmd/deployctl/run_test.go", region: "helpers")
#src("workbook/ch03/step1/cmd/deployctl/run_test.go", region: "step1")

The tests use `Fast: time.Millisecond`, so a deploy takes a millisecond
instead of a hundred. Look at how the last test checks the error: not by
comparing the message with a string, which would break the first time
someone improved the wording, but with `errors.Is`, which asks whether the
failure is the one the test means. That only works because `loadConfig`
wrapped with `%w`; the troubleshooting table below shows the test failing
when it doesn't. Every later step adds tests to this file, each in a region
named after its step.

#needspace(12em)
#checkpoint(step: 1, of: 8, title: [Errors are values])[
  Your module should contain these files:
  #output("ch03/s1-tree.txt", cmd: "find . -name '*.go' -o -name '*.json' | sort")
  Vet and test it:
  #output("ch03/s1-test.txt", cmd: "go vet ./... && go test ./...")
  Start the fake API in a second terminal and leave it running for the rest
  of the chapter (restart it after each step, so it runs that step's code):
  #output("ch03/s1-api.txt", cmd: "go run ./cmd/fakeapi", title: "terminal 2")
  Back in the first terminal, export the token the fake API accepts, build
  `deployctl`, and deploy. The log in terminal 2 above shows the three
  requests this run made:
  #session(
    ("export DEPLOYCTL_TOKEN=dev-token", none),
    ("go build ./cmd/deployctl", "ch03/s1-build.txt"),
    ("./deployctl -config prod.json deploy v1.4.2", "ch03/s1-run.txt"),
    ("echo $?", "ch03/s1-run.code"),
  )
  The rollout stopped at `eu-west-1`, so `sa-east-1` was never tried. Now
  two more failures. Note the exit status of both, and that a mistyped flag
  is reported twice, once by the `flag` package and once by `main`:
  #session(
    ("./deployctl deploy v1.4.2", "ch03/s1-noconfig.txt"),
    ("echo $?", "ch03/s1-noconfig.code"),
    ("./deployctl -config prod.json deploy -parallel=2 v1.4.2", "ch03/s1-badflag.txt"),
    ("echo $?", "ch03/s1-badflag.code"),
  )
  #troubleshoot(
    ([#ts("s1-noapi.txt")], [The fake API is not running, so the connection is refused. The `*url.Error` names the request.], [Start `go run ./cmd/fakeapi` in a second terminal.]),
    ([#ts("s1-notoken.txt")], [`DEPLOYCTL_TOKEN` isn't set in this terminal, so the API rejects the first deploy. Step 2 checks the token before deploying anything.], [`export DEPLOYCTL_TOKEN=dev-token`.]),
    ([#ts("s1-percentv.txt")], [`loadConfig` wraps with `%v`, not `%w`: the message is the same, but the chain is cut and `errors.Is` can't see `fs.ErrNotExist`.], [Use `%w`. See the box on `%w` and wrapping.]),
    ([#ts("s1-bodyclose.txt")], [`defer resp.Body.Close()` is missing, so every call leaks a connection.], [Add it right after the error check on `Do`.]),
    ([#ts("s1-errcheck.txt")], [The error from `json.Unmarshal` is ignored: a malformed file would deploy an empty config.], [Check it and return it with context.]),
  )
]

#step(2, 8, "Sentinels, types and behaviours", label: <sec-err-step-kinds>)

Step 1's errors are good for reading and useless for deciding. The rollout
can't tell a 503 that might clear up in a second from a 409 that won't, so
it can't retry sensibly. `main` can't tell a rejected token from a broken
region. The fix is to give some errors a shape that code can inspect. This
step adds three shapes, and the section below explains how to choose
between them.

=== Four kinds of error <sec-err-kinds>

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

Start opaque, as step 1 did. Promote an error to a sentinel or a type only
when a caller has a real decision to make with it, such as "retry or not",
"exit 77 or 1", "create the file or report it". The decision is the reason
for the API.

Behavioural checks are underused. Code that asks "is this a timeout?" should
not need to know whether the timeout came from `net`, `os`, `context`, or an
SDK. Asking for `interface{ Timeout() bool }` works for all of them, which is
how `clierr.CodeOf` maps every kind of timeout to one exit code in step 4.
Be precise about the method's meaning, though. `net.Error` once had a
`Temporary()` method, and Go 1.18 deprecated it with the note "Temporary
errors are not well-defined", because callers and implementers disagreed
about what it meant. A behaviour is only useful if everyone agrees what it
promises.

#goconcept(title: [Type assertions, `errors.As` and `errors.AsType`])[
  A _type assertion_ asks an interface value what it holds:
  `apiErr, ok := err.(*APIError)` sets `ok` if `err`'s dynamic type is
  exactly `*APIError`. For errors that is almost always the wrong question,
  because the `*APIError` is usually a few links down a chain, under
  `deploy v1.4.2 to eu-west-1: ...`, and the assertion only looks at the
  outermost link. The `errorlint` linter flags assertions and `==`
  comparisons on errors for that reason.

  `errors.As(err, &target)` walks the chain and stops at the first error
  that can be assigned to `target`, which must be a pointer to a variable of
  the type you want: declare `var apiErr *APIError`, pass `&apiErr`. Passing
  `apiErr` itself, or a pointer to a type that isn't an error, panics at run
  time; `go vet` catches the common cases. Go 1.26 added a generic form
  without the variable:

  #code(file: "sketch")[```go
  if apiErr, ok := errors.AsType[*APIError](err); ok {
  	// apiErr is the first *APIError in err's chain
  }
  ```]

  The result is scoped to the `if`, a wrong type is a compile error, and
  there is no reflection. Interface types work too, as long as they embed
  `error`, because of the constraint on the type parameter:
  `errors.AsType[interface{ error; Timeout() bool }](err)` finds the first
  error that has a `Timeout` method. Use `AsType` in new code; `go fix` and
  the `modernize` linter rewrite old `errors.As` calls for you.
]

=== `APIError`: an error with fields

Replace `cmd/deployctl/client.go`'s imports and add two error types after
them:

#src("workbook/ch03/step2/cmd/deployctl/client.go", region: "imports")
#src("workbook/ch03/step2/cmd/deployctl/client.go", region: "apierror")

`APIError` keeps what the API said in three fields a caller can read, and
`Error()` puts all three in the message, so the request ID reaches every
log the error is printed in. That ID is what the API's owners need to find
one request among millions. `Temporary` is a behaviour, narrow and
documented: 429 (slow down) and 5xx (the server's problem) might succeed if
you ask again; a 409 or a 401 never will.

When the client gives up after several attempts, the caller should know
both facts: that it retried, and what the last attempt said.

#src("workbook/ch03/step2/cmd/deployctl/client.go", region: "retryerror")

`RetryError` wraps the last attempt's error, and its `Unwrap` method is what
keeps the chain intact: `errors.AsType[*APIError]` still finds the 503
underneath. Every layer can add its own meaning (retried, three attempts)
without hiding the original from code above it. Delete `Unwrap` and the
failure becomes opaque again; the troubleshooting table shows the test that
catches it.

=== Retrying at the source

The `Client` gains two fields for the retry policy:

#src("workbook/ch03/step2/cmd/deployctl/client.go", region: "client")

Replace `do` with a retry loop around a new `send` method. The split puts
each decision where the knowledge is. `send` makes one attempt and
classifies its own failure, because only it knows the protocol: no answer at
all (refused, reset, timed out) is worth another try, an `*APIError` is worth
one if it is `Temporary`, and anything else (a request that can't be built, a
response that can't be decoded) is not. `do` knows nothing about HTTP. It
retries while `send` says `again`, doubles the pause each time, gives up
early if the context is done, and wraps the last error in a `RetryError` when
the attempts run out:

#src("workbook/ch03/step2/cmd/deployctl/client.go", region: "do")
#src("workbook/ch03/step2/cmd/deployctl/client.go", region: "send")

Chapter 4 builds a full retry policy with jitter and `Retry-After`;
Exercise 3.5 adds the second to this one.

The error body is read through `io.LimitReader`, so a misbehaving server
can't make the client buffer a gigabyte of HTML to find an error message.
The decode error is ignored on purpose: a 503 with an unreadable body is
still a 503, and the status code is in the error either way.

=== Check the token first

A bad token in step 1 produced a 401 from the first target, in the middle
of what looked like a rollout. Add a method that asks the API who we are,
and turns a rejection into a clear error:

#src("workbook/ch03/step2/cmd/deployctl/client.go", region: "auth")
#src("workbook/ch03/step2/cmd/deployctl/client.go", region: "deploycall")

This is the first `errors.AsType` in `deployctl`. Without the preflight call,
a bad token would fail once per target, and a forty-region rollout would
report forty identical 401s. Failing up front with one message means
"rejected token" also always means "nothing was changed", which step 4 turns
into an exit code a pipeline can rely on. `deploy` calls it after loading
the config:

#src("workbook/ch03/step2/cmd/deployctl/deploy.go", region: "deploy")

=== Sentinels: not found, already exists

The most common sentinel in a CLI is "file not found", and it deserves its
own message. Replace the imports and `loadConfig` in `config.go`, and add
`initConfig` after it:

#src("workbook/ch03/step2/cmd/deployctl/config.go", region: "imports")
#src("workbook/ch03/step2/cmd/deployctl/config.go", region: "load")
#src("workbook/ch03/step2/cmd/deployctl/config.go", region: "init")

`errors.Is(err, fs.ErrNotExist)` asks the question without parsing a
message or knowing which system call failed. The new message says what to
do about it: run `deployctl init`. `initConfig` opens its file with
`O_EXCL`, which makes the operating system refuse if the file exists, and
then checks for the `fs.ErrExist` sentinel. Checking first with `os.Stat`
and creating second would leave a gap in which another process could create
the file; letting the open fail is both simpler and correct.

`f.Write` and `f.Close` can both fail, and a failed `Close` on a written
file can mean the data never reached the disk. `errors.Join(err, f.Close())` keeps both errors, or returns `nil` if both are `nil`; step 3
looks at what `Join` builds. Register the command in `run`:

#src("workbook/ch03/step2/cmd/deployctl/main.go", region: "run")

=== The lab again

Add `errors.As` and `errors.AsType` to `wrapping` in `lab/chain/main.go`.
Both look for the same thing on the same wrapped error: the first
`*fs.PathError` in the chain, the one `os.Open` returned. `errors.As` needs a
variable declared first and its address passed in; `AsType` returns the match
and a boolean, so the variable lives only inside the `if`. Either way you get
the error's fields: `Op` and `Path` say what was attempted, and `Err` holds
the operating system's own error, which is what `errors.Is` matched against
`fs.ErrNotExist` in step 1:

#src("workbook/ch03/step2/lab/chain/main.go", region: "wrap")

#output("ch03/s2-chain.txt", cmd: "go run ./lab/chain")

Both find the `*fs.PathError` inside the wrapped error and read its fields.
The `nolint` comment on the `errors.As` line is there because the
`modernize` linter would otherwise flag it and suggest the `AsType` form
below it.

#newingo("1.27", title: [`go vet` flags wrapped pointers that defeat `errors.As`])[
  The `printf` analyzer now reports `fmt.Errorf("...: %w", p)` when `p` has
  type `*E` and `E` itself implements `error`. Wrapping the pointer means
  `AsType[E]` and `errors.Is` comparisons against `E` values never match.
  Create `lab/testdata/ptrwrap.go`:
  #src("workbook/ch03/step2/lab/testdata/ptrwrap.go")
  #session(
    ("go vet lab/testdata/ptrwrap.go 2>&1 | fold -s -w 80", "ch03/s2-vet-ptrwrap.txt"),
    ("go run lab/testdata/ptrwrap.go", "ch03/s2-run-ptrwrap.txt"),
  )
  The file sits under `testdata`, which `./...` patterns skip, so the rest
  of the module still passes `go vet`.
]

=== Tests

Add the step 2 tests to `run_test.go`:

#src("workbook/ch03/step2/cmd/deployctl/run_test.go", region: "step2")

Each test asserts on identity and fields, never on wording: a 409 is an
`*APIError` with status 409 and a request ID, and it was not retried; a 503
was retried three times and the `*APIError` is still in the chain; a bad
token stops before anything is printed; `init` refuses to overwrite with an
error that `errors.Is` recognizes as `fs.ErrExist`.

#needspace(12em)
#checkpoint(step: 2, of: 8, title: [Sentinels, types and behaviours])[
  #output("ch03/s2-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch03/s2-test.txt", cmd: "go vet ./... && go test ./...")
  Restart the fake API in terminal 2, rebuild, and deploy again:
  #session(
    ("go build ./cmd/deployctl", none),
    ("./deployctl -config prod.json deploy v1.4.2", "ch03/s2-run.txt"),
    ("echo $?", "ch03/s2-run.code"),
  )
  The API's log shows the token check, then three attempts at `eu-west-1`
  with the pause doubling from 100 to 200 milliseconds:
  #output("ch03/s2-api.txt", cmd: "go run ./cmd/fakeapi", title: "terminal 2")
  A bad token now fails before anything is deployed, a missing config file
  gets a suggestion, and `init` won't overwrite the file it made:
  #session(
    ("DEPLOYCTL_TOKEN=expired ./deployctl -config prod.json deploy v1.4.2", "ch03/s2-auth.txt"),
    ("./deployctl deploy v1.4.2", "ch03/s2-noconfig.txt"),
    ("./deployctl init && cat deployctl.json", "ch03/s2-init.txt"),
    ("./deployctl init", "ch03/s2-init2.txt"),
    ("rm deployctl.json", none),
  )
  The messages are better, but every one of these runs still exits 1, and
  each still ends with the raw chain. Step 4 separates the message from the
  chain.
  #troubleshoot(
    ([#ts("s2-as.txt")], [`errors.As(err, apiErr)`: the target must be a pointer to the variable, `&apiErr`. At run time this panics.], [Pass `&apiErr`, or use `errors.AsType`.]),
    ([#ts("s2-equal.txt")], [A sentinel compared with `==`. It stops matching as soon as anyone wraps the error.], [`errors.Is(err, fs.ErrNotExist)`.]),
    ([#ts("s2-assert.txt")], [A type assertion on an error only sees the outermost link of the chain.], [`errors.AsType[*APIError](err)`.]),
    ([#ts("s2-retry409.txt")], [`send` returns `again = true` for every `*APIError`, so a 409 is retried three times.], [Return `apiErr.Temporary()`.]),
    ([#ts("s2-nounwrap.txt")], [`RetryError` has no `Unwrap` method, so the chain ends at it and the `*APIError` is invisible.], [Add `Unwrap`. See "`APIError`: an error with fields".]),
  )
]

#step(3, 8, "One error, many failures", label: <sec-err-step-join>)

A rollout to four targets has four outcomes, and step 2 reports only the
first failure and never tries the rest. This step deploys to every target,
several at a time, and returns one error that describes all the failures.
That needs a way to put several errors in one, and Go has had one since
1.20.

#goconcept(title: [Goroutines, channels and `WaitGroup.Go`, briefly])[
  Chapter 0 introduced these, and Chapter 4 is about little else; this step
  needs only the basics. `go f()` runs `f` concurrently in a new goroutine.
  A channel passes values between goroutines: `results <- r` sends,
  `r := <-results` receives, and `for r := range results` receives until
  someone calls `close(results)`. An unbuffered channel makes the sender
  wait for a receiver; `make(chan struct{}, n)` has room for `n` values, so
  sending into it blocks only when it is full, which makes it a simple
  counting semaphore. `wg.Go(f)` (Go 1.25) starts `f` in a goroutine and
  tracks it, and `wg.Wait()` blocks until every tracked goroutine has
  returned. Two rules keep this safe: only the sender closes a channel, and
  only after every send is done; and a variable written by one goroutine is
  never touched by another without synchronization. `go test -race` checks
  the second.
]

=== Trees: `errors.Join` and multiple `%w` <sec-err-chains>

`errors.Join(errs...)` returns an error that wraps all its non-nil
arguments (and `nil` if they are all `nil`), and `fmt.Errorf` accepts
several `%w` verbs in one format string. Both produce an error with an
`Unwrap() []error` method instead of `Unwrap() error`, so a chain becomes a
tree. `errors.Is` and `errors.As` traverse the tree depth first, visiting an
error before its children and the children in order, and stop at the first
match. Add a second part to the lab, after `wrapping`:

#src("workbook/ch03/step3/lab/chain/main.go", region: "tree")

`walk` prints the dynamic type of every node in the order `errors.Is` visits
them. Walking a tree by hand takes a type switch over the two `Unwrap`
shapes:

#src("workbook/ch03/step3/lab/chain/main.go", region: "walk")

Replace the imports and `main` so `go run ./lab/chain tree` runs the new
part:

#src("workbook/ch03/step3/lab/chain/main.go", region: "head")
#src("workbook/ch03/step3/lab/chain/main.go", region: "main")

#output("ch03/s3-chain.txt", cmd: "go run ./lab/chain tree")

The indentation shows the visiting order. Three consequences of the tree
shape catch people out:

- `errors.Unwrap` only calls `Unwrap() error`, so it returns `nil` for a
  joined error. A hand-written `for err != nil { err = errors.Unwrap(err) }`
  loop silently stops at the first `Join` and misses everything below it.
- `AsType` returns the _first_ match in depth-first order. When a tree holds
  several errors of the type you want, as `deployctl`'s partial failure
  does, you get the leftmost one. To see them all, walk the tree yourself;
  Exercise 3.3 turns that into a function.
- A joined error's message is its children's messages separated by
  newlines. That works in a log and looks broken in a one-line terminal
  message, as this step's checkpoint shows. Step 4 lists the children on
  lines of their own.

#warning(title: [Wrapping makes the cause part of your API])[
  Once a package returns `fmt.Errorf("query: %w", err)` with a
  `*pgconn.PgError` underneath, callers start writing
  `errors.AsType[*pgconn.PgError]`, and you can no longer change database
  drivers without breaking them. Wrap with `%w` when you mean callers to
  inspect the cause: your own sentinels and types, or standard ones such as
  `fs.ErrNotExist` and `context.DeadlineExceeded`. At package boundaries,
  use `%v` for implementation details you want to keep the freedom to
  change. The Go blog's 2019 post on Go 1.13 errors makes the same argument,
  and Exercise 3.6 asks you to apply it to `deployctl`.
]

=== Deploying to every target

Rewrite `cmd/deployctl/deploy.go`. The imports gain `errors` and `sync`, and
a small type carries one target's outcome:

#src("workbook/ch03/step3/cmd/deployctl/deploy.go", region: "imports")
#src("workbook/ch03/step3/cmd/deployctl/deploy.go", region: "result")

`deploy` gains two flags, `-parallel` and `-only`, and hands the work to
`rollout`:

#src("workbook/ch03/step3/cmd/deployctl/deploy.go", region: "deploy")

`rollout` is a bounded worker pool:

#src("workbook/ch03/step3/cmd/deployctl/deploy.go", region: "rollout")

One goroutine starts the workers. Before each one, it puts a token into
`slots`, which blocks while `parallel` workers are already running; each
worker takes its token back out when it is done. Starting workers in target
order, and only when a slot is free, means at most `parallel` goroutines
exist at once and the targets start in the order the config lists them. When
every worker has been started and `wg.Wait` says every one has sent its
result, the same goroutine closes `results`, which ends the `range` loop.

The loop is the only code that touches `failed`. Each failed result is
wrapped with its target's name, and at the end the failures are joined
into one error under a headline that counts them. The headline uses `%w`
on the joined error, so the tree stays inspectable: `errors.Is` and
`errors.AsType` can still find every `*APIError` underneath. The last two
functions run one target and print one line:

#src("workbook/ch03/step3/cmd/deployctl/deploy.go", region: "deployone")
#src("workbook/ch03/step3/cmd/deployctl/deploy.go", region: "print")

`-only` takes a comma-separated list. Add `strings` to `main.go`'s imports,
and the parser after `run`:

#src("workbook/ch03/step3/cmd/deployctl/main.go", region: "head")
#src("workbook/ch03/step3/cmd/deployctl/main.go", region: "splitlist")

`strings.SplitSeq` (Go 1.24) returns an iterator instead of a slice, so the
loop doesn't build a slice it would only throw away.

=== Every problem in one go

The same idea applies to the config file. Nobody wants to fix a file one
error per run, so `loadConfig` collects every problem it finds and joins
them. Replace it:

#src("workbook/ch03/step3/cmd/deployctl/config.go", region: "load")

`errors.Join` returns `nil` when it has nothing to join, so the `if` needs no
separate length check.

=== Tests

#src("workbook/ch03/step3/cmd/deployctl/run_test.go", region: "step3")

#needspace(12em)
#checkpoint(step: 3, of: 8, title: [One error, many failures])[
  #output("ch03/s3-tree.txt", cmd: "find . -name '*.go' | sort")
  Run the tests with the race detector from now on:
  #output("ch03/s3-test.txt", cmd: "go vet ./... && go test -race ./...")
  Restart the fake API, rebuild, and deploy. Results arrive in the order the
  targets finish, so yours may differ:
  #session(
    ("go build ./cmd/deployctl", none),
    ("./deployctl -config prod.json deploy v1.4.2", "ch03/s3-run.txt"),
    ("echo $?", "ch03/s3-run.code"),
  )
  Every target was tried, and the error names both failures. The joined
  error's second child starts on a new line with no indentation, which reads
  as if it were a separate message. `-only` deploys a subset:
  #session(
    ("./deployctl -config prod.json deploy -only us-east-1,us-west-2 v1.4.2", "ch03/s3-only.txt"),
    ("echo $?", "ch03/s3-only.code"),
  )
  A config file with two problems reports both:
  #session(
    ("cat incomplete.json", "ch03/s3-catincomplete.txt"),
    ("./deployctl -config incomplete.json deploy v1.4.2", "ch03/s3-incomplete.txt"),
  )
  #troubleshoot(
    ([#ts("s3-closeearly.txt")], [`close(results)` runs before `wg.Wait()`, so a worker sends on a closed channel.], [Close only after `Wait`. Only the sender closes, and only when every send is done.]),
    ([#ts("s3-noclose.txt")], [Nobody closes `results`, so `rollout`'s `range` waits forever. The test binary's timeout reports the stuck goroutine.], [Close the channel in the goroutine that waits.]),
    ([#ts("s3-race.txt")], [Two workers update the same variable (here a count of deployed targets) with no synchronization. Only `-race` notices.], [Count in the loop that reads `results`, which owns everything the workers report.]),
  )
]
