#import "../../template/book.typ": *

#solutions-for(0, "Go from Zero")

Every code exercise in Chapter 0 starts from the finished Step 14 module.
Copy the acceptance tests from `workbook/ch00/exercises/exK` into your
`logq` directory (keeping their subdirectories), watch them fail, then make
them pass. `go test -race ./...` and `golangci-lint run ./...` should both
be clean when you are done.

#solution(0, 1, title: [Level aliases], code: "solutions/ch00/ex1")[
  The aliases belong in data, not in code, so a map holds them:

  #src("solutions/ch00/ex1/logline/logline.go", region: "solution")

  `ParseLevel` normalizes the name once with `strings.ToUpper` and then
  does two exact lookups: the alias map, and the loop over the real
  levels comparing against `l.String()`. Normalizing first replaces the
  `strings.EqualFold` call, because both the map lookup and the comparison
  now see upper-case text.

  Nothing else changes. `Parse` calls `ParseLevel`, so `WARNING` in a log
  line parses, and so does `-level warning` on the command line, because
  `buildMatcher` calls it too. One function, three behaviours fixed: that
  is the benefit of having one place that knows what a level is.

  Two traps. Do not add the aliases as extra `Level` constants: there are
  still four levels, and `String` must keep printing `WARN`, so JSON
  output and summaries stay consistent. And keep the error message using
  the original `name`, not `upper`, so the user sees what they typed.
]

#solution(0, 2, title: [Percentages per level], code: "solutions/ch00/ex2")[
  The method is one line, because the division-by-zero guard already
  exists in `percent`:

  #src("solutions/ch00/ex2/logline/stats.go", region: "solution")

  `Print` then calls `s.Percent(Error)` for the error share instead of
  calling `percent` itself.

  A value receiver is right: `Percent` only reads. A `Stats` with no
  entries has a nil `Levels` map, and reading a nil map is allowed and
  returns 0, so `Percent` works on the zero `Stats` without any extra
  check. The test compares floating-point results with `!=`, which is safe
  here because 75 and 25 are exact in binary; for shares like one third,
  compare with a tolerance instead.
]

#solution(0, 3, title: [Read it before you run it])[
  The four programs were run exactly as printed, with `package main` on
  line 1 and `import "fmt"` on line 3, so the line numbers in the messages
  count those lines too.

  *(a) Does not compile.* `:=` must declare at least one new variable, and
  `count` already exists:

  #output("ch00/ex3-a.txt")

  The fix is `count = count + 1` (or `count++`). This is the most common
  `:=` mistake. Inside a nested block such as an `if` or a `for`, the same
  line _would_ compile, declaring a second `count` that shadows the first,
  which is worse (Step 13).

  *(b) Does not compile.* `"8080"` is a string constant and `port` is an
  `int`; Go never converts between them:

  #output("ch00/ex3-b.txt")

  To turn text into a number at run time, use `strconv.Atoi`, which
  returns an error for text that is not a number.

  *(c) Compiles, prints `db`, then panics.* The loop runs for `i` = 0 and
  1, and `names[i+1]` is `names[2]` on the second pass, past the end:

  #output("ch00/ex3-c.txt")

  The compiler cannot know the length of a slice in general, so index
  errors are found at run time. This is why Step 2 checks `len` before
  indexing.

  *(d) Compiles and prints `1 0 2`.*

  #output("ch00/ex3-d.txt")

  `counts["WARN"]++` works on a missing key because the missing key reads
  as 0, so the map gains `"WARN": 1`. Reading `counts["ERROR"]` returns 0
  but does _not_ add the key, which is why `len(counts)` is 2. In Python,
  the same program raises `KeyError` on the first missing key.
]

#solution(0, 4, title: [Filter by service], code: "solutions/ch00/ex4")[
  The matcher follows `Contains`, with `strings.EqualFold` for a
  comparison that ignores case:

  #src("solutions/ch00/ex4/match/match.go", region: "solution")

  `Describe` gets one more case that returns `"service=" + string(m)`. This
  is the cost of a type switch noted in Step 11: adding a matcher means
  remembering to update `Describe`, and the test that checks the
  description is what catches you if you forget.

  In `main.go`, one flag:

  #src("solutions/ch00/ex4/main.go", region: "sflag")

  and `buildMatcher` takes the service as a parameter and adds the matcher
  right after the level, so `Describe` prints the parts in the order the
  test expects:

  #src("solutions/ch00/ex4/main.go", region: "build")

  An alternative is to make service filtering part of `Contains`, with a
  field saying what to search; resist it. One type per idea keeps each
  `Match` method trivial and each test small. If you want several
  services at once, a slice of names and `slices.ContainsFunc` with
  `strings.EqualFold` does it.
]

#solution(0, 5, title: [Invert the query], code: "solutions/ch00/ex5")[
  `Not` is a decorator: a small type that holds another `Matcher` and is a
  `Matcher` itself. The type is unexported, and the exported function
  returns it as a `Matcher`, so callers cannot depend on its fields:

  #src("solutions/ch00/ex5/match/match.go", region: "solution")

  `Describe` learns the new type, and recurses for the wrapped matcher:

  #src("solutions/ch00/ex5/match/match.go", region: "describe")

  In `run`, a boolean flag:

  #src("solutions/ch00/ex5/main.go", region: "vflag")

  and one wrap after `buildMatcher`, so `-v` inverts the whole query, not
  just one part of it:

  #src("solutions/ch00/ex5/main.go", region: "invert")

  The trap is precedence. `-v -level error -grep timeout` should mean "not
  (error and timeout)", which is what wrapping the finished `All` gives.
  Wrapping each part instead would give "not error and not timeout", a
  different query. The `-count` test checks the description, which makes
  the difference visible. Note also what `-v` does _not_ invert: bad lines
  are still reported and still not shown, because they are not entries at
  all.
]

