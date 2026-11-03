#import "../template/book.typ": *
#import "02-lib.typ": ts, needspace

#step(7, 8, "Retries", label: <sec-api-s7>)

Networks drop connections, load balancers return 502 while a pod restarts,
and the platform answers 429 when a CI system floods it on a Monday
morning. A caller who sees one of these should usually just try again, and
if every caller writes that loop themselves, half of them will retry a
`POST` that wasn't safe to repeat. This step puts retries inside the SDK,
where the decision of what is safe to retry is made once, by the people who
know the API.

=== What may be retried

A retry is only safe if repeating the request can't do harm, and only
useful if the failure might go away. The SDK classifies every attempt on
both axes:

#table(
  columns: (1.2fr, auto, 1.6fr),
  align: (left, center, left),
  table.header([Outcome], [Retry?], [Why]),
  [Network error: refused, reset, timed out], [yes], [A pod went away or a connection was cut. Another attempt usually lands elsewhere.],
  [429 Too Many Requests, 503 Unavailable], [yes], [The server is shedding load. If it sends `Retry-After`, wait exactly that long.],
  [502 Bad Gateway, 504 Gateway Timeout], [yes], [These come from proxies and load balancers in front of the API.],
  [Any other 4xx], [no], [A 404 won't turn into a 200 in 200 ms, and a 400 is the same bad request every time.],
  [Any other 5xx], [no], [The server failed in a way it didn't call temporary. Repeating it adds load and rarely helps.],
  [A request that is neither `GET` nor marked idempotent], [no], [The first attempt may have done its work before the failure.],
)

The last row is the safety net. Every `POST` in this SDK is marked, either
because it carries an idempotency key or because it is naturally idempotent
(cancelling a cancelled deployment succeeds), and a future `POST` added
without thinking about idempotency fails safe.

=== A retry package

The loop itself is generic, and the book's repository keeps it in a package
of its own, `pkg/retry`, which Chapter 4 builds from scratch for the `sweep`
tool and explains in depth. Snapshots never import the book's repository,
so this step adds the same file to the SDK's module as a package,
`platformapi/retry`. Make a directory `retry` and create `retry/retry.go`.
It starts with the package documentation:

#src("workbook/ch02/step7/retry/retry.go", region: "head")

A `Policy` is a plain config struct, the shape from step 2's table that is
right for _values_. Its zero value works:

#src("workbook/ch02/step7/retry/retry.go", region: "policy")

`Do` runs an operation until it succeeds, fails permanently, runs out of
attempts, or the context ends:

#src("workbook/ch02/step7/retry/retry.go", region: "do")

The sleep is a `select` on a timer and `ctx.Done()`, like `Wait`'s, so a
caller's deadline cuts a backoff short. When the context ends, the error
says both why the retry stopped and what it was retrying: `%w` twice in one
`fmt.Errorf` wraps both errors, and `errors.Is` finds either. `Value` is a
generic method for operations that return a result; the SDK doesn't need
it, but it shows the Go 1.27 feature in a second, smaller setting:

#src("workbook/ch02/step7/retry/retry.go", region: "value")

The delay between attempts uses _full jitter_: a random duration between
zero and an exponentially growing ceiling. Without randomness, a thousand
clients that failed together retry together, at 200 ms, 400 ms, 800 ms, and
the server sees the same spike every time. With full jitter, their retries
spread evenly across each window:

#src("workbook/ch02/step7/retry/retry.go", region: "backoff")

Finally, the vocabulary an operation uses to classify its failures.
`Permanent` stops the retries, `After` asks for a specific delay, and
`ExhaustedError` reports that the attempts ran out:

#src("workbook/ch02/step7/retry/retry.go", region: "errors")

Both wrappers are transparent: their `Error` is the wrapped error's text,
and `Unwrap` lets `errors.Is` and `errors.AsType` see through them. A caller
of the SDK who checks `errors.Is(err, platformapi.ErrNotFound)` never needs
to know the error passed through a retry loop.

=== Wiring the policy into the client

The client gets a policy, on by default. In `client.go`, replace the import
block:

#src("workbook/ch02/step7/client.go", region: "imports")

add a `retry` field to `config`:

#src("workbook/ch02/step7/client.go", region: "client")

#needspace(10em)
and a default to `New`:

#src("workbook/ch02/step7/client.go", region: "option")

Then add the option after `WithPollInterval`:

#src("workbook/ch02/step7/client.go", region: "withretry")

`WithRetry` takes a `retry.Policy` struct: an option on the client,
carrying a value that is easy to build, copy and compare. Use structs for
_values_ (a policy, a request, a filter) and options for _the construction
of a long-lived object_; the two combine well.

Now the transport. Replace the import block of `transport.go`:

#src("workbook/ch02/step7/transport.go", region: "imports")

#needspace(10em)
and replace `request`, `newRequest` and `url`, to add the `idempotent` field:

#src("workbook/ch02/step7/transport.go", region: "request")

`do` keeps generating the request ID and the idempotency key once per call,
and now runs `attempt` through the policy. Replace it:

#src("workbook/ch02/step7/transport.go", region: "do")

This is the line that step 4 put in the right place: the key is generated
_before_ `policy.Do`, so every attempt sends the same one, and the server
creates one deployment however many attempts it takes. `OnRetry` logs each
retry at `WARN` and then calls the caller's own hook, if the policy had one.

`attempt` classifies each failure in the vocabulary of `retry`. Replace it:

#src("workbook/ch02/step7/transport.go", region: "attempt")

Read it as the table above, in code. Before every attempt, retries included,
it waits for the limiter. Retries that bypass a rate limit turn a partial
outage into a retry storm, the same argument Chapter 4 makes for `sweep`.

=== Optional interfaces: growing without breaking implementers

Interfaces that callers implement still need to evolve. Six months after the
first release, the identity team starts rotating credentials hourly. A
`TokenSource` that caches tokens will keep sending a revoked one until its
cache expires, and every call fails with 401 in the meantime. The client
needs a way to say "that token was rejected". Adding a method to
`TokenSource` would break every implementation. The standard library's
answer is the _optional interface_: a second interface that a value _may_
implement, which the consumer checks at run time. Add it at the end of
`token.go`:

#src("workbook/ch02/step7/token.go", region: "invalidator")

#goconcept(title: [Type assertions])[
  A _type assertion_ asks an interface value what is inside it. `x.(T)`
  with a concrete type `T` extracts the value; with an interface type `T`,
  it asks whether the value inside `x` _also_ has `T`'s methods:

  #code(file: "sketch")[```go
  inv, ok := c.tokens.(TokenInvalidator)
  if ok {
  	inv.InvalidateToken(token) // the source can do more than Token
  }
  ```]

  The two-result form never panics: `ok` is false when the value doesn't
  have the methods. The one-result form, `inv := c.tokens.(TokenInvalidator)`,
  panics instead, so use it only when a failure would be a bug. A _type
  switch_, `switch v := x.(type) { case *APIError: ... }`, tests several
  types in turn. For errors, prefer `errors.AsType`, which also looks
  inside wrapped errors; a plain assertion sees only the outermost one.
]

`http.Flusher`, `io.WriterTo` and `io.ReaderFrom` all work this way:
`io.Copy` asserts its arguments to the last two and skips its own buffer
when it can. The client uses `TokenInvalidator` on a 401: it invalidates
the rejected token and tries once more. Replace `send` with two functions:

#src("workbook/ch02/step7/transport.go", region: "send")
#needspace(10em)
#src("workbook/ch02/step7/transport.go", region: "sendonce")

Two details matter. `InvalidateToken` receives the _rejected_ token, so a
caching source can ignore the call if it has already refreshed: under load,
ten requests may fail with the same old token, and only the first should
evict anything. And the second attempt happens once, outside the retry
policy. A second 401 means the new token is bad too, and retrying again
would only hammer the identity provider. A failure to get a token at all is
`Permanent` for the same reason.

The `retry` log line reports API errors by status. Add `errAttr` after
`decodeError`:

#src("workbook/ch02/step7/transport.go", region: "errattr")

#warning(title: [Wrappers hide optional interfaces])[
  An optional interface is only visible on the value you assert against. If
  a caller wraps their `TokenSource` in another type, say one that counts
  calls for metrics, or converts its `Token` method to a `TokenSourceFunc`,
  the wrapper doesn't have `InvalidateToken`, and the upgrade silently stops
  working; the checkpoint shows the failing test. HTTP middleware that wraps
  `http.ResponseWriter` hits the same problem with `http.Flusher`, which is
  why Go 1.20 added `http.ResponseController`: it follows `Unwrap` methods
  to find the original writer. Document optional interfaces next to the
  interface they extend, as `TokenInvalidator`'s comment does, so that
  wrapper authors know to forward them.
]

#needspace(10em)
Last, mark the two `POST`s. In `api.go`, replace `CreateDeployment`:

#src("workbook/ch02/step7/api.go", region: "create")

and `CancelDeployment`:

#src("workbook/ch02/step7/api.go", region: "cancel")

=== The fake learns to fail

Tests need failures on demand. Replace the import block of
`platformapifake/fake.go`:

#src("workbook/ch02/step7/platformapifake/fake.go", region: "imports")

Replace the `Server` type, adding a queue of injected failures:

#src("workbook/ch02/step7/platformapifake/fake.go", region: "server")

Add `FailNext` after `RequireToken`, which stays as it is:

#src("workbook/ch02/step7/platformapifake/fake.go", region: "failnext")

#needspace(10em)
and replace `ServeHTTP`:

#src("workbook/ch02/step7/platformapifake/fake.go", region: "serve")

An injected failure is consumed by the next request, whatever it is, and is
answered before the request reaches the API handlers, the way a proxy in
front of a real server fails.

=== Tests in virtual time

Retries sleep, so these tests run in `synctest` bubbles and assert exact
durations. Create `retry_test.go`:

#src("workbook/ch02/step7/retry_test.go", region: "head")

The test this whole chapter has been building towards: two 503s, then
success, one key.

#src("workbook/ch02/step7/retry_test.go", region: "retrytest")

The next test asserts that a retry after a 429 happened after _exactly_
seven seconds. In virtual time that assertion is deterministic, and the test
still finishes in microseconds:

#src("workbook/ch02/step7/retry_test.go", region: "retryafter")

Permanent errors and an exhausted budget:

#src("workbook/ch02/step7/retry_test.go", region: "permanent")

A token source that caches, and implements the optional interface. It is a
test helper here; exercise 2.5 turns it into a real one:

#src("workbook/ch02/step7/retry_test.go", region: "caching")

`TestRejectedTokenIsRefreshedOnce` rotates the fake's accepted token
mid-test and checks both behaviours: one invalidation, and only one refresh
when the new token is rejected too. The last test checks that the limiter
sees every attempt:

#src("workbook/ch02/step7/retry_test.go", region: "rotation")

#needspace(12em)
#checkpoint(step: 7, of: 8, title: [Retries])[
  #output("ch02/s7-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch02/s7-test.txt", cmd: "go vet ./... && go test ./...")
  The four tests that sleep, between them for more than ten seconds of
  virtual time:
  #output("ch02/s7-synctest.txt", cmd: "go test -v -run 'TestRetries|TestRetryAfter|TestLimiterGates' . 2>&1 | grep -E '^(=== RUN|--- |ok)'")
  #troubleshoot(
    ([#ts("s7-notidem.txt")], [`CreateDeployment` doesn't set `r.idempotent`, so the `POST` is never retried and the first 503 reaches the caller.], [Mark requests that carry a key, or are idempotent by nature.]),
    ([#ts("s7-keyperattempt.txt")], [The idempotency key is generated per attempt (in `sendOnce`), so each retry looks like a new deployment to the server.], [Generate it once per call, in `do`, before `policy.Do`.]),
    ([#ts("s7-all.txt")], [`attempt` returns every error as retryable, including a 404.], [Wrap permanent failures in `retry.Permanent`. See the table in "What may be retried".]),
    ([#ts("s7-wrapper.txt")], [The token source was wrapped (here in a `TokenSourceFunc`), hiding its `InvalidateToken` method.], [Pass the source itself, or forward the optional method. See "Wrappers hide optional interfaces".]),
  )
]

#step(8, 8, "Documentation, examples and a tour", label: <sec-api-s8>)

The SDK works. This step makes it _usable_ by someone who has never seen
its source: a package comment, runnable examples that `go test` checks, a
fake whose documentation stands on its own, and a small program that shows
everything working together.

=== Names and the public surface

A package name is part of every identifier a caller writes. `platformapi`
is short, says what the package talks to, and reads well in use:
`platformapi.New`, `platformapi.Client`, `platformapi.ErrNotFound`. Avoid
stutter (`platformapi.PlatformAPIClient`) and avoid names that describe
shape rather than content: `client`, `sdk`, `common`, `utils`, `models`.

The exported surface is one constructor, eight client options, three call
options, eleven methods, `Collect`, the resource and request types, two
error types and two sentinels. Everything else, including the request
struct, the call options' storage, the wire type `page[T]`, and the whole
transport, is unexported. Every unexported name is one the platform team can
rename, split or delete without a release note. When you are unsure whether
something should be public, leave it private. Exporting it later is a
compatible change, and the reverse never is.

=== `internal/` and import cycles

`internal/` directories are the module-level version of lowercase names.
The `go` command refuses to let a package import
`platformapi/internal/wire` unless it lives under `platformapi/`. If the SDK
grows an admin client in a sibling package that shares wire types and
request signing with the main one, that shared code goes in
`platformapi/internal/`. It isn't there today because nothing shares it
yet: `internal` is for code with more than one user inside the module and
none outside it.

@fig-api-packages shows the import graph. Two choices keep it acyclic. The
fake doesn't import the SDK, for the reason step 1 gave. And the SDK's
tests live in the external test package `platformapi_test`, which can import
the fake without creating a cycle, even if the fake one day imports the SDK
for convenience. External tests also see only the exported API, so they
double as a check that the public surface is usable.

#fig(placement: auto, caption: [Import graph. The fake shares no code with the SDK, and the SDK's tests import both from outside, as a consumer would.])[
  #diagram(
    spacing: (30pt, 22pt),
    dnode((0, 0), [`examples/promote`\ (like `ship`)], kind: "default"),
    dnode((1, 0), [`platformapi_test`\ external tests + examples], kind: "muted"),
    dnode((2, 0), [`examples/tour`], kind: "default"),
    dnode((0, 1), [`platformapi`], kind: "dark"),
    dnode((2, 1), [`platformapifake`\ own wire types], kind: "good"),
    dnode((0, 2), [`platformapi/retry`\ (`pkg/retry`, Chapter 4)], kind: "accent"),
    dnode((1, 2), [standard library\ `net/http` · `iter` · `uuid`], kind: "muted"),
    dedge((0, 0), (0, 1), "-|>"),
    dedge((1, 0), (0, 1), "-|>"),
    dedge((1, 0), (2, 1), "-|>"),
    dedge((2, 0), (0, 1), "-|>"),
    dedge((2, 0), (2, 1), "-|>"),
    dedge((0, 1), (0, 2), "-|>"),
    dedge((0, 1), (1, 2), "-|>"),
    dedge((2, 1), (1, 2), "-|>"),
  )
] <fig-api-packages>

=== Doc comments are the manual

For most users, the output of `go doc` _is_ the documentation, and editors
show the same text on hover. The package comment comes first. Create
`doc.go`, a file that holds nothing but the package comment:

#src("workbook/ch02/step8/doc.go", region: "doc")

A few conventions make doc comments work. Start each one with the name it
documents ("Wait polls op until..."), because `go doc` and search results
show the first sentence on its own. Document what the caller can't see:
that `Wait` returns the final state _together with_ an `*OperationError`
when a rollout fails, that cancelling a context doesn't cancel a
deployment, that the zero `Client` isn't usable. Square brackets create doc
links (Go 1.19): `[Client.Wait]` and `[errors.Is]` become hyperlinks on
pkg.go.dev and in gopls, and plain text in the terminal. An indented block
is shown as code. `go doc . Client.Wait` prints a single method's
documentation, and it keeps the source's line breaks in the signature, one
more reason to wrap long signatures by hand.

=== A fake for every consumer

`platformapifake` is a package other teams import, not a test helper hidden
in the SDK's test files. Every consumer of the SDK needs to test their own
code against something, and if the platform team doesn't ship a fake, 50
teams will write 50 mocks of varying accuracy. Its package comment says how
to use it. Replace the top of `platformapifake/fake.go`, down to the end of
the import block:

#src("workbook/ch02/step8/platformapifake/fake.go", region: "imports")

Because the fake is an `http.Handler`, callers choose how to serve it:
`httptest.NewTestServer` in a `synctest` bubble, `httptest.NewServer` in an
ordinary test, or a real `http.Server` for a local demo.

=== Examples that cannot rot

#goconcept(title: [Testable examples])[
  A function in a `_test.go` file whose name starts with `Example` is
  documentation and a test at once. `Example` documents the package,
  `ExampleAPIError` the type `APIError`, and `ExampleClient_ListDeployments`
  the method `Client.ListDeployments`; `go doc` and pkg.go.dev attach each
  one to its identifier. If it ends with an `// Output:` comment, `go test`
  runs it, captures what it prints, and fails when the output differs. An
  example without that comment is compiled but not run. `go vet` checks
  that the name refers to something that exists.
]

