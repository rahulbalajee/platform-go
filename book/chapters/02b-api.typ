#import "../template/book.typ": *
#import "02-lib.typ": ts, needspace

#step(4, 8, "Every call identified", label: <sec-api-s4>)

The SDK can read. This step teaches it to write: creating a deployment and
cancelling one. Writes are where the incident at the start of the chapter
happened, so before the first `POST` goes out, every call gets an identity:
a request ID that ties the client's logs to the server's, and, for creates,
an idempotency key that lets the server recognise a repeat. Both are
per-call settings, so this step also gives calls their own options.

=== Context is part of the signature

Every method that talks to the platform takes a `context.Context` as its
first parameter, including methods that look instant, like
`GetEnvironment`. Any call can become slow: the server is under load, the
client waits on the rate limiter, the token source refreshes a token, or (in
step 7) the retry policy backs off. Adding a context parameter later changes
the signature, and the lab shows that every signature change breaks
someone. So the context goes in from the start.

The context bounds the _whole_ call: the limiter wait, the token fetch, and
every attempt. A caller who wants "create this deployment, but give up after
30 seconds including retries" writes exactly that, and the SDK has no
timeout knobs of its own to conflict with it. The tests in this step check
that a token source stuck on a dead identity provider is cut off by the
caller's deadline.

The client never stores a context. It is created once and lives as long as
the process, while a context describes one operation. A context saved in a
struct either outlives its operation or gets reused for the next one. The
`oauth2` refresher from step 2 shows both failure modes: every token
refresh runs under the context captured at construction, so a request's
deadline never applies to its own refresh, and if that captured context is
ever cancelled, every later refresh fails.

Context _values_ are for request-scoped data that crosses API boundaries
without every function in between knowing about it. Trace context is the
canonical example: OpenTelemetry's HTTP instrumentation reads the span from
the request's context and propagates it in headers, which is why
`WithHTTPClient` is the SDK's tracing hook. Settings that change what a
call does are not context values. Request IDs, idempotency keys and page
sizes are explicit _call options_. They show up in `go doc` and at the call
site, and a reader can see that a call sets one. A value hidden in a context
is an invisible parameter, and invisible parameters are the hardest kind to
keep compatible.

=== Call options

Per-call settings are a separate type from client options, so passing
`WithToken` to `GetDeployment` doesn't compile. `transport.go` changes
almost completely in this step. Replace its import block (the new imports
are `bytes` and `uuid`):

#src("workbook/ch02/step4/transport.go", region: "imports")

Then delete `getJSON` and `url`, and in their place add the call options:

#src("workbook/ch02/step4/transport.go", region: "calloption")

#newingo("1.27", title: [The `uuid` package])[
  Go 1.27 adds `uuid` to the standard library. `uuid.New()` returns a random
  UUID (currently version 4), and `uuid.NewV7()` a version 7 UUID, whose
  leading 48 bits are a millisecond timestamp. Version 7 IDs sort by
  creation time, which makes them pleasant as request IDs: a log search
  sorted by ID is sorted by time. Before 1.27, SDKs imported
  `github.com/google/uuid` for the same thing.
]

Next, the internal description of a call. Add it below the call options:

#src("workbook/ch02/step4/transport.go", region: "request")

A `request` is one logical API call, built by the method that knows which
endpoint it calls. `url` now takes the request; its body is unchanged.

=== One call, one identity

Inside the client, a _call_ is the unit the caller sees, and an _attempt_ is
one HTTP exchange. Step 7 lets a call take several attempts; this step
already keeps the two apart. Add `do`:

#src("workbook/ch02/step4/transport.go", region: "do")

The request ID and the idempotency key are generated in `do`, once per
call, before any attempt. The idempotency key is what makes retrying a
`POST` safe. If the first attempt reached the server but its response was
lost to a timeout or a reset connection, a retry carries the same key, and
the server returns the operation it already started instead of starting a
second rollout. That is the incident from the start of this chapter,
prevented by one line in the right place. The request ID ties the attempts
together in the server's logs.

`attempt` makes one exchange and turns a non-2xx status into an
`*APIError`:

#src("workbook/ch02/step4/transport.go", region: "attempt")

If a proxy between the client and the platform strips the `X-Request-Id`
header from an error page, the error still carries the ID the client sent.
`send` builds the HTTP request and its headers; it is `getJSON`'s first half,
generalised to any method and body:

#src("workbook/ch02/step4/transport.go", region: "send")

`drain` and `decodeError` stay as they were. The last piece replaces
`getJSON`'s second half. Add it at the end of the file:

#src("workbook/ch02/step4/transport.go", region: "call")