#solution(0, 6, title: [Read compressed logs], code: "solutions/ch00/ex6")[
  Only `scanFile` changes, because `scan` already accepts any
  `io.Reader`. Add `compress/gzip` and `strings` to the imports of
  `scan.go`, then:

  #src("solutions/ch00/ex6/scan.go", region: "solution")

  `gzip.NewReader(f)` reads the gzip header immediately, so a file that is
  not gzip data fails right there with `gzip: invalid header`. Wrapping it
  with the file name makes the message useful and keeps the original error
  available to `errors.Is` (it is `gzip.ErrHeader`). Both `defer` calls run
  when `scanFile` returns: first the gzip reader is closed, then the file,
  the reverse of the order they were opened.

  The gzip reader also checks the data's checksum when it reaches the end
  of the stream. A corrupted or truncated file therefore makes a `Read`
  fail, `Scan` return false, and `scanner.Err()` report the problem, so the
  `Err` check from Step 5 covers it. This is the reader composition from
  Step 5's "Streaming" box: file, decompressor and scanner each hold a few
  kilobytes, whatever the size of the file.

  Choosing by file name is simple and predictable. The alternative is to
  sniff the first two bytes for gzip's magic number (`0x1f 0x8b`), which
  also handles compressed data on standard input; `bufio.Reader.Peek`
  makes that possible without consuming the bytes.
]

#solution(0, 7, title: [Explain the race])[
  (a) The raced-on variable is the slice `results`, a local variable of
  `scanAll` that every goroutine's closure captured. `append` reads the
  slice (its pointer, length and capacity) and then writes a new slice
  back. Goroutine 7 read it at `scan.go:56` after goroutine 8 had written
  it at the same line, with nothing ordering the two.

  (b) With two small files, the goroutines usually run one after the other
  by chance, so both appends land and the counts look right. A race is
  undefined behaviour that often looks correct; with more files and cores
  you would lose results or crash. That is why the race detector exists:
  it reports the unsynchronized access whether or not it caused visible
  damage in that run.

  (c) Fix it by not sharing: send each result over a channel and let one
  goroutine collect them (what `logq` does), or by protecting the shared
  slice with a `sync.Mutex` locked around the `append`. A third option is
  to allocate `make([]*result, len(files))` up front and have goroutine
  `i` write only element `i`.

  (d) In the real `scanAll`, only one goroutine, the one running
  `scanAll` itself, ever writes to `ordered`; the others only send on a
  channel. A value sent on a channel is safely handed from sender to
  receiver, so the writes to `ordered` never overlap. The third fix in
  (c) is safe for a different reason: different goroutines write
  different elements, and distinct elements of a slice are distinct
  variables.
]

#solution(0, 8, title: [Read JSON logs too], code: "solutions/ch00/ex8")[
  First, decoding a `Level` from text, the mirror of `MarshalText`. It has
  a pointer receiver because it must change the `Level`:

  #src("solutions/ch00/ex8/logline/logline.go", region: "unmarshal")

  Then `Parse` checks the first byte and hands JSON lines to `parseJSON`.
  The `encoding/json` import is new:

  #src("solutions/ch00/ex8/logline/logline.go", region: "parse")

  The design choice is in `parseJSON`. Decoding straight into `Entry`
  would work for valid input, because `time.Time` and now `Level` know how
  to decode themselves. But for invalid input the error would come from
  inside `encoding/json`, and telling a bad time from a bad level would
  mean inspecting its error types. Decoding into a struct of strings first
  keeps JSON syntax errors (`Field: "json"`) separate from bad values,
  which then go through the same `time.Parse` and `ParseLevel` as text
  lines and produce the same `ParseError`s. `main.go` gets one more entry
  in `parseHints` for the new field.

  The round-trip test, `logq -json` piped into `logq -count`, is the
  property worth keeping: a tool that cannot read its own output is
  annoying to compose with others. Missing `service` or `message` fields
  decode as empty strings; whether that should be an error is a policy
  decision you could make either way.
]

#solution(0, 9, title: [Busiest minutes], code: "solutions/ch00/ex9")[
  The generic core is `TopFunc`, which needs only `comparable` keys (to be
  map keys) plus a function to order them. `Top` becomes a one-line
  wrapper that passes `cmp.Compare[K]`, the comparison for ordered types:

  #src("solutions/ch00/ex9/rank/rank.go", region: "top")

  `cmp.Compare[K]` is an explicit instantiation: naming a generic function
  with its type argument produces an ordinary function value. On the other
  side, `time.Time.Compare` is a _method expression_: the method turned
  into a function whose first parameter is the receiver, which gives
  exactly `func(a, b time.Time) int`.

  `Stats` gains a field `Minutes map[time.Time]int`, made in `init`,
  incremented in `Add` with `s.Minutes[e.Time.Truncate(time.Minute)]++`,
  and summed in `Merge`. `Truncate` rounds down to the start of the
  minute, so all entries in one minute share a key. In `main.go`, a flag
  and a check:

  #src("solutions/ch00/ex9/main.go", region: "byflag")
  #src("solutions/ch00/ex9/main.go", region: "bycheck")

  and a function that picks the ranking, called from `run` in place of the
  loop over `rank.Top` (add `time` to the imports):

  #src("solutions/ch00/ex9/main.go", region: "printtop")

  Why not key minutes by the string `"09:02"` and keep using `Top`? It
  works for one day of logs, but a week of logs would merge 09:02 on
  Monday with 09:02 on Tuesday. Keeping real times as keys and formatting
  them only for display avoids that. The general rule: compute with typed
  values, and format at the edge.
]
