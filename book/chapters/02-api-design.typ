#import "../template/book.typ": *

#chapter(2, "Designing Go APIs That Last", label: <ch-api-design>,
  abstract: [
    A platform team's Go SDK gets imported by dozens of teams, vendored into
    CLIs, and compiled into services nobody has touched in a year. Every
    exported name in it is a promise you will keep for years. This chapter
    designs that SDK for the platform's deployment API, from the constructor
    to the error types, and then shows how to change it later without
    breaking the people who depend on it.
  ],
  learn: (
    [Why breaking changes are so expensive under Go modules, and what the Go 1 promise and `/v2` import paths mean for your own packages],
    [Small interfaces owned by the consumer, optional interfaces, and when an exported interface is a mistake],
    [Functional options versus config structs, validation in constructors, and zero values that work],
    [Context as API surface, request IDs, idempotency keys, and retry classification],
    [Paginated APIs as `iter.Seq2` iterators],
    [Generics in SDK code, Go 1.27 generic methods, and their limits],
    [Doc comments, runnable examples, deprecation, and catching breaking changes with `apidiff`],
  ),
  build: [
    *`platformapi`*, the Go SDK for the platform's environments, services and
    deployments API: functional options, context-first methods, iterators,
    typed long-running operations, retries with idempotency keys, and typed
    errors.

    #v(4pt)
    *`platformapifake`*, an in-memory platform for tests, plus a tour program
    and a small consumer package. The `ship` deployment CLI in Part V is
    built on this SDK.
  ],
)

== The SDK fifty teams import <sec-api-cost>

The platform team runs an internal HTTP API for environments, services and
deployments. For its first year, every team that wanted to deploy wrote its
own client: a Python script in one repository, `curl` in a Makefile, four Go
wrappers with four different ideas about retries. Then one of those wrappers
retried a `POST /v1/deployments` after a client-side timeout. The first
request had already reached the server, so checkout got two rollouts of the
same version racing each other through staging. The postmortem's action item
was one line: _the platform team owns the client_.

So now there is an SDK, and the cost structure of every change to it is
lopsided. Renaming a field takes its author ten minutes. For each consuming
module it costs an upgrade pull request, a review, a CI run and a release.
Call it half a day of an engineer's time. With 50 consuming modules, one
rename costs about 25 engineer-days, spread across teams who did not ask for
it and will not schedule it this sprint.

Go modules add a twist that surprises people coming from other ecosystems.
The `go` command uses _minimal version selection_: for each module in the
build, it picks the highest version that any module in the build requires.
Suppose the `ship` CLI requires `platformapi` v1.3.0 and also imports an
internal library that requires v1.8.0. Then `ship` builds with v1.8.0,
whether or not its authors ever tested against it. If v1.8.0 removed a
function `ship` calls, `ship` stops compiling on the day someone bumps the
library, and the `ship` team changed nothing. In Go, a new minor version
must be a superset of the old one, because consumers don't get to choose.

The Go project holds itself to the same rule. The Go 1 compatibility promise
of 2012 says that programs written against Go 1 keep compiling and running.
The _import compatibility rule_ extends it to every module: if an old package
and a new package have the same import path, the new one must be backwards
compatible with the old one. A breaking change therefore needs a new import
path, which for modules means a major version suffix such as `/v2`. The
standard library follows its own advice: `math/rand/v2` arrived in Go 1.22
and `encoding/json/v2` in Go 1.27, both alongside their v1 packages, which
keep working. Behaviour changes in the toolchain ship with a `GODEBUG`
setting that restores the old behaviour, and since Go 1.21 the default
follows the `go` line in your `go.mod`.

An internal SDK can adopt the same discipline cheaply, as long as it is
designed for it from the first commit. That means a small surface, types
that can grow, behaviour pinned down by tests, and a mechanical check that
catches breaking changes before they are tagged. @fig-api-layers shows the
package this chapter builds, `platformapi`, and how a call travels through
it. Each layer has one job, and only the top one is public.

#fig(placement: auto, caption: [One call through `platformapi`. Consumers see methods, `Operation[T]`, iterators and `*APIError`. Everything below the first row is unexported and free to change.])[
  #diagram(
    spacing: (26pt, 10pt),
    dnode((0, 0), [consumers: `ship`, bots, portal plugins], kind: "muted"),
    dnode((0, 1), [public methods · `CreateDeployment` · `ListDeployments` · `Wait`], kind: "dark"),
    dnode((0, 2), [generic helpers · `call[T]` · `list[T]`], kind: "accent"),
    dnode((0, 3), [`do` · request ID · idempotency key · `retry.Policy`], kind: "accent"),
    dnode((0, 4), [`attempt` · `Limiter` · classify the status], kind: "accent"),
    dnode((0, 5), [`send` · `TokenSource` · refresh on 401], kind: "accent"),
    dnode((0, 6), [`*http.Client` · your `RoundTripper`], kind: "default"),
    dnode((1, 6), [platform API\ or `platformapifake`], kind: "good"),
    dnode((1, 1), [`Operation[T]` · `iter.Seq2`\ `*APIError` · sentinels], kind: "muted"),
    dedge((0, 0), (0, 1), "-|>"),
    dedge((0, 1), (0, 2), "-|>"),
    dedge((0, 2), (0, 3), "-|>"),
    dedge((0, 3), (0, 4), "-|>", label: [per attempt], label-side: left),
    dedge((0, 4), (0, 5), "-|>"),
    dedge((0, 5), (0, 6), "-|>"),
    dedge((0, 6), (1, 6), "-|>", label: [HTTPS]),
    dedge((0, 1), (1, 1), "--", label: [returns]),
  )
] <fig-api-layers>

