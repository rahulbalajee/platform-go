#import "../../template/book.typ": *

#solutions-for(4, "Concurrency Patterns for Production Tooling")

Every code exercise in Chapter 4 starts from the finished step 7 module. Copy
the acceptance tests from `workbook/ch04/exercises/exK` into your `sweep`
directory, keeping their subdirectories, and watch them fail before you start.
When you are done, `go test -race ./...` and `golangci-lint run ./...` should
both be clean, and the tests you had before must still pass.

#solution(4, 1, title: [Count the retries], code: "solutions/ch04/ex1")[
  `Tally` sees every result, so it does the counting, and `String` does the
  printing:

  #src("solutions/ch04/ex1/internal/sweep/report.go", region: "summary")

  The test is specific about three things, and each one is a decision.
  "Retried" means "needed more than one attempt", whatever the final status,
  so the check is on `r.Attempts`, not on `r.Status`. The new count goes after
  the down count and before the cancelled count, so the line still reads from
  most to least important. And a zero count prints nothing, which keeps the
  summary of a clean run exactly as it was: scripts and the golden files in
  Chapter 6 compare that line.

  The trap is the receiver. `Tally` already has a pointer receiver; if you add
  a second method to do the counting, give it one too, or it will count on a
  copy and the test will report `Retried = 0`. The JSON key comes from the
  struct tag, and the test checks it, because other people's dashboards will.
]

#solution(4, 2, title: [Collect every error], code: "solutions/ch04/ex2")[
  The semaphore shape from @sec-bounded, with one slot per item for results
  and one for errors:

  #src("solutions/ch04/ex2/conc/mapall.go")

  Each goroutine owns index `i` of both slices, so no lock is needed, and
  `wg.Wait` makes the writes visible to the caller, exactly as in `Map`.
  Collecting errors by index, rather than appending to a shared slice, also
  gives the input order the test asks for: `errors.Join` keeps the order of
  its arguments and skips `nil`s, and returns `nil` when they are all `nil`.

  Copying `Map` and changing the return statement doesn't work, and the test
  is built to catch it. `errgroup.WithContext` cancels the group's context on
  the first failure, so the calls started after it see a cancelled context;
  the test's function returns `ctx.Err()` in that case, and the joined error
  then contains `context canceled` lines. A plain `errgroup.Group` (no
  `WithContext`), with every `Go` function returning `nil`, would also work.
  It reads oddly, because the group's own error handling goes unused, which
  is why the solution uses a `WaitGroup`.

  `MapAll` doesn't watch `ctx` while it waits for a slot. If the context is
  cancelled, every remaining call still starts, gets a cancelled context and
  (if it is well behaved) returns at once. For a collect-all helper that is
  acceptable: each item gets a result, even if it is "cancelled".
]

