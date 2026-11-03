#import "../../template/book.typ": *

#solutions-for(2, "Designing Go APIs That Last")

Every code exercise in Chapter 2 starts from the finished SDK, step 9 of
the build. Copy the acceptance tests from `workbook/ch02/exercises/exK` into
your `platformapi` directory and watch them fail (most fail to compile,
because they use names you haven't written yet) before you start. When you
are done, `go test -race ./...` and `golangci-lint run ./...` should both be
clean, and the tests you had before must still pass.

#solution(2, 1, title: [Two more sentinels], code: "solutions/ch02/ex1")[
  Two variables and two cases in the `Is` method are the whole change:

  #src("solutions/ch02/ex1/errors.go", region: "errors")

  The second test is the interesting one. After two 429s, the error the
  caller gets is a `*retry.ExhaustedError`, which wraps the last
  `*APIError`. `errors.Is` walks the chain: it asks the exhausted error
  (no `Is` method, not equal to the sentinel), unwraps it, and asks the
  `*APIError`, whose `Is` says yes. Nothing in the retry package had to
  know about sentinels; implementing `Unwrap` was enough. That is why
  wrapping errors is better than replacing them.

  Sentinel names are API, so they get the same care as functions. Each new
  one is a promise that the SDK will keep mapping that condition to that
  value, and a reason for callers to write a branch. Add them for the
  conditions callers act on differently: a 401 means "fix your
  credentials", a 429 that survived retries means "back off for longer".
  Don't add one per status code.

  A map from sentinel to status looks neater than a `switch`:
  `code, ok := sentinels[target]`. It panics. `errors.Is` passes whatever
  target the caller gives it, and a map lookup hashes its key, which
  fails at run time for an error whose dynamic type is a slice, such as a
  `multiError []error` from some other library:

  #output("ch02/ts/ex1-unhashable.txt")

  The `switch` compares with `==` against each sentinel, and comparing an
  interface holding an uncomparable value with a sentinel of a different
  type is simply false, with no panic. The capture script makes this
  mistake on a copy of the solution and keeps the evidence.
]

#solution(2, 2, title: [`Take`], code: "solutions/ch02/ex2")[
  `Take` wraps one iterator in another. It ranges over `seq` and stops
  ranging as soon as it has what it needs:

  #src("solutions/ch02/ex2/list.go", region: "take")

  Stopping is the point. When `Take`'s loop returns, the `yield` that
  `list` was calling returns `false`, and `list` returns without fetching
  the next page. With a page size of 3, taking 4 items fetches two pages
  and never asks for the third, which is what `TestTakeStopsFetching`
  counts on the fake.

  Three details are easy to miss. The `n <= 0` check must come before the
  loop: the first iteration of `range seq` is what sends the first request,
  so checking inside the loop sends one request too many. The check on
  `err` after `yield` ends the sequence after an error even if the
  consumer's loop `continue`s past it, the same rule `list` follows. And
  `Take` is a generic function, not a method: it works on any
  `iter.Seq2[T, error]`, including the hand-written one in
  `TestTakeWorksOnAnyIterator`, and it needs no client.
]