And here is what using it looks like. The repository's tour program runs the
SDK against the in-memory fake platform. This scenario starts a deployment,
follows the rollout, and streams its log:

#output("ch02/tour-deploy.txt", cmd: "go run ./examples/ch02/tour deploy")

The rest of the chapter takes the design decisions behind that output one at
a time.

== Interfaces: small, and owned by the consumer <sec-api-interfaces>

A Go type satisfies an interface by having its methods. It never declares
which interfaces it implements. That one rule moves ownership of interfaces
from the package that _implements_ behaviour to the package that _uses_ it,
and most of the advice about interfaces in Go follows from it.

=== Return concrete types

`platformapi.New` returns a `*Client`, a struct. The tempting alternative,
seen in many internal SDKs, exports an interface next to its only
implementation:

#code(file: "client.go", caption: "don't ship this")[```go
// Client is the platform API. Use New to get one.
type Client interface {
	CreateDeployment(ctx context.Context,
		req CreateDeploymentRequest) (*Operation, error)
	GetDeployment(ctx context.Context, id string) (*Deployment, error)
	// ... nine more methods
}

func New(baseURL string) Client { return &client{baseURL: baseURL} }
```]

It looks like good engineering, and it locks the SDK in place. The day the
platform team adds `DeploymentLogs`, every type that implements `Client`
stops compiling: every mock that 50 teams generated, every wrapper that adds
logging. Adding a method to a struct breaks nobody. Adding one to an
exported interface breaks everyone who implemented it. There are smaller
costs too. `go doc` shows one wall of method signatures instead of
documentation per method, and callers can't reach anything that isn't on
the interface.

The proverb is _accept interfaces, return structs_. The second half is
about the evolution of _your_ package. The first half is about your
callers.

=== Let consumers declare what they use

The `promote` package in the repository is a miniature of what `ship` does:
it finds the version that last succeeded in one environment and deploys it
to the next. It needs three of the SDK's eleven methods, so it declares an
interface with exactly those three:

#src("examples/ch02/promote/promote.go", region: "platform")

Nobody in the platform team had to anticipate this interface. It lives in
the consumer, it changes when the consumer changes, and a stub that
satisfies it fits in a test file. (`WaitDeployment` is not an SDK method; it
comes from a small adapter, needed because of a Go 1.27 restriction that
@sec-api-generics explains.)

#src("examples/ch02/promote/promote_test.go", region: "stub")

The test then reads like a specification of `Promote`'s behaviour, with no
HTTP in sight:

#src("examples/ch02/promote/promote_test.go", region: "stubtest")

The same package also tests `Promote` against the real client and the fake
platform, which covers the wire format the stub skips. Chapter 6 weighs
stubs, fakes and mocks against each other.

=== Interfaces the SDK consumes

The SDK _uses_ two behaviours that callers supply, so the SDK declares those
interfaces. The first is a source of bearer tokens:

#src("pkg/platformapi/token.go", region: "token")

`Token` takes a context because fetching a token can mean a network call to
an identity provider, and that call must respect the caller's deadline.
This is easy to get wrong, and once it ships it can't be fixed.
`golang.org/x/oauth2` defines its `TokenSource` as `Token() (*Token, error)`
with no context. Its refreshing implementation therefore keeps a context in
a struct field, captured when the source was built (the field is commented
`// used to get HTTP requests` in `oauth2.go`). Adding a context parameter
now would break every `TokenSource` implementation in the ecosystem, so the
interface stays as it is. If a method might ever do I/O, give it a context
from the first release.

`TokenSourceFunc` is the same adapter pattern as `http.HandlerFunc`: a
function type with a method, so a closure can satisfy a one-method
interface without a named type.

The second behaviour is client-side rate limiting. `WithLimiter` accepts
any value with this method set:

#src("pkg/platformapi/client.go", region: "limiter")

`*rate.Limiter` from `golang.org/x/time/rate` has a method
`Wait(ctx context.Context) error`, so it satisfies `Limiter` without either
package knowing about the other. The SDK gets rate limiting without adding
`x/time` to its dependencies, and its API doesn't mention a third-party type
whose version would then be tied to the SDK's own.

=== When an exported interface is a mistake

An interface in a library is a mistake when it has one implementation and
exists "so callers can mock it". It is a mistake when it is large, because
every method is something every implementer must write and nobody can add
to it. And it is a mistake when it describes the library's own behaviour
rather than something the library needs from the outside. `TokenSource` and
`Limiter` pass that test: one method each, implemented by callers, consumed
by the SDK.

=== Readers and writers

The rollout log can be megabytes. `DeploymentLogs` returns the stream rather
than a `[]byte` or a `[]string` of lines:

#src("pkg/platformapi/api.go", region: "logs")

The tour program wraps it in a `bufio.Scanner` to prefix each line. A CI
job could `io.Copy` it into a file, pipe it through `gzip.NewWriter`, or
`io.TeeReader` it to two places, all in constant memory, and the SDK had to
anticipate none of it. `io.Reader` and `io.Writer` are the most successful
interfaces in Go because they are one method each and every package agrees
on them.

=== Optional interfaces: growing without breaking implementers

Interfaces that callers implement still need to evolve. Six months after the
first release, the identity team starts rotating credentials hourly. A
`TokenSource` that caches tokens will keep sending a revoked one until its
cache expires, and every call fails with 401 in the meantime. The client
needs a way to say "that token was rejected". Adding a method to
`TokenSource` would break every implementation. The standard library's
answer is the optional interface: a second interface that a value _may_
implement, which the consumer checks with a type assertion. `http.Flusher`,
`io.WriterTo` and `io.ReaderFrom` all work this way; `io.Copy` uses the
last two to skip its buffer when it can.