#goconcept(title: [Generics and generic methods])[
  A _generic_ function or type has _type parameters_ in square brackets,
  filled in by the caller. One definition then works for many types while
  the compiler still checks every use:

  #code(file: "sketch")[```go
  func (c *Client) call[T any](ctx context.Context, r request) (T, error)

  env, err := c.call[*Environment](ctx, r) // env is an *Environment
  ```]

  `any` is the _constraint_: it allows every type, and lets the function do
  nothing with a `T` except store it, return it, and take its address,
  which is all `call` needs to hand `&out` to `json.Decode`. Compare
  `getJSON(ctx, out any, ...)`: there, any value at all could be passed,
  and passing a non-pointer failed at run time. With `call[T]`, the result
  is returned rather than filled in, so there is no pointer to forget.

  Nothing in `call`'s arguments mentions `T`, so the compiler can't infer it
  and the call site names it: `c.call[*Environment](ctx, r)`. Chapter 0
  introduced generic functions and types such as `Operation[T]` below. A
  _method_ with its own type parameter is new in Go 1.27.
]

#newingo("1.27", title: [Methods may declare type parameters])[
  A method declaration can now have its own type parameter list:
  `func (c *Client) call[T any](...)`. Until Go 1.27 a method could use the
  type parameters of a generic receiver type, but not declare its own, so a
  helper that needed both the client's configuration and a per-call type had
  to be a package-level function taking the client as an argument:
  `call[Deployment](ctx, c, r)`. The standard library uses the feature in
  `math/rand/v2`, where `(*Rand).N` now exists alongside the generic
  function `rand.N`. Step 6 shows the two restrictions that remain.
]

=== The breaking change you make now

Every method gains a final parameter, `opts ...CallOption`. Replace all of
`api.go` from the top to the end of `GetDeployment`:

#src("workbook/ch02/step4/api.go", region: "gets")

Adding a variadic parameter is a breaking change, even though every
existing call such as `client.GetService(ctx, "x")` still compiles. It
breaks `f := client.GetService` assigned to a variable of the old function
type, every interface that lists the method, and every stub that
implements one; the lab shows `apidiff` flagging it. The SDK is still v0,
so this is the moment to do it, once: from v1 on, every method has had
`opts ...CallOption` since its first release, before there was a single
call option to pass. An empty variadic parameter costs nothing and buys a
place to put the next feature.

The methods are now one line each after the ID check, and the result type
appears exactly once, as the type argument. Add the first write method:

#src("workbook/ch02/step4/api.go", region: "create")

`CreateDeployment` checks its required fields before sending anything and
reports all missing ones together, the same habit as `New`. It sets
`needsKey`, so `do` generates an idempotency key unless the caller passed
one with `IdempotencyKey`. It returns an `*Operation[Deployment]`, because
a rollout takes minutes and the API answers at once with a handle on the
work in progress. Add cancellation:

#src("workbook/ch02/step4/api.go", region: "cancel")

Add the request type at the end of `types.go`:

#src("workbook/ch02/step4/types.go", region: "create")

and create `operation.go` for the operation:

#src("workbook/ch02/step4/operation.go", region: "operation")

`Operation[T]` is a generic _type_: the same shape for every kind of
long-running work, with `Result` typed by what the operation produces. A
deployment operation's result is a `*Deployment`, with no type assertion
anywhere. It is plain data with JSON tags, so a program can store an
operation's ID in a file and come back to it; step 6 does exactly that.

=== The fake learns to deploy

The fake needs somewhere to keep operations and the idempotency keys it
has seen. Replace the `Server` type, `New` and `routes` in
`platformapifake/fake.go`:

#src("workbook/ch02/step4/platformapifake/fake.go", region: "server")

Create `platformapifake/deployments.go` with the wire types the new
endpoints use:

#src("workbook/ch02/step4/platformapifake/deployments.go", region: "types")

`operationJSON` embeds `*operation`, so `encoding/json` writes the
operation's fields at the top level and adds `result` next to them, the
shape `Operation[T]` decodes. The create handler is the longest function in
the fake, because it implements the server side of idempotency:

#src("workbook/ch02/step4/platformapifake/deployments.go", region: "create")

The order of checks is the contract. A request whose key the fake has seen
before, with the same body, gets the original operation back, marked with an
`Idempotent-Replayed` header. The same key with a _different_ body is a 422
`idempotency_mismatch`, as the IETF draft for the `Idempotency-Key` header
recommends, because silently replaying the first request would deploy the
wrong version. Only a new key gets as far as validation, the conflict check
and a new deployment. Cancellation is short:

#src("workbook/ch02/step4/platformapifake/deployments.go", region: "cancel")

#production(title: [Idempotency keys need a server-side contract])[
  A key is only as good as the server's memory of it. Document how long the
  platform keeps keys (24 hours is a common choice), what happens when a key
  arrives while the first request is still being processed (409 or
  waiting), and that a key reused with a different body is an error rather
  than a silent replay. The IETF HTTP APIs working group has a draft
  standard for the `Idempotency-Key` header that covers these cases; follow
  it rather than inventing semantics. On the client side, derive keys from
  something that is stable across restarts (a CI run ID plus the
  environment) whenever the caller has one, and fall back to random keys
  only for retries within a single process.
]

=== Tests

Create `calls_test.go`. `staging` is a request that several test files use:

#src("workbook/ch02/step4/calls_test.go", region: "head")

`id[14] == '7'` checks the version digit of a UUIDv7 without parsing it.
Contexts next:

#src("workbook/ch02/step4/calls_test.go", region: "ctx")

`TestDeadlineCoversTheTokenFetch` builds a token source that blocks until
its context ends, as a client of a dead identity provider would, and checks
that the caller's 50 ms deadline still applies. Creates:

#src("workbook/ch02/step4/calls_test.go", region: "create")

`TestIdempotencyKeyMakesCreateRepeatable` plays a CI job that crashed and
re-ran its step: it passes its own key, derived from the pipeline run, and
gets the same operation back. Then validation, conflicts and cancellation:

#src("workbook/ch02/step4/calls_test.go", region: "validate")

#needspace(12em)
#checkpoint(step: 4, of: 8, title: [Every call identified])[
  #output("ch02/s4-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch02/s4-test.txt", cmd: "go vet ./... && go test ./...")
  #output("ch02/s4-testv.txt", cmd: "go test -v -run 'TestEveryCall|TestIdempotency|TestCancelled' .")
  #troubleshoot(
    ([#ts("s4-golang.txt")], [`go.mod` says `go 1.26.0`. Generic methods need the language version 1.27, whatever toolchain you run.], [`go get go@1.27.0`. The `go` line is a promise to your users; see the lab.]),
    ([#ts("s4-infer.txt")], [`c.call(ctx, r)` without a type argument. Nothing in the arguments mentions `T`.], [Name it: `c.call[*Environment](ctx, r)`.]),
    ([#ts("s4-mixed.txt")], [A client `Option` was passed to a method. Call options and client options are different types.], [Use the call option (`RequestID`), or set it in `New`.]),
    ([#ts("s4-background.txt")], [`send` used `context.Background()` instead of `ctx`, so cancelling the caller's context no longer stops the request.], [Pass `ctx` all the way down. See "Context is part of the signature".]),
  )
]

#step(5, 8, "Pages and streams", label: <sec-api-s5>)

Every list endpoint on the platform paginates: the client sends
`page_size`, the server returns a page of `items` and an opaque
`next_page_token`, and the client sends that token back to get the next
page. An SDK has five ways to expose this, and the choice shapes every
caller's code.

#table(
  columns: (auto, 1fr, 1fr),
  align: (left, left, left),
  table.header([Design], [Caller writes], [Problems]),
  [Pages], [`ListPage(ctx, token)` in a loop, passing tokens back], [Every caller reimplements the loop, and some get the termination condition wrong.],
  [Slice of all], [`all, err := List(ctx)`], [Fetches everything even if the caller needs one item. Memory grows with the collection.],
  [Callback], [`List(ctx, func(d Deployment) error {...})`], [Inverted control flow. Stopping early needs a sentinel error. `return` inside the callback doesn't return from the caller.],
  [Channel], [`for d := range ch` plus an error channel], [Needs a goroutine, which leaks if the caller stops reading (Chapter 4). Errors travel separately from items.],
  [Iterator], [`for d, err := range List(ctx)`], [The caller must check `err` on every iteration.],
)

Since Go 1.23, the last row is the idiomatic answer.

#goconcept(title: [Iterators: range over a function])[
  `for x := range f` works when `f` is a function of type
  `func(yield func(T) bool)`, and `for k, v := range f` when it takes a
  `func(K, V) bool`. The `iter` package names these `iter.Seq[T]` and
  `iter.Seq2[K, V]`. The iterator calls `yield` once per element; the
  compiler turns the loop body into the `yield` function, which returns
  `false` when the body executes `break` or `return`:

  #code(file: "sketch")[```go
  func Count(n int) iter.Seq[int] {
  	return func(yield func(int) bool) {
  		for i := range n {
  			if !yield(i) {
  				return // the loop stopped; stop producing
  			}
  		}
  	}
  }

  for i := range Count(3) { fmt.Println(i) } // 0 1 2
  ```]

  Two rules make iterators safe. An iterator must stop when `yield` returns
  `false`; calling it again panics, and the checkpoint shows the message.
  And `break`, `return` and `continue` in the loop body work as they do in
  any loop. Python generators and JavaScript's `function*` play the same
  role; Go's version is an ordinary function, with no hidden state machine.
]

The SDK's list methods return `iter.Seq2[T, error]`: each step of the loop
yields an item or an error. `for d, err := range client.ListDeployments(ctx, f)` reads like ranging over a map, while the SDK keeps control of fetching.

=== Filters and page sizes

A list call takes a filter. Add both filter types at the end of `types.go`:

#src("workbook/ch02/step5/types.go", region: "filter")

The zero value of each filter selects everything, and a field narrows the
result only when it is set. Callers write `DeploymentFilter{}` for "all" and
`DeploymentFilter{Service: "checkout"}` for one service, without a
constructor or a list of flags, and a new field added next year keeps
meaning "no restriction" for everyone who doesn't set it.

The page size is a call option. In `transport.go`, replace the call options
(the new lines are the `pageSize` field and `PageSize`):

#src("workbook/ch02/step5/transport.go", region: "calloption")

and replace `request`, `newRequest` and `url` (the request gains a query,
and `url` encodes it):

#src("workbook/ch02/step5/transport.go", region: "request")

=== One loop for every list

All three list endpoints share one generic implementation. Create
`list.go`:

#src("workbook/ch02/step5/list.go", region: "page")

`page[T]` is the wire shape of every list response, and `list[T]` is a
second generic method: the client's configuration plus a per-collection item
type. The iterator is lazy at both ends. Calling `ListDeployments` sends
nothing; the first request goes out when the loop starts. And a page is
fetched only after the caller has consumed the previous one, so `break`
stops the requests. Nothing runs in the background, and nothing needs
cleaning up after `break`.

Errors travel with the items. A failed fetch yields one `(zero, err)` pair
and ends the iteration, so a caller that `continue`s past the error doesn't
spin forever. `q.Clone()` copies the caller's query values, because the
iterator adds `page_token` to them and must not change a map the caller
still holds; `url.Values.Clone` is another Go 1.27 addition.

For callers who do want everything in memory, add `Collect` to the same
file:

#src("workbook/ch02/step5/list.go", region: "collect")

It returns the items gathered so far along with the first error, which
suits "best effort" reports. `Collect` is an ordinary generic function: it
needs no client, so it doesn't need to be a method.

#warning(title: [An iterator is a recipe, not a result])[
  An `iter.Seq2` value holds no data. Ranging over it twice runs the whole
  pagination twice, against a collection that may have changed in between.
  If a caller needs two passes, they should `Collect` once. And because the
  context is captured when the iterator is created, don't store an iterator
  built with a request-scoped context and range over it later: by then the
  request is over, its context is cancelled, and the first fetch fails.
  Treat iterators like the calls that create them, and use them right away.
]

=== The list methods

`api.go` needs three more imports. Replace its import block:

#src("workbook/ch02/step5/api.go", region: "imports")

Then add the list methods at the end of the file:

#src("workbook/ch02/step5/api.go", region: "lists")
#src("workbook/ch02/step5/api.go", region: "listdeployments")

The doc comment of `ListDeployments` contains the loop a caller should
write. An indented block in a doc comment is shown as code by `go doc` and
pkg.go.dev, so the first thing a user sees is how to use the method, error
check included.

=== Readers and writers

The rollout log of a deployment can be megabytes. Add `DeploymentLogs` at
the end of `api.go`:

#src("workbook/ch02/step5/api.go", region: "logs")

It returns the response body itself, an `io.ReadCloser`, rather than a
`[]byte` or a `[]string` of lines.

#goconcept(title: [`io.Reader` and `io.Writer` compose])[
  `io.Reader` has one method, `Read(p []byte) (n int, err error)`, and
  `io.Writer` one, `Write(p []byte) (n int, err error)`. Files, network
  connections, HTTP bodies, buffers, compressors and hashes implement them,
  so code written against the interfaces works with all of them, and
  wrappers stack: `bufio.NewScanner(r)` reads lines from any reader,
  `gzip.NewWriter(w)` compresses into any writer, `io.TeeReader(r, w)`
  copies everything read from `r` into `w`, and `io.Copy(w, r)` connects the
  two in constant memory. `io.ReadCloser` is a reader with a `Close` method,
  built by _embedding_ the two interfaces: `type ReadCloser interface { Reader; Closer }`. Interfaces embed the same way structs do.
]

A CI job can `io.Copy` the log into a file, pipe it through
`gzip.NewWriter`, or `io.TeeReader` it to two places, all in constant
memory, and the SDK had to anticipate none of it. `io.Reader` and
`io.Writer` are the most successful interfaces in Go because they are one
method each and every package agrees on them. The cost of returning a
stream is that the caller must close it, and the doc comment says so.

=== The fake learns to paginate

Replace the import block of `platformapifake/resources.go`:

#src("workbook/ch02/step5/platformapifake/resources.go", region: "imports")

and add, at the end of the file, a generic pagination helper:

#src("workbook/ch02/step5/platformapifake/resources.go", region: "paginate")

The token is opaque on purpose. If clients could read an offset out of it,
some would start constructing tokens, and the server could never change how
it paginates (a cursor on `created_at` would survive concurrent inserts
better than an offset does). Base64 doesn't hide anything from a
determined reader, but it makes clear that the token is not meant to be
read. Then the list handlers:

#src("workbook/ch02/step5/platformapifake/resources.go", region: "lists")

and the log handler:

#src("workbook/ch02/step5/platformapifake/resources.go", region: "logs")

In `platformapifake/fake.go`, replace `routes`:

#src("workbook/ch02/step5/platformapifake/fake.go", region: "routes")

=== Tests

Create `list_test.go`. The first test follows page tokens to the end:

#src("workbook/ch02/step5/list_test.go", region: "head")

The laziness gets a test of its own, which counts the requests the fake
received:

#src("workbook/ch02/step5/list_test.go", region: "breaktest")

When an error ends the iteration, the loop sees it once. The fake's token
check makes a convenient failure: rotate the required token after the
third item, and the next page fetch is rejected.

#src("workbook/ch02/step5/list_test.go", region: "errtest")

`Collect` with partial results, a bad page size, and a filter:

#src("workbook/ch02/step5/list_test.go", region: "collecttest")

And the log stream, read line by line with `bufio.Scanner`:

#src("workbook/ch02/step5/list_test.go", region: "logstest")

The fake's own test checks that it rejects bad tokens and sizes. Add it at
the end of `platformapifake/fake_test.go`:

#src("workbook/ch02/step5/platformapifake/fake_test.go", region: "pagetest")

#needspace(12em)
#checkpoint(step: 5, of: 8, title: [Pages and streams])[
  #output("ch02/s5-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch02/s5-test.txt", cmd: "go vet ./... && go test ./...")
  The documentation of a list method, as a user's editor shows it on hover:
  #output("ch02/s5-doc.txt", cmd: "go doc . Client.ListDeployments")
  #troubleshoot(
    ([#ts("s5-yield.txt")], [`list` ignored `yield`'s result and kept producing items after the loop body executed `break`.], [`if !yield(item, nil) { return }`. See "Iterators".]),
    ([#ts("s5-nilmap.txt")], [`r.query` was `nil` (the caller passed no filter), and writing to a nil map panics.], [Start from `url.Values{}` when the clone is `nil`.]),
    ([#ts("s5-errcheck.txt")], [A test ranged over an `iter.Seq2` with one variable, so every error was silently dropped.], [Range with `d, err` and check `err` on every iteration.]),
  )
]

#step(6, 8, "Long-running operations", label: <sec-api-s6>)

`CreateDeployment` returns an operation that is `pending`. A rollout takes
minutes, and callers want two things from it: progress while it runs, and
the final state when it ends. This step adds both as generic methods on
the client, then writes a small consumer of the SDK, the way the `ship` CLI
uses it, and runs into the one place where Go 1.27's generic methods and
interfaces don't mix.

=== Generics where they pay for themselves

The SDK uses type parameters in five places by the end of this step, and
each one removes real repetition. `list[T]` serves three list endpoints with
one pagination loop, over the generic wire type `page[T]`. `call[T]` decodes
a response into whatever type each endpoint returns. `Operation[T]`
describes a long-running operation along with the type of resource it
produces, so waiting on a deployment returns a `*Deployment` without a type
assertion. `Collect[T]` works on any of the iterators. And `Poll[T]` and
`Wait[T]`, below, follow any operation.

Just as instructive is what isn't generic. There is no `Resource` interface
with a `Get[T Resource](ctx, id)` function, no generic options, no
`Filter[T]`. A generic `Get` would need a constraint with a method such as
`path() string` on every resource type, put type arguments at every call
site, and turn readable signatures in `go doc` into one abstract one. The
rule of thumb in SDK code: generics work well for code that _moves values
around_ without looking inside them (decoding, paging, collecting, polling),
which is why every constraint in this package is `any`. When you need to
call methods on `T`, a plain interface is usually clearer. Constraints such
as `cmp.Ordered` or `~string` earn their place in algorithms like sorting,
sets and aggregation, which an HTTP client mostly doesn't contain.

=== Poll and Wait

A failed rollout needs its own error type: the API calls succeeded, but the
work they started did not. Add it at the end of `errors.go`:

#src("workbook/ch02/step6/errors.go", region: "operror")

Replace all of `operation.go` above the end of the `Operation` type with an
import block and a type that carries the error:

#src("workbook/ch02/step6/operation.go", region: "operation")

The doc comment now promises what the type is for: an operation is plain
data, so a program can store its ID and resume waiting later, even in
another process. Add `Poll`:

#src("workbook/ch02/step6/operation.go", region: "poll")

`Poll` is an iterator over snapshots of the operation, and the third generic
method in the package. It fetches the operation, yields it, sleeps for the
poll interval, and repeats until a snapshot says `Done` or the caller
breaks. Callers who want progress, like the tour in step 8, range over it.
Callers who only want the result call `Wait`, which is built on `Poll`
rather than beside it, so both share one loop, one sleep that honours the
context, and one definition of "done":

#src("workbook/ch02/step6/operation.go", region: "wait")

`sleep` is a `select` on a timer and `ctx.Done()`, never a bare
`time.Sleep`: a tool that ignores #kbd("Ctrl-C") for the rest of a
two-second poll interval feels broken. `context.Cause` reports _why_ the
context ended, which Chapter 4 uses heavily.

The comment in `Wait`'s second case guards against a famous Go trap.

#goconcept(title: [A nil pointer in an interface is not a nil interface])[
  An interface value is `nil` only when it holds _no_ type and no value. A
  nil `*OperationError` stored in an `error` variable holds a type
  (`*OperationError`) and a nil value, so the variable is not `nil`:

  #code(file: "sketch")[```go
  var opErr *OperationError // nil pointer
  var err error = opErr     // err != nil is true!
  ```]

  If `Wait` returned `cur.Result, cur.Error` for every finished operation,
  successful ones would return a non-nil error holding a nil pointer.
  Callers would treat success as failure, and printing the error would
  show `<nil>`, as the checkpoint demonstrates. Return a literal `nil` for
  "no error", and only convert a pointer to `error` when it is known to be
  non-nil.
]

The poll interval is a client option. In `client.go`, add `time` to the
imports:

#src("workbook/ch02/step6/client.go", region: "imports")

add a `poll` field to `config`:

#src("workbook/ch02/step6/client.go", region: "client")

#needspace(10em)
give it a default in `New`:

#src("workbook/ch02/step6/client.go", region: "option")

and add the option after `WithLogger`:

#src("workbook/ch02/step6/client.go", region: "poll")

=== Generic methods in Go 1.27

Before Go 1.27 there were three ways to write `Wait`. A package-level
`platformapi.Wait(ctx, client, op)` works but reads backwards and sits under
no type in `go doc`. A common design in cloud SDKs makes the operation a
_handle_ that holds a hidden pointer to the client and offers
`op.Wait(ctx)`; handles can't be serialized, can't be built by hand in
tests, and can't be recreated from an ID in another process. The third, a
method on the generic type that takes the client, `op.Wait(ctx, client)`,
keeps the operation as plain data and is a reasonable choice on older
toolchains, but it puts I/O on a data type and splits the client's
behaviour across two places in the docs. With a generic method, the
operation stays plain data and every call that does I/O hangs off `Client`.
`ship` writes `op.ID` to its state file, and after a crash it resumes by
passing `Wait` a fresh `Operation[Deployment]` with only the `ID` set, which
`TestResumeWaitingByOperationID` covers below.

Type arguments of `Poll` and `Wait` are inferred from the operation, so
call sites read `client.Wait(ctx, op)`. Method values work too:
`client.Wait[platformapi.Deployment]` is a value of an ordinary function
type.

=== Cancelling a wait is not cancelling the work

Long-running operations make the context's meaning subtle. When a caller
cancels `Wait`, only the _waiting_ stops. The deployment is running on the
platform's servers, and the client has no way to stop it except by asking.
The doc comment of `Poll` says so, and a test below pins it down, because it
is exactly the kind of behaviour a future maintainer might "fix".

#warning(title: [#kbd("Ctrl-C") during a deploy leaves the rollout running])[
  When a user interrupts `ship deploy`, the signal cancels the context,
  `Wait` returns, and the rollout carries on without anyone watching.
  Sometimes that is what the user wants. Often it isn't. Decide explicitly,
  document it, and if interruption should stop the rollout, call
  `CancelDeployment` in the interrupt path. Use `context.WithoutCancel(ctx)`
  with its own short timeout for that call (Chapter 4), because the original
  context is already cancelled, and a cancel request sent on a cancelled
  context never leaves the process.
]

=== The fake rolls out

#needspace(10em)
The fake moves a rollout forward one replica each time the operation is
fetched. Replace `Server`, `New` and `routes` in `platformapifake/fake.go`:

#src("workbook/ch02/step6/platformapifake/fake.go", region: "server")

Add two knobs for tests above `Requests`:

#src("workbook/ch02/step6/platformapifake/fake.go", region: "knobs")

In `platformapifake/deployments.go`, replace the wire types from the top of
the file to the end of `operation` (the operation gains an error):

#src("workbook/ch02/step6/platformapifake/deployments.go", region: "types")

and add the operation handler at the end:

#src("workbook/ch02/step6/platformapifake/deployments.go", region: "advance")

Rollouts advance per poll rather than by wall-clock time, so a test
controls progress by polling and never needs to sleep. A broken version
fails when half its replicas are updated.

=== Tests in virtual time

`Wait` sleeps two seconds between polls, so a four-replica rollout takes six
seconds. Tests that wait six real seconds are slow, and tests that shrink the
interval to a millisecond are flaky on a busy CI machine. Go has a better
answer.

#newingo("1.25", title: [`testing/synctest`: virtual time for tests])[
  `synctest.Test(t, f)` runs `f` in an isolated _bubble_. Inside it, the
  `time` package uses a fake clock that only moves when every goroutine in
  the bubble is _durably blocked_: waiting on a channel, timer, `select`,
  `sync.Cond` or `WaitGroup` that belongs to the bubble. The clock then
  jumps straight to the next timer that would unblock something. A test of
  a six-second wait finishes in microseconds and measures exactly six
  seconds. Production code needs no changes.
]

#newingo("1.27", title: [In-memory networks for synctest])[
  Real sockets are not durably blocking, because a packet from outside the
  bubble could wake them, so `synctest` alone can't virtualize an HTTP round
  trip. Go 1.27 adds `httptest.NewTestServer(t, handler)`, which creates a
  test server on an in-memory network and closes it when the test ends. Its
  `Client()` talks to that network, so pollers, timeouts and retries with
  backoff all run in virtual time. Its URL is `http://example.com`: pass the
  server's client along with the URL, or requests go to the real
  `example.com`.
]