#solution(2, 3, title: [Judge seven changes])[
  Here are the seven changes, judged against the table in the lab, and then
  what `apidiff` said when the capture script made all of them in a copy of
  step 9.

  + *`Environment.Labels map[string]string`: breaking.* Adding a field is
    usually safe, but a map field makes the struct non-comparable, so
    `if a == b` and maps keyed by `Environment` stop compiling.
  + *`StateCancelled` becomes `"canceled"`: breaking.* The constant's name
    is the same, so every caller compiles. But a value stored in a
    database or compared with a string from a log no longer matches, and
    the server still sends `"cancelled"`. This is the most dangerous change
    on the list because only a tool or a test can see it.
  + *`PageSize(n int32)`: breaking.* `PageSize(50)` still compiles, because
    an untyped constant converts to any integer type. `PageSize(n)` with an
    `int` variable doesn't, and neither does a function value of the old
    type.
  + *`Limiter.Tokens() float64`: breaking.* Every limiter a caller wrote,
    including `countingLimiter` in the SDK's own tests, stops satisfying
    `Limiter`. `*rate.Limiter` happens to have `Tokens`, which makes the
    change look harmless in review.
  + *`TokenSourceFunc.String`: compatible.* Adding a method to a concrete
    type breaks nothing that compiled before.
  + *`Client.GetOperation`: compatible*, for the same reason. It would
    break an exported interface listing `*Client`'s methods, which is one
    more reason the SDK doesn't have one (exercise 2.6).
  + *`Operation[T].Labels`: breaking*, for the same reason as the first.
    `Operation[T]` was comparable for every `T`, because its result is a
    pointer.

  #output("ch02/ex3-apidiff.txt", cmd: "apidiff ../v1.api .")

  `apidiff` agrees on all seven. It reports the value change of
  `StateCancelled` because the constant is exported; it would not
  notice if the same rename happened in a string literal inside a function.
  Behaviour changes need tests. A test that pins the JSON value of every
  state against the API's documentation would have caught the second
  change before `apidiff` ran.

  How to make the breaking ones compatible: put labels behind a method
  (`(*Environment).Labels() map[string]string`) or accept that
  comparability is part of the API and say so in the type's comment.
  Fix the spelling with a second constant and a `Deprecated:` note, if at
  all. Leave `PageSize` alone. Give `Tokens` its own optional interface.
]

#solution(2, 4, title: [Observe every attempt], code: "solutions/ch02/ex4")[
  The option and its record type go in a file of their own:

  #src("solutions/ch02/ex4/observe.go", region: "observe")

  `config` gains a field, `observe func(Attempt)`, and `do` calls it after
  each attempt, inside the function the retry policy runs:

  #src("solutions/ch02/ex4/transport.go", region: "do")

  The status comes from the response when there is one, from the
  `*APIError` when the server answered with an error, and is 0 for a
  network failure, where no status exists. `n` counts attempts in the
  closure, so the observer and the retry log agree on numbering. The
  callback runs synchronously on the caller's goroutine. That makes it
  cheap and lets the tests append to a slice without a lock, and the doc
  comment tells users the cost: a slow observer slows every call, and a
  shared client calls it from many goroutines at once.

  *Callback or `RoundTripper`?* A transport decorator sees every HTTP
  exchange, including the second send after a token refresh, which the
  observer doesn't. But it sees HTTP, not calls: it doesn't know the
  attempt number, it can't tell a retry from a new call except by the
  request ID header, and it never sees failures that happen before a
  request is sent, such as the limiter refusing or a token fetch failing.
  The callback speaks the SDK's own vocabulary. If the platform moves to
  gRPC, a `RoundTripper` is useless (gRPC has its own interceptors), while
  `WithObserver` keeps its meaning: the SDK would fill in `Attempt` from a
  gRPC status instead of an HTTP one. Prefer the callback for SDK-level
  facts, and keep `WithHTTPClient` for transport-level ones like TLS and
  tracing.
]

#solution(2, 5, title: [A caching token source], code: "solutions/ch02/ex5")[
  The state is a token, the time to refresh it, and a channel that exists
  while a fetch is running:

  #src("solutions/ch02/ex5/caching.go", region: "caching")

  `Token` loops: use the cached token if it is still fresh, wait for a
  fetch that is already running, or start one.

  #src("solutions/ch02/ex5/caching.go", region: "token")

  The lock is never held during the fetch, which can take seconds. While a
  fetch runs, `inflight` is a channel that `refresh` closes when it ends,
  and closing a channel wakes every goroutine waiting on it at once. A
  waiter then goes round the loop again instead of assuming success: if
  the fetch failed, nothing was cached, and the next caller starts a new
  fetch. That is what `TestCachingTokenSourceDoesNotCacheErrors` checks.
  Each waiter selects on its own context too, so an impatient caller gives
  up at its own deadline while the fetch carries on for everyone else.

  `singleflight.Group` from Chapter 4 would collapse the fetches with less
  code, but its `Do` blocks without a context. Its `DoChan` returns a
  channel you can `select` on, which would work, at the cost of a
  dependency on `golang.org/x/sync`. The fetch itself runs on the context
  of the caller who started it. If that caller gives up, the fetch fails
  for everyone waiting, and the next caller retries; running the fetch on
  `context.WithoutCancel(ctx)` with its own timeout avoids that, and is
  worth it when the identity provider is slow.

  `InvalidateToken` compares before it clears. Ten requests that failed
  with `tok-1` report it ten times, possibly after the first report already
  caused `tok-2` to be fetched. Only a report about the current token may
  clear it.
]