#src("pkg/platformapi/token.go", region: "invalidator")

The client checks for it on a 401, invalidates, and retries once:

#src("pkg/platformapi/transport.go", region: "send")

Two details matter. `InvalidateToken` receives the _rejected_ token, so a
caching source can ignore the call if it has already refreshed: under load,
ten requests may fail with the same old token, and only the first should
evict anything. And the retry happens once, outside the retry policy. A
second 401 means the new token is bad too, and retrying again would only
hammer the identity provider. `TestRejectedTokenIsRefreshedOnce` rotates
the fake's accepted token mid-test and checks both behaviours.

#warning(title: [Wrappers hide optional interfaces])[
  An optional interface is only visible on the value you assert against. If a
  caller wraps their `TokenSource` in another type, say one that counts calls
  for metrics, the wrapper doesn't have `InvalidateToken` and the upgrade
  silently stops working. HTTP middleware that wraps `http.ResponseWriter`
  hits the same problem with `http.Flusher`, which is why Go 1.20 added
  `http.ResponseController`: it follows `Unwrap` methods to find the
  original writer. Document optional interfaces next to the interface they
  extend, as `TokenInvalidator`'s comment does, so that wrapper authors know
  to forward them.
]

#interview(title: [“What does ‘accept interfaces, return structs’ mean, and when do you break it?”])[
  Accepting an interface lets the caller pass anything with the methods you
  need, including test doubles, and the interface should be as small as the
  function's needs. Returning a concrete type lets you add methods later
  without breaking anyone, and gives callers full documentation and access.
  Then name the exceptions. Return an interface when there are several
  implementations and the caller must not depend on which one it got, as
  with `error`, `net.Dial` returning a `net.Conn`, or `sha256.New` returning
  a `hash.Hash`. Accept a
  concrete type when you need a specific implementation's behaviour, such
  as `*http.Client` for its connection pool. Finish with the cost
  asymmetry: adding a method to an exported interface breaks every
  implementer.
]

== Constructors and configuration <sec-api-config>

A client has one required setting (where the API is) and a long tail of
optional ones that will keep growing for as long as the SDK exists. Go code
uses three shapes for this, and Chapter 4 already used one of them:
`retry.Policy` and `sweep.Config` are plain config structs.

#block(breakable: false)[#table(
  columns: (auto, 1fr, 1fr),
  align: (left, left, left),
  table.header([Shape], [Good at], [Weak at]),
  [Config struct\ `retry.Policy{MaxAttempts: 4}`], [Visible: callers see every setting in one place and can print, compare and copy it. Easy to fill from YAML or flags. With care, the zero value means "defaults".], [It can't tell "unset" from "zero". Adding a field whose default isn't zero needs a pointer or a sentinel. Validation is a separate step that callers can skip. Required and optional fields look the same.],
  [Functional options\ `New(url, WithToken(t))`], [Defaults stay internal and can change. Each option validates its own input. Required arguments stay positional. New options never break existing calls.], [More code per setting. You can't inspect a built configuration. Discovery depends on good docs (`go doc` groups the options under `Option`, which helps).],
  [Builder\ `NewBuilder().Token(t).Build()`], [Familiar to Java and C\# developers.], [Errors pile up until `Build` or get lost mid-chain, a half-built builder can be shared by accident, and it reads as foreign in Go code.],
)]

`platformapi` takes the base URL as a positional argument and everything
else as options. The client's fields are unexported and grouped in a
`config` struct that only options can touch:

#src("pkg/platformapi/client.go", region: "client")

#src("pkg/platformapi/client.go", region: "option")

Several decisions in those twenty lines are deliberate.

*The `Option` type takes an unexported `*config`, not `*Client`.* An early
draft used `type Option func(*Client) error`. That compiles fine, and it
means a caller can write `platformapi.WithLogger(l)(client)` to reconfigure
a live client that other goroutines are using, a data race the SDK would be
blamed for. With an unexported parameter type, callers can neither write
their own options nor apply one after `New` returns. The set of options is
closed, and a built `Client` is immutable.

*`New` validates everything and reports everything.* Each option checks its
input, and `New` joins every error with `errors.Join`, so a misconfigured
client produces one message listing all of its problems, not one problem
per deploy attempt. `TestNewReportsEveryProblem` passes an `ftp://` base
URL, an empty User-Agent, a zero poll interval and a nil `*http.Client`, and
checks that the single error names all four.

*`New` performs no I/O.* It doesn't fetch a token or ping the API. A
constructor that touches the network makes program startup depend on
another service being up, makes every test that builds a client slow or
flaky, and turns a configuration error and a network error into the same
failure. Errors from `New` are always configuration errors, and they always
happen before any work starts.

*The defaults are production defaults.* Retries are on (four attempts,
200 ms base delay, full jitter, all from `pkg/retry`), because a caller who
forgets to configure them should get safe behaviour, not fragile behaviour.
The `http.Client` has no `Timeout`, for the same reason as in Chapter 4:
deadlines come from the caller's context, and a second, competing timeout
only produces confusing errors. Logs are discarded unless the caller asks
for them.

Here are two of the options. Each is a constructor for a closure that
validates and stores one setting:

#src("pkg/platformapi/client.go", region: "options")