#solution(4, 3, title: [Which limit binds?], code: "solutions/ch04/ex3")[
  Turn each limit into a ceiling in checks per second; the lowest ceiling
  decides. A check that takes 100 ms holds a slot for 100 ms, so a limit of
  _N_ concurrent checks allows _N_ / 0.1 s = 10 _N_ checks per second.

  (a) Three hosts at four checks each allow 12 at a time: 120 per second.
  `-c 32` allows 320 per second. The rate limit allows 50 per second after a
  burst of 5. The rate limit binds: (300 − 5) / 50 = 5.9 s of tokens, plus the
  last check's 100 ms, is 6 seconds.

  (b) Without the rate limit, the per-host limit binds: 12 at a time, 25
  rounds of 100 ms, 2.5 seconds.

  (c) With 300 hosts the per-host limit never applies, so `-c` binds: 32 at a
  time, 10 rounds (the last one partial), 1 second.

  (d) Two hundred instant answers from one host: the per-host limit allows 4
  at a time, but each takes no time, so only the rate limit matters:
  (200 − 5) / 50 = 3.9 seconds. Against the fake fleet:

  #output("ch04/ex3-rate.txt", cmd: "go run ./cmd/sweep -o jsonl ok200.txt > /dev/null")
  #output("ch04/ex3-norate.txt", cmd: "go run ./cmd/sweep -o jsonl -rate 0 ok200.txt > /dev/null")

  You can check the other three without 300 real hosts. The solution module
  adds a test that sweeps fake targets in a `synctest` bubble and measures
  virtual time. It builds inventories of fake hosts:

  #src("solutions/ch04/ex3/internal/sweep/limits_test.go", region: "inventory")

  runs a sweep in a bubble against a prober that sleeps:

  #src("solutions/ch04/ex3/internal/sweep/limits_test.go", region: "sweeptime")

  and asserts the four answers, plus one more:

  #src("solutions/ch04/ex3/internal/sweep/limits_test.go", region: "scenarios")
  #output("ch04/ex3-sim.txt", cmd: "go test -v -run TestWhichLimitBinds ./internal/sweep 2>&1 | grep -E 'limits_test|^ok'")

  The extra row is the trap. The same 300 targets, listed host by host instead
  of taking turns, take 6.1 seconds instead of 2.5. `Stream` admits targets in
  input order, so its 32 slots fill with targets of the first host, 28 of which
  wait for one of that host's 4 slots. Hosts two and three sit idle until the
  first host's targets have all been admitted. The global limit is held by
  checks that are only waiting. Fixing it means admitting targets in an order
  that interleaves hosts, or taking the host slot before the global one; both
  have costs, and the second needs a scheduler that can skip ahead in the
  input. Most real inventories are grouped by host, because people write them
  by service, so this is worth knowing before you tune `-c`.
]

#solution(4, 4, title: [Fail fast], code: "solutions/ch04/ex4")[
  A `failFast` field in `options`, a flag (`fs.BoolVar(&o.failFast, "fail-fast", false, "stop at the first failed target")`), and this change
  to the loop in `run`:

  #src("solutions/ch04/ex4/cmd/sweep/main.go", region: "ex4")

  `break` does all the work. It makes `yield` return `false` inside `Stream`,
  which closes `consumerGone`, cancels the context of the checks in flight,
  and waits for every worker to exit before the `for` statement finishes.
  That is rule zero paying off: the caller wrote one keyword, and the test's
  `goleak.VerifyNone` and its two-second bound both pass, although three
  checks were hanging on a server that never answers. Against the fake fleet,
  the 404 from `/missing` ends the sweep before `/down` has finished its
  retries:

  #output("ch04/ex4-run.txt", cmd: "go run ./cmd/sweep -fail-fast fleet.txt")

  The exit status falls out of the existing logic: `Healthy` requires every
  target to be checked, so a stopped sweep is never healthy, and the status
  is 1. The context wasn't cancelled, so `sum.Interrupted` stays false, which
  is right: nobody pressed #kbd("Ctrl-C").

  Two alternatives are worth rejecting. Cancelling the run's context instead
  of breaking would report the in-flight checks as `cancelled` and make the
  sweep look interrupted. And stopping on the first failed _attempt_, inside
  the runner, would defeat the retry policy: `/flaky` fails twice before it
  comes up.
]

#solution(4, 5, title: [A time budget for retries], code: "solutions/ch04/ex5")[
  The field, with a comment that says what zero means:

  #src("solutions/ch04/ex5/retry/retry.go", region: "policy")

  and three lines in `Do`, between computing the delay and sleeping:

  #src("solutions/ch04/ex5/retry/retry.go", region: "do")

  The check uses the delay `backoff` already chose, so it accounts for jitter
  and for `Retry-After`: if the server asks for 30 seconds and the budget has
  10 left, `Do` gives up now rather than sleep 30 seconds to give up later.
  That is what "never sleep just to give up" in the test means, and the
  bubble checks it exactly: the time between the end of the last attempt and
  the return of `Do` must be zero.

  The budget limits when attempts _start_, not when they end, which is why
  the test allows 5.5 seconds for a 5-second budget with half-second
  attempts. To bound the whole call, including the last attempt, give `Do` a
  context with a deadline instead: `context.WithTimeout(ctx, budget)`. The two
  compose, and they answer different questions. A context deadline says "I
  need an answer by then". `MaxElapsed` says "stop trying after this long",
  and returns an `ExhaustedError` that wraps the last real failure instead of
  a context error.

  `start` is taken once, before the first attempt, with `time.Now()`. Inside
  a bubble that is the fake clock, so the production code needs no clock
  parameter to be testable.
]