Create `example_test.go`. It is in the external test package, like the
tests, so the examples show code a user can copy:

#src("workbook/ch02/step8/example_test.go", region: "head")

The package example is the whole happy path:

#src("workbook/ch02/step8/example_test.go", region: "example")

Because the fake is deterministic, the examples can show real IDs and real
output, and they stay correct as long as the tests pass. Prose in a README
goes stale without anyone noticing. A runnable example fails CI the day it
goes stale. The list example shows the loop with `break`:

#src("workbook/ch02/step8/example_test.go", region: "examplelist")

`Poll` and `*APIError` get one each:

#src("workbook/ch02/step8/example_test.go", region: "poll")
#src("workbook/ch02/step8/example_test.go", region: "apierror")

`RequestID("req-1234")` makes the request ID predictable, so the output can
include it.

#newingo("1.27", title: [`go doc` shows examples])[
  `go doc -ex` lists the executable examples for a package or symbol, and
  passing an example's name prints its source as a complete program, ready
  to paste, followed by its expected output. `go doc` also accepts
  `package@version`, so `go doc example.com/pkg@v1.2.3` shows the
  documentation of a release you haven't upgraded to yet.
]

=== A tour

Examples show one thing each. A small program that runs four scenarios
against the fake shows the SDK as a whole, and makes the behaviour of
retries and errors visible in a terminal. Make a directory `examples/tour`
and create `examples/tour/main.go`:

#src("workbook/ch02/step8/examples/tour/main.go", region: "head")

`signal.NotifyContext` gives `run` a context that #kbd("Ctrl-C") cancels,
and `os.Exit` runs only after `stop`, because deferred calls don't run
when a program exits. `run` serves a fresh fake for each scenario and
builds a client that logs to the same writer as the scenario's output:

#src("workbook/ch02/step8/examples/tour/main.go", region: "run")

The `ReplaceAttr` hook drops the time and the request ID from log lines, so
the output stays short and the same from run to run. Then the four
scenarios. `pages` lists five deployments, three per page:

#src("workbook/ch02/step8/examples/tour/main.go", region: "pages")

`deploy` starts a rollout, follows it with `Poll`, and copies the log stream
line by line; this is the output you saw at the start of the chapter:

#src("workbook/ch02/step8/examples/tour/main.go", region: "deploy")

`flaky` injects two 503s and a 429 with `Retry-After: 1`, creates a
deployment, prints what the server saw, and then creates a deployment twice
with the same caller-chosen key. A helper shortens the IDs:

#src("workbook/ch02/step8/examples/tour/main.go", region: "short")
#src("workbook/ch02/step8/examples/tour/main.go", region: "flaky")

`errors` walks through the four ways a call can fail: not found, a
conflict, a wait that times out, and a rollout that fails:

#src("workbook/ch02/step8/examples/tour/main.go", region: "errors")

`run` takes an `io.Writer` rather than printing to `os.Stdout`, so a test
can capture the output. Create `examples/tour/main_test.go`:

#src("workbook/ch02/step8/examples/tour/main_test.go")

#needspace(12em)
#checkpoint(step: 8, of: 8, title: [Documentation, examples and a tour])[
  #output("ch02/s8-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch02/s8-test.txt", cmd: "go vet ./... && go test ./...")
  The package as its users meet it:
  #output("ch02/s8-godoc.txt", cmd: "go doc .")
  An example, as a complete program:
  #output("ch02/s8-example.txt", cmd: "go doc . ExampleAPIError")
  The fake's API:
  #output("ch02/s8-fake.txt", cmd: "go doc ./platformapifake Server")
  Now run the tour. Pages are fetched on demand, and `break` stops the
  second page short:
  #output("ch02/s8-tour-pages.txt", cmd: "go run ./examples/tour pages")
  Retries, as the server saw them. The waits before the first two retries
  are drawn at random below ceilings of 200 ms and 400 ms, so they differ
  on every run. The third is exactly one second, because the server asked
  for it. Four `POST`s carried the same request ID and idempotency key, and
  created one operation. The last line is the cross-process case: a CI job
  that crashed and re-ran its step passes its own key and gets the same
  operation back.
  #output("ch02/s8-tour-flaky.txt", cmd: "go run ./examples/tour flaky")
  And failures. The timeout line shows the wait giving up while the
  deployment carries on, exactly as `Poll`'s documentation promises:
  #output("ch02/s8-tour-errors.txt", cmd: "go run ./examples/tour errors")
  #troubleshoot(
    ([#ts("s8-output.txt")], [An example's output doesn't match its `// Output:` comment. Here the comment is wrong, which is how examples catch stale docs.], [Fix whichever side is wrong; never delete the comment to make the test pass.]),
    ([#ts("s8-exname.txt")], [An example's name refers to a method that doesn't exist (renamed, or a typo).], [Name it `Example<Type>_<Method>` after a real identifier.]),
    ([#ts("s8-usage.txt")], [The tour ran without a scenario.], [`go run ./examples/tour deploy`.]),
  )
]

== Lab: evolving the API <sec-api-evolve>

The SDK is ready for its `v1.0.0` tag. From then on, every change is
judged by one question: does code that compiled against the last release
still compile, and still behave the same? This lab teaches you to answer
it, first by reading the rules, then by letting a tool apply them.

Most changes to a Go API are either clearly safe or clearly breaking, and
the dangerous ones are those that look safe. This table is the checklist
the platform team reviews SDK changes against:

#table(
  columns: (1fr, auto, 1.25fr),
  align: (left, center, left),
  table.header([Change], [Safe?], [Why]),
  [Add a function, type, constant, or a method on a concrete type], [yes], [Nothing that compiled before refers to it.],
  [Add a struct field], [usually], [Breaks unkeyed literals (`Deployment{"d-1", ...}`), and breaks `==` if the new field is a map, slice or func.],
  [Add a method to an interface], [no], [Every implementation stops compiling.],
  [Add a parameter, even a variadic one], [no], [Calls still compile, but function values, interface satisfaction and method expressions don't.],
  [Change a constant's value], [no], [Code that stored or compared the old value now behaves differently.],
  [Change a field's or parameter's type, or remove anything], [no], [Obvious, and still the most common accident.],
  [Change behaviour (defaults, retry rules, errors returned)], [depends], [No tool can see it. Tests and release notes must.],
)

The variadic row is the one that surprises people, and step 4 explained
why every method in `platformapi` has had `opts ...CallOption` since before
there was a call option to pass.

=== Two versions of an API

Reviewers miss these things, so let a tool check them. `apidiff`, from
`golang.org/x/exp`, compares two versions of a package's exported API and
sorts the differences into compatible and incompatible. To try it, you need
two versions of an API. Make a directory `evolve/before` and create
`evolve/before/platform.go`, a plausible first release of a small deployment
API:

#src("workbook/ch02/step9/evolve/before/platform.go")

Then `evolve/after/platform.go`, what the same package might look like a
year later, after changes from several contributors:

#src("workbook/ch02/step9/evolve/after/platform.go")

Before you run anything, read the two files side by side and write down
which changes you think break callers. Then install `apidiff` and ask it:

#session(
  ("go install golang.org/x/exp/cmd/apidiff@" + "v0.0.0-20261014143641-f0251eb4aa3e", "ch02/s9-install.txt"),
  ("apidiff ./evolve/before ./evolve/after | fold -s -w 86", "ch02/s9-apidiff.txt"),
)

`golang.org/x/exp` has no releases, so the version is a pseudo-version: the
commit the book was tested with. `@latest` works too. `fold` wraps the long
lines for the page.

Every incompatible line is a row of the table. `CreateDeployment` and
`NewClient` gained variadic parameters. `DefaultPollInterval` changed value,
so code that used it as a deadline now waits longer. `Status` was renamed to
`State` with a new type. `TokenSource` gained a method, where an optional
interface like step 7's `TokenInvalidator` would have been compatible. And
`Deployment` gained a `Labels map[string]string` field, which no reviewer
would flag but which makes the struct non-comparable: any consumer that
wrote `if old == cur` or used a `Deployment` as a map key no longer
compiles.

=== Guarding a release

In CI, run `apidiff` against the last release on every pull request that
touches the SDK. `apidiff -w` writes the API of a package to a file, and
the same command with the file as its first argument compares the working
tree against it. Try it on your SDK: record its API, then compare the
unchanged tree with the record.

#session(
  ("apidiff -w platformapi-v1.api .", "ch02/s9-write.txt"),
  ("apidiff platformapi-v1.api .", "ch02/s9-same.txt"),
)

No output means no changes. In a real pipeline, the first command runs
against a checkout of the last `v1.*` tag, and the build fails on any
incompatible change unless the module path has moved to a new major
version. `gorelease`, also in `golang.org/x/exp`, wraps the same analysis
around module versions and suggests the next semantic version number for a
release. Exercise 2.3 hands you seven proposed changes to the finished SDK
to judge before `apidiff` does.

=== Deprecation

When an API has to go, deprecate it first and remove it in the next major
version, if ever. A paragraph starting with `Deprecated:` in the doc comment
is the convention every Go tool understands, and `after` uses it on
`ListDeployments`, which `Deployments` replaces.

Staticcheck's SA1019 check, which runs in `golangci-lint`'s default set,
reports uses of deprecated identifiers from other modules, so consumers find
out at their next lint run while the SDK's own tests can keep exercising the
old function. gopls renders deprecated names with a strikethrough, and
pkg.go.dev collapses them in its index. Say what to use instead, keep the
deprecated function working (ideally by implementing it in terms of its
replacement), and use the User-Agent data from step 2 to see when its last
caller is gone.

=== When you really must break it: `/v2`

Some changes can't be made compatibly, such as a different error model or a
different authentication scheme. Go's answer is a new major version with a
new module path, `github.com/acme/platformapi/v2`. Both versions can be
imported in the same build, because they are different packages, so
consumers can migrate one call site at a time. The cheapest way to maintain
both is to reimplement v1 as a thin layer over v2, so bug fixes land once.
Type aliases (`type Deployment = v2.Deployment`) make shared types
identical across the two.

#warning(title: [Your `go` line is API too])[
  The `go` directive in the SDK's `go.mod` is a minimum toolchain for every
  consumer. When `platformapi` started using generic methods in step 4 it
  required Go 1.27, and every module that imports it now needs a Go 1.27
  toolchain to build. Raise the `go` line deliberately and announce it like
  any other breaking change. From Go 1.27, `go test` runs vet's
  `stdversion` check by default, which reports uses of standard library
  symbols that are newer than the `go` line allows, so an SDK can't raise
  its effective minimum by accident.
]

#needspace(12em)
#checkpoint(title: [Lab: evolving the API])[
  The lab added two packages and no tests:
  #output("ch02/s9-tree.txt", cmd: "find ./evolve -name '*.go' | sort")
  Everything still passes, now under the race detector too. This module is
  the same code as the book repository's `pkg/platformapi`:
  #output("ch02/s9-test.txt", cmd: "go test -race ./...")
  #troubleshoot(
    ([#ts("s9-noversion.txt")], [`go install` was given a package path without a version, so it looked for the package in your module's dependencies.], [Add `@latest` or the pseudo-version.]),
    ([#ts("s9-outside.txt")], [`apidiff` ran outside the module, so the relative paths match nothing.], [Run it from the directory that holds `go.mod`.]),
  )
]

== Interfaces as design patterns <sec-api-patterns>

You have now written or used every common interface pattern a platform
tool needs, most of them without naming them. Pattern books describe these
with class hierarchies. In Go, each one is a small interface plus a type
that has the right methods, and the names are worth knowing because
reviewers and interviewers use them.

#table(
  columns: (auto, 1.5fr, 1.2fr),
  align: (left, left, left),
  table.header([Pattern], [What it means in Go], [In this chapter]),
  [Strategy], [The caller passes in a behaviour as an interface value or a function, and the code calls it without knowing which one it got.], [`TokenSource`, `Limiter`, `retry.Policy.Retryable`],
  [Adapter], [A type, often a function type or a struct that embeds another, makes an existing value fit an interface.], [`TokenSourceFunc`, `http.HandlerFunc`, `promote.Client`],
  [Decorator], [A value wraps another value of the same interface and adds behaviour around each call.], [`http.StripPrefix`, `bufio.Scanner` over `io.Reader`, the transport sketch below],
  [Optional interface], [A second interface that a value may implement, discovered with a type assertion.], [`TokenInvalidator`, `io.WriterTo`],
  [Null object], [A value that satisfies the interface and does nothing, so callers never check for `nil`.], [`slog.DiscardHandler`],
  [Fake], [A working, in-memory implementation of an external dependency.], [`platformapifake.Server`, an `http.Handler`],
)

The decorator is the one this chapter used least directly, and it is the
SDK's most powerful extension point. `http.Client` sends every request
through its `Transport`, an `http.RoundTripper`:

#code(file: "net/http (standard library)")[```go
type RoundTripper interface {
	RoundTrip(*http.Request) (*http.Response, error)
}
```]

A type that has that method and holds another `RoundTripper` can do
anything around each request: count it, time it, add a header, record a
trace span. Here is a sketch of one that counts requests by status, for a
metrics dashboard:

#code(file: "sketch")[```go
type counting struct {
	next   http.RoundTripper
	counts *sync.Map // status code -> *atomic.Int64
}

func (c counting) RoundTrip(r *http.Request) (*http.Response, error) {
	resp, err := c.next.RoundTrip(r)
	if err == nil {
		n, _ := c.counts.LoadOrStore(resp.StatusCode, new(atomic.Int64))
		n.(*atomic.Int64).Add(1)
	}
	return resp, err
}

hc := &http.Client{Transport: counting{next: http.DefaultTransport,
	counts: &sync.Map{}}}
client, err := platformapi.New(url, platformapi.WithHTTPClient(hc))
```]

The SDK never learns that the decorator exists, and it doesn't have to:
`WithHTTPClient` accepts any `*http.Client`, and the client accepts any
`RoundTripper`. This is how OpenTelemetry's `otelhttp.NewTransport`
(Chapter 17) adds tracing to every SDK built on `net/http`, without any of
them importing it. Decorators stack, too: wrap the counting transport in a
tracing one, and both run. Exercise 2.4 compares this approach with a
callback option built into the SDK.

The common thread is the rule from step 1: _the consumer owns the
interface_. `promote` declared `Platform` because it needed three methods.
`http.Client` declares `RoundTripper` because it needs one. The SDK declares
`TokenSource` and `Limiter` because it consumes them, and exports no
interface for what it _provides_. When you reach for an interface, ask who
calls the methods. That code is where the interface belongs, and it should
list only the methods that code calls.

== SDKs at scale <sec-api-scale>

Everything in this chapter gets more important as the number of consumers
grows. A few practices matter most once the SDK runs in hundreds of
processes.

*One client per process.* The `http.Client` pools connections and the
`Limiter` holds the rate budget, so both only work if they are shared. A
program that builds a new `Client` per request opens a new TLS connection
per request and gives each request its own fresh rate budget, which means
no limit at all. The package comment says to share one client, and the
`Client` doc comment says it is safe for concurrent use. An SDK needs to
say both, because neither is obvious from the type.

*Retries, idempotency and rate limits are one design.* Retries without
idempotency keys duplicate writes. Retries outside the rate limiter amplify
outages. Retries that ignore `Retry-After` hammer a server that has said
exactly how long to wait. The SDK makes all three decisions once, so 50
teams don't make them 50 different ways. Chapter 15 adds retry budgets and
circuit breakers on top.

*Observability without dependencies.* The SDK logs through any
`*slog.Logger`, identifies itself in the User-Agent, gives every call a
request ID that appears in both the client's errors and the server's logs,
and accepts an `*http.Client`, which is the hook for decorators like the
one above. None of this requires the SDK to import a metrics or tracing
library, so it never forces a version of one on its consumers.

*Wire compatibility runs in both directions.* The server will add fields to
its responses. `encoding/json` ignores unknown fields by default, and the
SDK must not turn on `DisallowUnknownFields`, or every server release
becomes a client outage. The server will also add enum values, which is why
`DeploymentState` tells callers to treat unknown states as unfinished. In
the other direction, the server must accept requests from SDK versions that
are a year old, and the User-Agent tells it how old they really are.

#production(title: [Publish a support window])[
  "Every SDK version is supported forever" is a promise nobody keeps. Write
  down a real one, for example: the platform API accepts requests from SDK
  versions released in the last 12 months, deprecated SDK functions keep
  working for two minor releases after the deprecation is announced, and a
  `/v2` gets security fixes for 6 months after `/v3` ships. Back it with
  data: a dashboard of requests by User-Agent version shows which teams to
  contact before an old version stops working. At 50 consuming teams, the
  dashboard and the window are what keep "upgrade the SDK" a routine
  ticket rather than a negotiation.
]

#interview(title: [“Walk me through an API or SDK you designed.”])[
  Lead with the consumers and the constraint: "50 teams import it, and a
  breaking change costs each of them a release." Then walk the decisions as
  trade-offs. Concrete `*Client` with consumer-defined interfaces, so
  methods can be added. Functional options with validation in `New`,
  because the option list grows and defaults must be able to change.
  Context first everywhere, because any call can become slow. Retries with
  idempotency keys generated once per call, and a classification table for
  what is retryable. Iterators for pagination, so `break` stops the
  requests. Name one decision you would revisit and why, then finish with
  how you protect the API over time: runnable examples, a fake for
  consumers, `apidiff` in CI, deprecation before removal, and a User-Agent
  that tells you who still calls what.
]

#takeaways(
  [Count the cost of a breaking change in consumer releases, not in your own diff. Under minimal version selection, consumers get your newest minor version whether they asked for it or not.],
  [An interface is a set of methods, satisfied implicitly by any type that has them. Keep interfaces small and declare them where they are used.],
  [Return concrete types and let consumers declare small interfaces. Interfaces the SDK _consumes_ (`TokenSource`, `Limiter`) belong in the SDK, take a context, and have one method.],
  [Grow interfaces with optional interfaces checked by type assertion, never by adding methods to an interface others implement.],
  [Required settings are parameters; everything else is a validated functional option over an unexported config, so a built client can't be reconfigured. Constructors do no I/O.],
  [Every method takes a context and the client stores none. Cancelling a wait doesn't cancel the server-side work; document that and give callers a way to cancel it.],
  [Generate idempotency keys and request IDs once per call, outside the retry loop. Classify every status as retryable or permanent, and honour `Retry-After`.],
  [Paginate with `iter.Seq2[T, error]`: lazy, constant memory, and `break` stops the requests.],
  [Use generics to move values around (decode, page, poll, collect). Go 1.27 generic methods fit helpers on concrete types, but they can't satisfy interfaces, so keep core methods non-generic.],
  [Treat docs and examples as API: `// Output:` examples, a published fake, `// Deprecated:` paragraphs, and `apidiff` in CI against the last release.],
)

#exercise-set(2,
  (
    tier: "warm-up",
    title: [Two more sentinels],
    body: [
      Callers keep writing `apiErr.StatusCode == 401` and
      `apiErr.StatusCode == 429`. Add `ErrUnauthorized` and
      `ErrRateLimited` so they can use `errors.Is` instead. Make sure
      `errors.Is(err, platformapi.ErrRateLimited)` still works when the
      SDK gave up after retrying a 429 and returned a
      `*retry.ExhaustedError`.
    ],
    hint: [Step 3's `Is` method is the only place that needs to know.],
    tests: "workbook/ch02/exercises/ex1",
  ),
  (
    tier: "warm-up",
    title: [`Take`],
    body: [
      Write `Take[T any](seq iter.Seq2[T, error], n int) iter.Seq2[T, error]`,
      which yields at most the first `n` items of `seq`. `Take` of a
      paginated list must fetch no page it doesn't need, and `Take(seq, 0)`
      must send no request at all.
    ],
    hint: [Range over `seq` inside your iterator, and return as soon as you have yielded `n` items or `yield` returns `false`.],
    tests: "workbook/ch02/exercises/ex2",
  ),
  (
    tier: "warm-up",
    title: [Judge seven changes],
    body: [
      A pull request proposes seven changes to the finished SDK: add
      `Labels map[string]string` to `Environment`, fix the spelling of
      `StateCancelled`'s value to `"canceled"`, change `PageSize` to take
      an `int32`, add `Tokens() float64` to `Limiter`, add a `String`
      method to `TokenSourceFunc`, add a `GetOperation` method to
      `Client`, and add `Labels` to `Operation[T]`. For each, decide
      whether it is compatible and why. Then make the changes in a copy
      of step 9 and check your answers with `apidiff`.
    ],
  ),
  (
    tier: "core",
    title: [Observe every attempt],
    body: [
      Add an option `WithObserver(f func(Attempt))` that calls `f` after
      every attempt, retries included, with the call (`"GET /v1/environments/dev"`), the attempt number, the HTTP status (0 if
      no response arrived), the request ID, the duration and the error.
      `WithObserver(nil)` is a configuration error. Then compare this
      design with documenting an `http.RoundTripper` decorator, like the
      one in "Interfaces as design patterns". Which survives better if
      the platform later moves to gRPC?
    ],
    tests: "workbook/ch02/exercises/ex4",
  ),
  (
    tier: "core",
    title: [A caching token source],
    body: [
      Implement `CachingTokenSource`, built by
      `NewCachingTokenSource(fetch)` where `fetch` returns a token and its
      expiry time. It caches the token until one minute before expiry,
      makes concurrent callers share a single fetch, lets each waiting
      caller give up when its own context ends, and implements
      `TokenInvalidator`, ignoring invalidations of tokens it has already
      replaced. A failed fetch must not be cached.
    ],
    hint: [Chapter 4 does this with `singleflight`; a mutex and a channel that is closed when the fetch ends are enough here.],
    tests: "workbook/ch02/exercises/ex5",
  ),
  (
    tier: "core",
    title: [Review an interface],
    body: [
      A team proposes adding this to `platformapi`, "so that everyone can
      mock the client": an exported `PlatformClient` interface listing all
      eleven methods of `*Client`, with `New` changed to return it. Write
      the review. Name what breaks now, what breaks the next time the
      platform team adds a method, and what the team should do instead to
      test their own code. Use `promote` as your example.
    ],
  ),
  (
    tier: "stretch",
    title: [Wait for many],
    body: [
      A release train deploys five services at once and waits for all of
      them. Add a generic method
      `WaitAll[T any](ctx, ops []*Operation[T], limit int, opts ...CallOption) ([]*T, error)`
      that follows at most `limit` operations at a time (fewer than 1
      means all at once), returns the final state of each in the order of
      `ops`, and joins the errors of every operation that failed. One
      failure must not stop the others, no goroutine may outlive the call,
      and cancelling `ctx` ends it promptly.
    ],
    hint: [`sync.WaitGroup.Go` (Go 1.25) and a buffered channel used as a semaphore. Chapter 4 explains both; the tests run in virtual time and check the total duration exactly.],
    tests: "workbook/ch02/exercises/ex7",
  ),
)