`WithUserAgent` deserves attention beyond its three lines. It doesn't
replace the User-Agent, it prefixes it, so every request says something
like `ship/2.3.0 platformapi-go/1.0.0`. When the platform team wants to
remove a deprecated endpoint, the server's access logs say which products
and which SDK versions still call it. That is the cheapest observability an
SDK can have, and it only works if callers can't turn it off.

=== Zero values that mean something

Go's habit of making the zero value useful pays off in API types. A
`DeploymentFilter{}` selects every deployment; set a field to narrow it.
`retry.Policy{}` means "the defaults". `CreateDeploymentRequest.Reason` is
optional and omitted from the JSON when empty. `DeploymentState` documents
that new states may be added and unknown values mean "not finished", so a
`switch` written today still behaves when the server adds a `paused` state
next year:

#src("pkg/platformapi/types.go", region: "state")

The `Client`'s zero value is _not_ useful, because a client without a base
URL can't do anything, and the doc comment says so. Compare `http.Client`,
whose zero value works because nothing in it is required. If the zero value
of a type can't be made useful, say so in its documentation and make the
constructor the obvious way in.

#tip(title: [Options and structs combine])[
  The choice isn't all or nothing. `WithRetry` takes a `retry.Policy` struct:
  an option on the client, carrying a value type that is easy to build, copy
  and compare. Use structs for _values_ (a policy, a request, a filter) and
  options for _the construction of a long-lived object_. The SDK's request
  types, such as `CreateDeploymentRequest`, are structs for the same reason:
  a struct can gain fields without breaking callers who use field names in
  their literals.
]

== Context is part of the signature <sec-api-context>

Every method that talks to the platform takes a `context.Context` as its
first parameter, including methods that look instant, like `GetEnvironment`.
Any call can become slow: the server is under load, the client waits on the
rate limiter, the token source refreshes a token, or the retry policy
backs off. Adding a context parameter later changes the signature, and
@sec-api-evolve shows that every signature change breaks someone. So the
context goes in from the start.

The context bounds the _whole_ call: every attempt, every backoff sleep, the
limiter wait, and the token fetch. A caller who wants "create this
deployment, but give up after 30 seconds including retries" writes exactly
that, and the SDK has no timeout knobs of its own to conflict with it.

The client never stores a context. It is created once and lives as long as
the process, while a context describes one operation. A context saved in a
struct either outlives its operation or gets reused for the next one. The
`oauth2` refresher from @sec-api-interfaces shows both failure modes: every
token refresh runs under the context captured at construction, so a
request's deadline never applies to its own refresh, and if that captured
context is ever cancelled, every later refresh fails.

=== Cancelling a wait is not cancelling the work

Long-running operations make the context's meaning subtle. When a caller
cancels `Wait`, only the _waiting_ stops. The deployment is running on the
platform's servers, and the client has no way to stop it except by
asking. A test pins this down, because it is exactly the kind of
behaviour a future maintainer might "fix":

#src("pkg/platformapi/operation_test.go", region: "canceltest")

The test runs in a `synctest` bubble on the fake platform, so its three
seconds of waiting take microseconds of real time. The tour shows the same
thing from a caller's point of view, along with the other failure shapes
the SDK reports:

#output("ch02/tour-errors.txt", cmd: "go run ./examples/ch02/tour errors")

#warning(title: [#kbd("Ctrl-C") during a deploy leaves the rollout running])[
  When a user interrupts `ship deploy`, the signal cancels the context, `Wait`
  returns, and the rollout carries on without anyone watching. Sometimes that
  is what the user wants. Often it isn't. Decide explicitly, document it, and
  if interruption should stop the rollout, call `CancelDeployment` in the
  interrupt path. Use `context.WithoutCancel(ctx)` with its own short
  timeout for that call (Chapter 4), because the original context is already
  cancelled, and a cancel request sent on a cancelled context never leaves
  the process.
]

=== What belongs in context values

Context values are for request-scoped data that crosses API boundaries
without every function in between knowing about it. Trace context is the
canonical example: OpenTelemetry's HTTP instrumentation reads the span from
the request's context and propagates it in headers, which is why
`WithHTTPClient` is the SDK's tracing hook (Chapter 17). Settings that
change what a call does are not context values. Request IDs, idempotency
keys and page sizes are explicit `CallOption`s. They show up in `go doc`
and in the call site, and a reader can see that a call sets one. A value
hidden in a context is an invisible parameter, and invisible parameters are
the hardest kind to keep compatible.

== One call, many attempts <sec-api-calls>

Per-call settings are a separate type from client options, so passing
`WithToken` to `GetDeployment` doesn't compile:

#src("pkg/platformapi/transport.go", region: "calloption")

Inside the client, a _call_ is the unit the caller sees, and an _attempt_ is
one HTTP exchange. `do` turns one into the other:

#src("pkg/platformapi/transport.go", region: "do")

The request ID and the idempotency key are generated _before_ the retry
loop, once per call. The idempotency key is what makes retrying a `POST`
safe. If the first attempt reached the server but its response was lost to
a timeout or a reset connection, the retry carries the same key, and the
server returns the operation it already started instead of starting a
second rollout. That is the incident from the start of this chapter,
prevented by moving one line above a loop. The request ID ties the attempts
together in the server's logs. Both default to UUIDs from the `uuid`
package, which is new in Go 1.27; request IDs use version 7, whose leading
bits are a timestamp, so they sort by time in a log search.

`attempt` then classifies what happened, in the vocabulary of `pkg/retry`:

#src("pkg/platformapi/transport.go", region: "attempt")

