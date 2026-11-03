#import "../../template/book.typ": *

#solutions-for(3, "Errors, Exit Codes, and Failure as a Feature")

Every code exercise in Chapter 3 starts from the finished step 8 module.
Copy the acceptance tests from `workbook/ch03/exercises/exK` into your
`deployctl` directory, keeping their subdirectories, and watch them fail
before you start. When you are done, `go test -race ./...` and
`golangci-lint run ./...` should both be clean, and the tests you had before
must still pass, golden files included.

#solution(3, 1, title: [Predict the exit code])[
  Walk @fig-err-codeof from the top for each error, stopping at the first
  rule that matches:

  #table(
    columns: (auto, auto, 1fr),
    table.header([Error], [Code], [Why]),
    [(a)], [75], [`os.ErrDeadlineExceeded` has `Timeout() == true`, and `%w` keeps it in the chain.],
    [(b)], [2], [An explicit `Code` beats inference, even though the cause is a timeout. This is the order step 4 tests with "explicit beats inferred".],
    [(c)], [1], [`%v` cut the chain. The message says "context deadline exceeded" and no rule can see it.],
    [(d)], [143], [The `*SignalError` check comes before the `*Error` check, so the signal decides, as it should for a stopped run: 128 + 15.],
    [(e)], [1], [The trap. See below.],
  )

  In (e) the tree holds a `context.DeadlineExceeded`, so you might expect
  75. But `AsType[timeouter]` returns the _first_ error in the tree that has
  a `Timeout` method, and `*fs.PathError` has one (it reports whether the
  error inside it is a timeout). The `PathError` comes first in depth-first
  order, its `Timeout()` is `false`, and `CodeOf` moves on without ever
  looking at the deadline. Neither of the last two rules matches, so the
  answer is 1.

  The rows that pin these down go in `TestCodeOf`'s table:

  #code(file: "pkg/clierr/clierr_test.go")[```go
  {"os deadline", fmt.Errorf("upload: %w", os.ErrDeadlineExceeded),
  	clierr.ExitTempFail},
  {"explicit beats timeout",
  	&clierr.Error{Code: clierr.ExitUsage, Err: context.DeadlineExceeded},
  	clierr.ExitUsage},
  {"%v cuts the chain", fmt.Errorf("deploy: %v", context.DeadlineExceeded),
  	clierr.ExitFailure},
  {"signal inside Error", &clierr.Error{Message: "stopped",
  	Err: &clierr.SignalError{Signal: syscall.SIGTERM}}, 143},
  {"first timeouter wins", errors.Join(&fs.PathError{Op: "open",
  	Path: "a", Err: fs.ErrNotExist}, context.DeadlineExceeded),
  	clierr.ExitFailure},
  ```]

  Is (e) a bug in `CodeOf`? For `deployctl` it is harmless: a joined error
  only reaches `CodeOf` inside an `*Error` with an explicit code. As a
  general rule it is worth knowing that `AsType` with an interface answers
  "what does the first error with this method say?", not "does any error in
  the tree say yes?". If you need the second question answered, walk the
  tree (Exercise 3.3 writes the walker) and check every match.
]

#solution(3, 2, title: [Did you mean?], code: "solutions/ch03/ex2")[
  The suggestion lives in a new file, `cmd/deployctl/suggest.go`, and `run`'s
  last line becomes `return unknownCommand(cmd)`. The error keeps the shape of
  every other usage error, with a longer hint:

  #src("solutions/ch03/ex2/cmd/deployctl/suggest.go", region: "unknown")

  The distance is the classic Levenshtein dynamic program, kept to two rows:

  #src("solutions/ch03/ex2/cmd/deployctl/suggest.go", region: "closest")

  `cur[j]` is the cheapest way to turn `a[:i]` into `b[:j]`: delete `a[i-1]`
  (`prev[j]+1`), insert `b[j-1]` (`cur[j-1]+1`), or substitute, free when the
  bytes are equal. A transposition such as `deplyo` costs two substitutions,
  which is why the limit is two: one would miss the most common typo. A limit
  of three would suggest `init` for `ls`, and a wrong suggestion is worse than
  none, because it sends the user to read about a command they didn't want.

  The suggestion goes _first_ in the hint because it is the likelier fix, and
  the `-h` advice stays because the suggestion may be wrong. The test's last
  case, `frobnicate`, checks that nothing is suggested when nothing is close.
  Comparing bytes is fine for command names, which are ASCII; for user input
  in general, compare runes.
]

#solution(3, 3, title: [Every request ID], code: "solutions/ch03/ex3")[
  `All` is `Chain`'s walk with a type test instead of `%T`, in a new file
  `pkg/clierr/all.go`:

  #src("solutions/ch03/ex3/pkg/clierr/all.go", region: "all")

  The type assertion `err.(E)` is what `errorlint` warns about, and here it is
  exactly right: the walk visits every node itself, and asks about each one.
  It also works for interface types, because asserting to an interface asks
  whether the value has the methods. Like `errors.As`, it visits a node
  before its children, so an error that matches and also wraps a match
  contributes both. In `rolloutError`, after building `e`:

  #src("solutions/ch03/ex3/cmd/deployctl/deploy.go", region: "ids")

  The failures are already in the order the report lists them, and `All`
  walks the joined error in that order, so the IDs line up with the detail
  lines.

  Then `TestExitCodes` fails on the `partial` golden file, and the reason is
  the point of the exercise: request IDs are random, so the stderr of a
  partial failure is different on every run. Running `-update` would only
  move the failure to the next run. A golden file can only hold what is
  stable, so the test masks what isn't, before comparing:

  #src("solutions/ch03/ex3/cmd/deployctl/main_test.go", region: "scrub")

  Then `-update` once, and the golden file shows
  `quote req-XXXXXXXXXX, req-XXXXXXXXXX`: two IDs, in the right place, with
  the parts that change masked. The alternative, making the fake API's IDs
  deterministic, is also reasonable, but it makes the test depend on a detail
  of the fake rather than on what users see.
]

#solution(3, 4, title: [Say where], code: "solutions/ch03/ex4")[
  `loadConfig` passes the data and the error to a new function in place of
  the fixed hint: `jsonHint(data, err)`. It lives in
  `cmd/deployctl/jsonpos.go`:

  #src("solutions/ch03/ex4/cmd/deployctl/jsonpos.go", region: "hint")

  Both decoder errors carry an `Offset`, the number of bytes the decoder had
  read when it gave up. For `["us-east-1",]` that includes the `]` it
  couldn't accept, so the byte to point at is `data[offset-1]`:

  #src("solutions/ch03/ex4/cmd/deployctl/jsonpos.go", region: "position")

  Columns count from 1 after the last newline before that byte. When there is
  no newline, `LastIndexByte` returns -1, which gives the right column for
  free. `min` and `max` keep a nonsensical offset from slicing out of range;
  an `Offset` of 0 would otherwise produce `data[:-1]`.

  The type error needs translating more than locating. Its message, `json: cannot unmarshal string into Go struct field Config.targets of type []string`, is written for the programmer who wrote `Config`. The user wrote
  the JSON, so the hint uses the field name as it appears in the file
  (`Field` comes from the struct tag) and describes the type in JSON's terms:
  `"targets" must be a list, not a string`. Everything else falls back to the
  old hint, so an error the code doesn't recognize is never made worse.
]

#solution(3, 5, title: [Honour `Retry-After`], code: "solutions/ch03/ex5")[
  `APIError` gains `RetryAfter time.Duration`, and `send` fills it when it
  builds the error: `RetryAfter: retryAfter(resp.Header.Get("Retry-After"))`.
  The header has two forms, both parsed by the standard library:

  #src("solutions/ch03/ex5/cmd/deployctl/client.go", region: "retryafter")

  In `do`, the wait is chosen just before sleeping, after the check for the
  last attempt:

  #src("solutions/ch03/ex5/cmd/deployctl/client.go", region: "wait")

  The server's value replaces the backoff, it doesn't add to it: the server
  knows when it expects to recover, and our doubling was only a guess. The
  backoff still doubles underneath, so an answer without the header later
  in the same call doesn't fall back to the first, shortest pause.

  The deadline check is what keeps the client honest. Without it, a
  `Retry-After: 30` inside a 5-second `-timeout` sleeps until the context
  ends and reports a timeout, which tells the user less than the truth:
  the API asked for 30 seconds. Returning the `RetryError` at once keeps the
  `*APIError`, and its `RetryAfter`, in the chain, so `targetError` or a
  caller can say how long the API wanted. Exercise 3.3's `All` would let a
  partial-failure hint report the longest wait.

  The acceptance tests run in a `synctest` bubble, where `time.Sleep` and
  `time.After` advance a fake clock as soon as every goroutine in the bubble
  is blocked. That is why the first test can demand exactly four seconds and
  the second exactly zero: in a bubble, durations are deterministic.
  `httptest.NewTestServer` serves over an in-memory network that belongs to
  the bubble, so the client's requests don't escape it.
]

#solution(3, 6, title: [`%w` or `%v`?])[
  Start with who decides what, today.

  *`send`'s decode error* wraps `*json.SyntaxError` or `*json.UnmarshalTypeError`
  with `%w`. No caller in `deployctl` inspects it; it is printed. Today the
  wrapping costs nothing, but if `Client` moved into a shared package,
  someone would write `errors.AsType[*json.SyntaxError]` to detect "the API
  sent garbage", and the client could never switch to another decoder (or to
  `encoding/json/v2`'s error types) without breaking them. For a shared
  package, use `%v`, or better, define a sentinel such as `ErrBadResponse`
  and wrap _that_, so callers get a decision they can rely on and you keep
  the freedom to change the decoder.

  *`do` returns `*url.Error` as it is.* That is an implementation detail too,
  but one with a useful contract underneath: `*url.Error` has `Timeout()`, and
  it wraps the context's cause, which `targetError` depends on
  (`errors.Is(err, context.Cause(ctx))`) and `CodeOf` depends on (the
  `Timeout` behaviour). Switching to `%v` would break both, silently: the
  deadline would stop mapping to 75, and an interrupted request would print
  the raw chain. Keep it wrapped. In a shared package, document the two
  behaviours callers may depend on (timeouts and context errors are
  recognizable with `errors.Is` and `Timeout()`), not the type.

  *`loadConfig` keeps the `*fs.PathError`.* `CodeOf` needs it: an unreadable
  file gets 77 because `errors.Is(err, fs.ErrPermission)` sees through the
  `PathError` to `EACCES`. Hiding it would turn every permission problem into
  exit 1. Errors from `os` are also about as stable as error types get, so
  making them part of the API costs little.

  An error that should stay opaque: the one from `json.Marshal` in `send`, or
  from `http.NewRequestWithContext`. Both mean a bug in `deployctl` (a body
  that can't be encoded, a base URL that can't be parsed); no caller can do
  anything useful with their types, and exposing them only invites someone
  to depend on them. The general rule: wrap with `%w` when a caller has a
  decision to make with the cause, and say which decision in a comment;
  otherwise use `%v`.
]

#solution(3, 7, title: [Stop after N failures], code: "solutions/ch03/ex7")[
  `deploy` gets the flag and its validation, next to `-parallel`:

  #code(file: "cmd/deployctl/deploy.go")[```go
  maxFail := fs.Int("max-failures", 0, "start no more targets after `N` "+
  	"failures (0: no limit)")
  // ...
  if *maxFail < 0 {
  	return usageError(errors.New("-max-failures must not be negative"),
  		"deploy")
  }
  ```]

  and passes `*maxFail` to `rollout`, which changes in three ways:

  #src("solutions/ch03/ex7/cmd/deployctl/deploy.go", region: "rollout")

  First, the loop that reads results now frees the slots, not the workers.
  That is the whole trick. In step 8 a worker frees its slot itself, after
  sending its result, so the starter can take the slot and start the next
  target _before_ the loop has looked at the result that would have stopped
  it. With `-parallel 1`, whether a target starts after the limit would
  depend on scheduling. Here the loop closes `stop` first and frees the slot
  second, and the starter checks `stop` only after it has the slot. A
  channel receive happens after the matching send, so when the starter gets
  the slot, the close is already visible to it. No timing can reorder that.

  Second, `stop` is a channel that is closed, not sent on. A close is seen by
  every receiver, any number of times, and `closed` checks it without
  blocking. The loop closes it exactly once, on the failure that reaches the
  limit; with `maxFail` 0, `nFailed == maxFail` is never true after an
  increment, so there is no limit.

  Third, the skipped targets travel through the same channel as everything
  else, after `wg.Wait`, so the loop owns them too: it counts them, wraps
  them with `targetError` like any failure, and prints them. `ErrSkipped` is
  a sentinel because callers need exactly one fact from it, and
  `errors.Is(err, ErrSkipped)` is how `printResult` labels the line and how
  the test checks the tree. Skipped targets go into `failed` so `names` puts
  them in the `-only` hint, because they are exactly the targets a re-run
  needs. The headline counts them separately:

  #src("solutions/ch03/ex7/cmd/deployctl/deploy.go", region: "outcome")

  An interrupted rollout counts skipped targets as "not updated", which is
  what they are. One question to think about: should skipped targets change
  the exit code? They don't here. The rollout failed, which is 1, and the
  hint says how to finish it.
]