Switch the fixture to the in-memory server. Replace the import block and
`newClient` in `client_test.go`:

#src("workbook/ch02/step6/client_test.go", region: "fixture")

The fixture sets the poll interval explicitly, so the tests don't depend on
the default. Create `operation_test.go`:

#src("workbook/ch02/step6/operation_test.go", region: "waittest")

The fake moves one replica per poll, so four replicas take four polls and
three two-second sleeps: six seconds of virtual time, asserted exactly.
The cancellation test:

#src("workbook/ch02/step6/operation_test.go", region: "canceltest")

Failed and cancelled rollouts:

#src("workbook/ch02/step6/operation_test.go", region: "failtest")

`Wait` returns the failed deployment _together with_ the
`*OperationError`, so a caller can report how far the rollout got. Last,
progress, resuming, and a guard against an operation with no ID:

#src("workbook/ch02/step6/operation_test.go", region: "polltest")

=== Let consumers declare what they use

Now look at the SDK from the other side. `ship` promotes releases: it finds
the version that last succeeded in one environment and deploys it to the
next. A miniature of that logic lives in a package of its own. Make a
directory `examples/promote` and create `examples/promote/promote.go`:

#src("workbook/ch02/step6/examples/promote/promote.go", region: "head")

`promote` needs three operations from the platform, so it declares an
interface with exactly those three:

#src("workbook/ch02/step6/examples/promote/promote.go", region: "platform")

Nobody in the platform team had to anticipate this interface. It lives in
the consumer, it changes when the consumer changes, and a stub that
satisfies it fits in a test file. This is the first half of _accept
interfaces, return structs_: `Promote` accepts the smallest interface that
describes what it needs, and anything with those methods will do.

The obvious thing would be to list `Wait` in the interface and pass a
`*platformapi.Client` directly. To see what happens, put an interface with
`Wait`, instantiated for deployments, in a scratch file next to `promote.go`,
with a compile-time assertion that the client satisfies it:

#code(file: "examples/promote/waiter.go (scratch)")[```go
package promote

import (
	"context"

	"platformapi"
)

// waiter lists the SDK's own Wait method, instantiated for deployments.
type waiter interface {
	Wait(ctx context.Context, op *platformapi.Operation[platformapi.Deployment],
		opts ...platformapi.CallOption) (*platformapi.Deployment, error)
}

var _ waiter = (*platformapi.Client)(nil)
```]

Here is what the compiler says to that:

#output("ch02/s6-generic-page.txt", cmd: "go build ./examples/promote 2>&1 | fold -s -w 86")

#newingo("1.27", title: [Generic methods and interfaces don't mix])[
  Two restrictions remain on generic methods. Interface methods can't
  declare type parameters, and a generic method never satisfies an
  interface method, even one whose signature matches an instantiation. The
  `have` and `want` lines above show both: `Wait[T any]` is a family of
  methods, and an interface needs one specific method in the type's method
  set.
]

Delete `waiter.go`. The fix is a small adapter in the consumer:

#src("workbook/ch02/step6/examples/promote/promote.go", region: "adapter")

`Client` embeds `*platformapi.Client`, so every SDK method is promoted onto
it: `ListDeployments` and `CreateDeployment` come along for free, and it
adds one non-generic `WaitDeployment` that calls the instantiated generic
method. That makes `promote.Client` satisfy `Platform`. Embedding a type to
add the one method an interface needs is the adapter pattern, Go style.

That is a fair price for a consumer, because it appears once per consuming
package. It would not be fair if the SDK forced it for core operations.
Generic methods suit convenience APIs on concrete types; keep the methods
consumers are likely to abstract over non-generic. In this SDK,
`CreateDeployment`, `GetDeployment` and the list methods are ordinary
methods, and only the operation helpers are generic.

The function itself:

#src("workbook/ch02/step6/examples/promote/promote.go", region: "promote")

`PageSize(1)` and `break` together mean one request for one item: the
iterator from step 5 fetches nothing more.

The tests use an internal test file, `examples/promote/promote_test.go`,
which starts with:

#src("workbook/ch02/step6/examples/promote/promote_test.go", region: "head")

A stub implements `Platform` in a few lines, because the interface has three
methods rather than the SDK's eleven:

#src("workbook/ch02/step6/examples/promote/promote_test.go", region: "stub")

The stub's `ListDeployments` is a hand-written iterator, the same shape the
SDK returns. The test then reads like a specification of `Promote`'s
behaviour, with no HTTP in sight:

#src("workbook/ch02/step6/examples/promote/promote_test.go", region: "stubtest")

The same package also tests `Promote` against the real client and the fake
platform, which covers the wire format the stub skips:

#src("workbook/ch02/step6/examples/promote/promote_test.go", region: "faketest")

Chapter 6 weighs stubs, fakes and mocks against each other. The short
version: a stub is the cheapest test of your logic, and a fake shipped by
the API's owner is the cheapest test of your integration.

#interview(title: [“What does ‘accept interfaces, return structs’ mean, and when do you break it?”])[
  Accepting an interface lets the caller pass anything with the methods you
  need, including test doubles, and the interface should be as small as the
  function's needs. Returning a concrete type lets you add methods later
  without breaking anyone, and gives callers full documentation and access.
  Then name the exceptions. Return an interface when there are several
  implementations and the caller must not depend on which one it got, as
  with `error`, `net.Dial` returning a `net.Conn`, or `sha256.New` returning
  a `hash.Hash`. Accept a concrete type when you need a specific
  implementation's behaviour, such as `*http.Client` for its connection
  pool. Finish with the cost asymmetry: adding a method to an exported
  interface breaks every implementer, and since Go 1.27 a generic method
  can't satisfy an interface at all.
]

#needspace(12em)
#checkpoint(step: 6, of: 8, title: [Long-running operations])[
  #output("ch02/s6-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch02/s6-test.txt", cmd: "go vet ./... && go test ./...")
  The tests that wait six seconds, and three, of virtual time, run in no
  measurable real time:
  #output("ch02/s6-synctest.txt", cmd: "go test -v -run 'TestWait|TestCancelling' . 2>&1 | grep -E '^(=== RUN|--- |ok)'")
  #troubleshoot(
    ([#ts("s6-adapter.txt")], [A `*platformapi.Client` was passed where `Platform` is needed. It has `Wait[T]`, but no `WaitDeployment`.], [Wrap it: `promote.Client{Client: client}`.]),
    ([#ts("s6-generic.txt")], [An interface lists `Wait`, and the SDK's `Wait` is generic. Generic methods never satisfy interface methods.], [Add a non-generic adapter method. See "Let consumers declare what they use".]),
    ([#ts("s6-typednil.txt")], [`Wait` returned a nil `*OperationError` as an `error` on success, so the error is non-nil and prints `<nil>`.], [Return a literal `nil`. See "A nil pointer in an interface".]),
    ([#ts("s6-realnet.txt")], [The fixture used `httptest.NewServer`, a real socket, inside a `synctest` bubble. Virtual time never advances past network I/O.], [Use `httptest.NewTestServer(t, fake)` and its `Client()`.]),
  )
]