Read it as a policy table. Network errors are retryable, because they
usually mean a connection was reset or a pod went away mid-request. 429 and
503 are retryable and honour `Retry-After`, which the server sends when it
knows how long to wait. 502 and 504 come from proxies and load balancers
and are retryable. Everything else is permanent: a 404 won't turn into a 200
in 200 ms, and retrying a 400 just sends the same bad request again.
Requests that are neither `GET` nor marked idempotent are never retried at
all. Every `POST` in this SDK is marked, either because it carries a key or
because it is naturally idempotent (cancelling a cancelled deployment
succeeds), but the guard means a future `POST` added without thinking about
idempotency fails safe.

Every failure that reaches the caller is an `*APIError`, built by
`decodeError` from the response. Servers and proxies don't always send the
API's JSON error shape, so it falls back to the status text:

#src("pkg/platformapi/errors.go", region: "errors")

`Code` is the field programs should branch on, and `Message` is for people.
`RequestID` is in the error text on purpose: it is what a user pastes into
a support ticket, and it finds the server's log lines for that call. The
`Is` method lets callers write `errors.Is(err, platformapi.ErrNotFound)`
without the SDK exporting a sentinel per status code. Chapter 3 covers
error design in depth; this SDK keeps its error API deliberately small.

The limiter is consulted before _every_ attempt, retries included. As
Chapter 4 argued for `sweep`, retries that bypass the rate limit turn a
partial outage into a retry storm.

The tour's flaky scenario injects two 503s and a 429 with `Retry-After: 1`
into the fake, then creates a deployment:

#output("ch02/tour-flaky.txt", cmd: "go run ./examples/ch02/tour flaky")

The waits before the first two retries are drawn at random below ceilings
of 200 ms and 400 ms, so they differ on every run. The third is exactly one
second, because the server asked for it. The server saw four `POST`s with the same request ID
and idempotency key, and created one operation. The second half of the
scenario is the cross-process case: a CI job that crashed and re-ran its
step passes its own key, derived from the pipeline run, and gets the same
operation back. If a caller reuses a key for a _different_ request, the
fake answers 422 `idempotency_mismatch`, as the IETF draft for the header
recommends.

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

=== Testing retries in virtual time

The retry tests use the fixture every test in the package shares. It serves
the fake with `httptest.NewTestServer`, which Go 1.27 added for exactly this:
its in-memory network lets HTTP round trips run inside a `testing/synctest` bubble:

#src("pkg/platformapi/client_test.go", region: "fixture")

`TestRetriesReuseTheIdempotencyKey` injects two 503s and checks that the
server saw three requests with one idempotency key and one request ID, the
same thing the tour printed. The next test asserts that a retry after a 429
happened after _exactly_ seven seconds. In virtual time that assertion is
deterministic, and the test still finishes in microseconds:

#src("pkg/platformapi/client_test.go", region: "retryafter")


#output("ch02/test-synctest.txt", cmd: "go test -v -run 'TestRetries|TestRetryAfter|TestWait|TestCancelling' ./pkg/platformapi")


== Iterators for paginated APIs <sec-api-iterators>

Every list endpoint on the platform paginates: the client sends
`page_size`, the server returns a page of `items` and an opaque
`next_page_token`, and the client sends that token back to get the next
page. An SDK has five ways to expose this, and the choice shapes every
caller's code.

#block(breakable: false)[#table(
  columns: (auto, 1fr, 1fr),
  align: (left, left, left),
  table.header([Design], [Caller writes], [Problems]),
  [Pages], [`ListPage(ctx, token)` in a loop, passing tokens back], [Every caller reimplements the loop, and some get the termination condition wrong.],
  [Slice of all], [`all, err := List(ctx)`], [Fetches everything even if the caller needs one item. Memory grows with the collection.],
  [Callback], [`List(ctx, func(d Deployment) error {...})`], [Inverted control flow. Stopping early needs a sentinel error. `return` inside the callback doesn't return from the caller.],
  [Channel], [`for d := range ch` plus an error channel], [Needs a goroutine, which leaks if the caller stops reading (Chapter 4). Errors travel separately from items.],
  [Iterator], [`for d, err := range List(ctx)`], [The caller must check `err` on every iteration.],
)]

Since Go 1.23, the last row is the idiomatic answer. An `iter.Seq2[T, error]`
is a function that takes a `yield` callback, and `for ... range` over it
reads like ranging over a map, while the SDK keeps control of fetching:

#src("pkg/platformapi/api.go", region: "listdeployments")

All three list methods share one generic implementation:

#src("pkg/platformapi/list.go", region: "page")

The iterator is lazy at both ends. Calling `ListDeployments` sends nothing;
the first request goes out when the loop starts. And a page is fetched only
after the caller has consumed the previous one, so `break` stops the
requests. The tour asks for five deployments, three per page, with request
logging on:

#output("ch02/tour-pages.txt", cmd: "go run ./examples/ch02/tour pages")

Two requests for five items, and the second one goes out only when the loop
asks for the fourth item. Nothing runs in the background, and nothing needs
cleaning up after `break`.

A test pins the laziness down by counting the requests the fake received:

#src("pkg/platformapi/list_test.go", region: "breaktest")

Errors travel with the items. A failed fetch yields one `(zero, err)` pair
and ends the iteration, so a caller that `continue`s past the error doesn't
spin forever:

#src("pkg/platformapi/list_test.go", region: "errtest")

For callers who do want everything in memory, the package exports
`Collect[T]`, an eight-line loop that drains any `iter.Seq2[T, error]` into a
slice and returns the items gathered so far along with the first error,
which suits "best effort" reports.