#solution(4, 6, title: [Why `consumerGone`?])[
  `TestStreamEarlyBreakCancelsAndWaits` fails, and `synctest` explains why:

  #output("ch04/ex6-consumergone.txt", cmd: "go test ./conc 2>&1 | head -3")

  The goroutine dump that follows names the stuck goroutines. Several workers
  are blocked sending a result:

  #output("ch04/ex6-stuck.txt", cmd: "go test ./conc 2>&1 | grep -m 2 -A 1 'chan send'")

  The test breaks out of its loop after three results. The iterator then
  cancels the context and waits on `<-done`. But the workers that were already
  running finish their calls, which return quickly because the context is
  cancelled, and try to send on `results`. The channel is unbuffered and
  nobody will ever receive from it again: the consumer has left the loop. So
  the workers block forever, the producer blocks in `wg.Wait()` waiting for
  them, `done` is never closed, and the iterator blocks on `<-done`. Every
  goroutine in the bubble is waiting for another one, which is a deadlock, and
  `synctest` detects it at once. Outside a bubble, the program would simply
  hang inside the `break`.

  Cancelling the context doesn't help, because the workers are not waiting on
  the context: they finished their work and are blocked on the send. They
  need a second way out of that send, and `case <-consumerGone:` is it.

  Why not `case <-ctx.Done():`? Because the context is also cancelled when the
  _parent_ is cancelled, by #kbd("Ctrl-C") for example, and in that case the
  consumer is still reading and wants every result. With `ctx.Done()` in the
  `select`, a worker whose result and cancellation are both ready would pick
  one at random, and the partial report would randomly miss checks. A test
  like `TestStreamParentCancelStillDeliversStartedResults` then fails only
  sometimes, which is worse than failing every time. Two different events,
  two different channels.
]

#solution(4, 7, title: [Ordered streaming], code: "solutions/ch04/ex7")[
  #src("solutions/ch04/ex7/conc/ordered.go")

  The idea is a queue of _promises_. Each started call gets its own channel
  with a buffer of one, and the producer queues those channels in input
  order. The consumer takes the next channel from the queue and waits on it,
  however many later calls have already finished. Ordering comes from the
  queue; concurrency is untouched, because calls start as soon as there is a
  slot.

  The memory bound is the subtle part. In `Stream`, a call's slot is freed
  when the call returns. Here that would let a slow first item hold up the
  output while every other item runs and piles up finished results, and the
  bounding test would see all five calls started after five seconds instead
  of two. So a slot is freed only when its result has been _yielded_: the
  consumer receives from `sem` after `yield` returns. At most `limit` calls
  are then running or waiting to be yielded, and since every queued channel
  holds a slot, the queue never has more than `limit` entries, so the
  producer's `pending <- out` never blocks.

  The rest is `Stream`'s structure, and it carries over because the two stop
  signals still mean different things. On an early `break`, the consumer
  stops reading `pending`, cancels, and waits for `done`; workers never block,
  because each sends into its own buffered channel, so no `consumerGone` is
  needed. On parent cancellation, the producer stops starting calls, and the
  consumer keeps draining the queue, so every started call is still reported,
  in order.

  Two alternatives fall short. A reorder buffer (a map from index to result,
  flushed whenever the next index arrives) works, but bounding it requires
  exactly the slot rule above; without it, the map can grow to the size of
  the input. And sorting `Stream`'s output at the end isn't streaming at
  all. That is what the table reporter does, deliberately, because it prints
  nothing until the sweep ends anyway.
]