#solution(2, 6, title: [Review an interface])[
  A review that gets this change rejected names concrete costs.

  *What breaks now.* Changing `New` to return an interface is itself
  breaking. Every caller that stored a `*platformapi.Client` in a struct
  field or passed one to a function with that parameter type stops
  compiling. Worse, interfaces can't have generic methods, so `Poll` and
  `Wait` can't be on `PlatformClient` at all. They would have to become
  package-level functions or non-generic, deployment-only methods, and
  `promote.Client`, which embeds the client to reach `Wait[T]`, would stop
  compiling too.

  *What breaks later.* The next method the platform team adds, say
  `GetOperation`, breaks every type that implements `PlatformClient`: every
  generated mock in 50 repositories, and every wrapper that adds logging.
  The SDK can then never add a method in a minor release, which is the one
  kind of change that should always be free.

  *What it costs readers.* `go doc` shows one wall of signatures, and
  "go to definition" in an editor lands on the interface, not the code.

  *What to do instead.* Each consumer declares the interface it needs,
  next to the code that needs it, as `promote` does with `Platform`: three
  methods, a stub that fits in twenty lines, and a test that reads like a
  specification. For the wire format, tests use `platformapifake`, which
  the platform team keeps correct. A consumer that needs a method the
  interface doesn't have adds it to its own interface, and nobody else
  notices.

  One sentence for the review: the SDK returns a concrete type so it can
  grow, and consumers declare interfaces so they can test.
]

#solution(2, 7, title: [Wait for many], code: "solutions/ch02/ex7")[
  One goroutine per operation, a buffered channel as a semaphore, and a
  `WaitGroup` that the method waits on before it returns:

  #src("solutions/ch02/ex7/waitall.go", region: "waitall")

  Each goroutine owns index `i` of both slices, so no lock is needed, and
  `wg.Wait` makes their writes visible to the caller. Collecting errors by
  index gives `errors.Join` the order of `ops`, and `Join` skips the `nil`s.
  `wg.Go` (Go 1.25) calls `Add` and `Done` for you, and since Go 1.22 each
  iteration of the loop has its own `i` and `op`, so the closures capture
  the right ones.

  A goroutine waits for a slot with a `select` that also watches the
  context, so cancelling `ctx` releases goroutines that never got to start,
  and they report `context.Cause(ctx)` as their error. The ones that did
  start return from `Wait` at their next sleep. Either way every goroutine
  has finished before `WaitAll` returns, so none outlives the call, which
  is the property Chapter 4 calls _structured concurrency_.

  The tests check the arithmetic exactly in virtual time. With no limit,
  the call takes as long as the slowest rollout: search needs 6 polls, so 5
  sleeps of 2 seconds. With a limit of 1, the rollouts run one after
  another, and the sleeps add up to 22 seconds. A version that started all
  goroutines but ignored `limit` passes the first test and fails the
  second; one that polled in a single goroutine fails the first.

  `WaitAll` is a generic method, so like `Wait` it can't appear in an
  interface. A consumer that wants to stub it declares a non-generic
  method in its own adapter, the same way `promote.Client` adds
  `WaitDeployment`.
]