#newingo("1.23", title: [Range-over-func iterators])[
  `for x := range f` works when `f` has type `func(yield func(T) bool)`, and
  `for k, v := range f` when it takes `func(K, V) bool`. The `iter` package
  names these `iter.Seq[T]` and `iter.Seq2[K, V]`. The compiler turns the
  loop body into the `yield` function; `break`, `return` and `continue` work
  as usual, and the runtime panics if an iterator calls `yield` again after
  it has returned `false`. `slices.Collect`, `maps.Keys` and friends build on
  the same types, which is why an SDK iterator composes with the standard
  library for free.
]

#warning(title: [An iterator is a recipe, not a result])[
  An `iter.Seq2` value holds no data. Ranging over it twice runs the whole
  pagination twice, against a collection that may have changed in between.
  If a caller needs to make two passes, they should `Collect` once. And
  because the context is captured when the iterator is created, don't
  store an iterator built with a request-scoped context and range over it
  later: by then the request is over, its context is cancelled, and the
  first fetch fails. Treat iterators like the calls
  that create them: use them right away.
]

== Generics where they pay for themselves <sec-api-generics>

The SDK uses type parameters in four places, and each one removes real
repetition. `list[T]` serves three list endpoints with one pagination loop,
over the generic wire type `page[T]`. `call[T]` decodes a response into
whatever type each endpoint returns. `Operation[T]` describes a
long-running operation along with the type of resource it produces, so
waiting on a deployment returns a `*Deployment` without a type assertion.
And `Collect[T]` works on any of the iterators.

Just as instructive is what isn't generic. There is no `Resource` interface
with a `Get[T Resource](ctx, id)` function, no generic options, no
`Filter[T]`. A generic `Get` would need a constraint with a method such as
`path() string` on every resource type, put type arguments at every call
site, and turn eleven readable signatures in `go doc` into one abstract one.
The rule of thumb in SDK code: generics work well for code that _moves
values around_ without looking inside them (decoding, paging, collecting,
polling), which is why every constraint in this package is `any`. When you
need to call methods on `T`, a plain interface is usually clearer.
Constraints such as `cmp.Ordered` or `~string` earn their place in
algorithms like sorting, sets and aggregation, which an HTTP client mostly
doesn't contain.

=== Generic methods in Go 1.27

Until Go 1.27, `call[T]` and `list[T]` could not have been methods. A method
could use the type parameters of a generic receiver type, but it could not
declare its own, so helpers that needed both the client's configuration and
a per-call type had to be package-level functions taking the client as an
argument: `call[Deployment](ctx, c, r)`. Go 1.27 lifts that restriction:

#src("pkg/platformapi/transport.go", region: "call")

Call sites instantiate it explicitly, because nothing in the arguments
mentions `T`: `c.call[*Deployment](ctx, r)` in `GetDeployment`,
`c.call[page[T]](ctx, r)` inside `list`. Method values work too, and
`client.Wait[platformapi.Deployment]` is a value of an ordinary function
type.

The public generic methods are `Poll` and `Wait`, which follow an
`Operation[T]`:

#src("pkg/platformapi/operation.go", region: "operation")

#src("pkg/platformapi/operation.go", region: "poll")

`Wait` is built on `Poll` rather than beside it, so both share one loop, one
sleep that honours the context, and one definition of "done". Callers who
want progress, like the tour's deploy scenario, range over `Poll`; callers
who only want the result call `Wait`:

#src("pkg/platformapi/operation.go", region: "wait")

`TestWaitFollowsRolloutToSuccess` checks the timing exactly: the fake moves
one replica per poll, so a four-replica rollout takes four polls and three
two-second sleeps, six seconds of virtual time.

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
operation stays plain data and every call that does I/O hangs off
`Client`. `ship` writes `op.ID` to its state file, and after a crash it
resumes by passing `Wait` a fresh `Operation[Deployment]` with only the `ID`
set, which `TestResumeWaitingByOperationID` covers.

#newingo("1.27", title: [Methods may declare type parameters])[
  A method declaration can now have its own type parameter list:
  `func (c *Client) Wait[T any](...)`. The type arguments are inferred
  from the arguments where possible and written explicitly otherwise
  (`c.call[page[T]](ctx, r)`). The standard library uses the feature in
  `math/rand/v2`, where `(*Rand).N` now exists alongside the generic
  function `rand.N`. Two restrictions remain: interface methods can't
  declare type parameters, and a generic method never satisfies an
  interface method, even one whose signature matches an instantiation.
]

That second restriction has a real cost, and the platform team should know
it before shipping generic methods in an SDK. A consumer who declares an
interface containing `Wait` for deployments, as `promote` does, gets this
from the compiler:

#output("ch02/generic-iface.txt", cmd: "go build ./examples/ch02/testdata/genericiface 2>&1 | fold -s -w 92")

The fix is a small adapter in the consumer. `promote` embeds
`*platformapi.Client` and adds a non-generic `WaitDeployment` that calls
the instantiated method:

#src("examples/ch02/promote/promote.go", region: "adapter")

That is a fair price for a consumer, because it
appears once per consuming package. It would not be fair if the SDK forced
it for core operations. Generic methods suit convenience APIs on concrete
types; keep the methods consumers are likely to abstract over non-generic.
In this SDK, `CreateDeployment`, `GetDeployment` and the list methods are
ordinary methods, and only the operation helpers are generic.

== Package boundaries, documentation and examples <sec-api-packages>

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
`.../pkg/platformapi/internal/wire` unless it lives under
`.../pkg/platformapi/`. If the SDK grows an admin client in a sibling
package that shares wire types and request signing with the main one, that
shared code goes in `pkg/platformapi/internal/`. It isn't there today
because nothing shares it yet: `internal` is for code with more than one
user inside the module and none outside it.

@fig-api-packages shows the import graph. Two choices keep it acyclic. The
fake does not import the SDK: it speaks the wire protocol with its own
types, so a wrong JSON tag in the SDK fails a test instead of being
faithfully mirrored by the fake. And the SDK's tests live in the _external_
test package `platformapi_test`, which can import the fake without creating
a cycle, even if the fake one day imports the SDK for convenience. External
tests also see only the exported API, so they double as a check that the
public surface is usable.

#fig(placement: auto, caption: [Import graph. The fake shares no code with the SDK, and the SDK's tests import both from outside, as a consumer would.])[
  #diagram(
    spacing: (30pt, 22pt),
    dnode((0, 0), [`examples/ch02/promote`\ (like `ship`)], kind: "default"),
    dnode((1, 0), [`platformapi_test`\ external tests + examples], kind: "muted"),
    dnode((2, 0), [`examples/ch02/tour`], kind: "default"),
    dnode((0, 1), [`pkg/platformapi`], kind: "dark"),
    dnode((2, 1), [`platformapifake`\ own wire types], kind: "good"),
    dnode((0, 2), [`pkg/retry`\ Chapter 4], kind: "accent"),
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

=== A fake for every consumer

`platformapifake` is a package other teams import, not a test helper hidden
in the SDK's test files. Every consumer of the SDK needs to test their own
code against something, and if the platform team doesn't ship a fake, 50
teams will write 50 mocks of varying accuracy. The fake is an `http.Handler`
with a handful of knobs for the failures that matter:

#output("ch02/godoc-fake.txt", cmd: "go doc ./pkg/platformapi/platformapifake Server | tail -n +3")

Because it is a handler, callers choose how to serve it:
`httptest.NewTestServer` in a `synctest` bubble, `httptest.NewServer` in an
ordinary test, or a real `http.Server` for a local demo. Rollouts advance
one replica per poll rather than by wall-clock time, so a test controls
progress by polling and never needs to sleep.

=== Doc comments are the manual

Run `go doc` on the package and you get the package comment followed by an
index of every exported name. For most users, this _is_ the documentation,
and editors show the same text on hover:

#output("ch02/godoc-pkg.txt", cmd: "go doc ./pkg/platformapi")

A few conventions make doc comments work. Start each one with the name it
documents ("Wait polls op until..."), because `go doc` and search results
show the first sentence on its own. Document what the caller can't see:
that `Wait` returns the final state _together with_ an `*OperationError`
when a rollout fails, that cancelling a context doesn't cancel a
deployment, that the zero `Client` isn't usable. Square brackets create doc
links (Go 1.19): `[Client.Wait]` and `[errors.Is]` in the package comment
become hyperlinks on pkg.go.dev and in gopls, and plain text in the
terminal. `go doc ./pkg/platformapi Client.Wait` prints a single method's
documentation, and it keeps the source's line breaks in the signature, one
more reason to wrap long signatures by hand.

=== Examples that cannot rot

A function named `Example`, `ExampleClient_ListDeployments` or
`ExampleAPIError` in a `_test.go` file is documentation and a test at once.
`go doc` and pkg.go.dev attach it to the matching identifier, and if it ends
with an `// Output:` comment, `go test` runs it and fails when the printed
output differs:

#src("pkg/platformapi/example_test.go", region: "examplelist")

Because the fake is deterministic, the examples can show real IDs and real
output, and they stay correct as long as the tests pass. Prose in a README
goes stale without anyone noticing. A runnable example fails CI the day it
goes stale.

#newingo("1.27", title: [`go doc` shows examples])[
  `go doc -ex` now lists the executable examples for a package or symbol,
  and passing an example's name prints its source as a complete program,
  ready to paste, followed by its expected output. `go doc` also accepts
  `package@version`, so `go doc example.com/pkg@v1.2.3` shows the
  documentation of a release you haven't upgraded to yet.
]

Here is the example that documents `*APIError`, as a reader at a terminal
sees it:

#output("ch02/godoc-example.txt", cmd: "go doc ./pkg/platformapi.ExampleAPIError")

== Evolving the API without breaking it <sec-api-evolve>

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

The variadic row is the one that surprises people. Adding
`opts ...CallOption` to a method doesn't break a call such as
`client.CreateDeployment(ctx, req)`, but it does break
`f := client.CreateDeployment` assigned to a variable of the old function
type, every interface that lists the method (the `Platform` interface in
`promote`, for example), and every stub that implements it. This is why
every method in `platformapi` took `opts ...CallOption` in its first
release, before there was a single call option to pass. An empty variadic
parameter costs nothing and buys a place to put the next feature.

=== Catching breaking changes mechanically

Reviewers miss these things, so let a tool check them. `apidiff`, from
`golang.org/x/exp`, compares two versions of a package's exported API and
sorts the differences into compatible and incompatible. The repository keeps
two versions of a small deployment API in `examples/ch02/evolve`: `before`
is a plausible first release, and `after` is what it might look like a year
later after changes from several contributors. One of them made
`TokenSource` look like this:

#src("examples/ch02/evolve/after/platform.go", region: "tokensource")

Here is what `apidiff` reports (`fold` wraps its long lines for the page):

#output("ch02/apidiff.txt", cmd: "go run golang.org/x/exp/cmd/apidiff@latest \\\n    ./examples/ch02/evolve/before ./examples/ch02/evolve/after | fold -s -w 92")

Every incompatible line is a lesson from the table. `CreateDeployment` and
`NewClient` gained variadic parameters. `DefaultPollInterval` changed value,
so code that used it as a deadline now waits longer. `Status` was renamed to
`State` with a new type. `TokenSource` gained a method, where the optional
`TokenInvalidator` from @sec-api-interfaces would have been compatible. And
`Deployment` gained a `Labels map[string]string` field, which no reviewer
would flag but which makes the struct non-comparable: any consumer that
wrote `if old == cur` or used a `Deployment` as a map key no longer
compiles.

In CI, run `apidiff` against the last release on every pull request that
touches the SDK. `apidiff -w old.api <import path>` writes the API of a
checked-out tag to a file, and `apidiff old.api <import path>` compares the
working tree against it. Fail the build on incompatible changes unless the
change is going into a new major version. `gorelease`, also in
`golang.org/x/exp`, wraps the same analysis around module versions and
suggests the next semantic version number for a release.

=== Deprecation

When an API has to go, deprecate it first and remove it in the next major
version, if ever. A paragraph starting with `Deprecated:` in the doc comment
is the convention every Go tool understands:

#code(file: "examples/ch02/evolve/after/platform.go")[```go
// ListDeployments returns every deployment of service.
//
// Deprecated: Use Deployments, which fetches pages on demand.
func (c *Client) ListDeployments(ctx context.Context,
	service string) ([]Deployment, error) {
```]

Staticcheck's SA1019 check, which runs in `golangci-lint`'s default set,
reports uses of deprecated identifiers from other modules, so consumers find
out at their next lint run while the SDK's own tests can keep exercising the
old function. gopls renders deprecated names with a strikethrough, and
pkg.go.dev collapses them in its index. Say what to use instead, keep the
deprecated function working (ideally by implementing it in terms of its
replacement), and use the User-Agent data from @sec-api-config to see when
its last caller is gone.

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
  consumer. When `platformapi` started using generic methods it required
  Go 1.27, and every module that imports it now needs a Go 1.27 toolchain to
  build. Raise the `go` line deliberately and announce it like any other
  breaking change. From Go 1.27, `go test` runs vet's `stdversion` check by
  default, which reports uses of standard library symbols that are newer
  than the `go` line allows, so an SDK can't raise its effective minimum by
  accident.
]

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
and accepts an `*http.Client`, which is the hook for OpenTelemetry's
instrumented transport. None of this requires the SDK to import a metrics
or tracing library, so it never forces a version of one on its consumers.

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

The whole SDK, its fake, the tour and the `promote` consumer pass their
tests under the race detector:

#output("ch02/test-all.txt", cmd: "go test -race ./pkg/platformapi/... ./examples/ch02/...")

#takeaways(
  [Count the cost of a breaking change in consumer releases, not in your own diff. Under minimal version selection, consumers get your newest minor version whether they asked for it or not.],
  [Return concrete types and let consumers declare small interfaces. Interfaces the SDK _consumes_ (`TokenSource`, `Limiter`) belong in the SDK, take a context, and have one method.],
  [Grow interfaces with optional interfaces checked by type assertion, never by adding methods to an interface others implement.],
  [Required settings are parameters; everything else is a validated functional option over an unexported config, so a built client can't be reconfigured. Constructors do no I/O.],
  [Every method takes a context and the client stores none. Cancelling a wait doesn't cancel the server-side work; document that and give callers a way to cancel it.],
  [Generate idempotency keys and request IDs once per call, outside the retry loop. Classify every status as retryable or permanent, and honour `Retry-After`.],
  [Paginate with `iter.Seq2[T, error]`: lazy, constant memory, and `break` stops the requests.],
  [Use generics to move values around (decode, page, poll, collect). Go 1.27 generic methods fit helpers on concrete types, but they can't satisfy interfaces, so keep core methods non-generic.],
  [Treat docs and examples as API: `// Output:` examples, a published fake, `// Deprecated:` paragraphs, and `apidiff` in CI against the last release.],
)

#exercises(
  [*A caching token source.* Implement a `TokenSource` that wraps a fetch function returning a token and its expiry time, and that also implements `TokenInvalidator`. It should refresh a minute before expiry, collapse concurrent refreshes into one with `singleflight` (Chapter 4), and ignore invalidations of tokens it has already replaced. Test it in a `synctest` bubble with 100 concurrent callers and a rotation in the middle.],
  [*Resumable scans.* A nightly job lists 200,000 deployments and sometimes crashes halfway. Design a compatible addition that lets it resume from where it stopped: a `PageToken` call option, a `ListDeploymentsPage` method, or something else. Implement your choice, run `apidiff` to prove it is compatible, and argue why the other options are worse.],
  [*`apidiff` in CI.* Write a script that checks out the latest `v1.*` tag into a temporary worktree, writes its export data with `apidiff -w`, compares the working tree against it, and fails on incompatible changes unless the module path ends in a new major version. Then make a compatible change and an incompatible one and show the script's output for both.],
  [*A request hook.* Add an option that lets callers observe every attempt (call, status, duration, attempt number, request ID) for metrics, without importing a metrics library. Compare a callback option with documenting an `http.RoundTripper` wrapper. Which survives better if the platform later moves to gRPC?],
  [*Designing v2.* The platform team wants `CreateDeployment` to accept a list of environments and return one operation per environment. Write the `/v2` signature, implement v1's `CreateDeployment` on top of it in a forwarding layer, and use type aliases where you can. Which v1 types can't be aliases, and why?],
)
