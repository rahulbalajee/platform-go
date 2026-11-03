#import "../../template/book.typ": *

#solutions-for(6, "Testing Tools That Touch the Real World")

Every code exercise in Chapter 6 starts from your `sweep` at the end of Lab 9
(`workbook/ch06/step9`). Copy the acceptance tests from
`workbook/ch06/exercises/exK` into your `sweep` directory, keeping their
subdirectories, and watch them fail before you start. When you are done,
`go test -race ./...` and `golangci-lint run ./...` should both be clean,
and the tests you had before must still pass, golden files included. The
solution modules under `solutions/ch06` leave out the `containers` module,
which none of the exercises touch.

#solution(6, 1, title: [An empty inventory], code: "solutions/ch06/ex1")[
  The script fails on the finished labs at its first assertion, because
  `sweep` happily checks nothing and exits 0:

  #output("ch06/ex1-fail.txt", cmd: "go test -run 'TestScripts/^empty$' ./sweepscript", size: 6.8pt)

  The fix is four lines in `run`, right after the targets are read and
  before any reporter is created, so nothing reaches stdout:

  #src("solutions/ch06/ex1/cmd/sweep/main.go", region: "ex1")

  `readTargets` already handles files and stdin the same way, so one check
  covers all three cases in the script. Comments and blank lines never
  become targets, so a file of comments is empty too, which is the point:
  an inventory whose every line was commented out during an incident and
  never restored is exactly the case the gate should catch.

  Status 2 rather than 1 is a decision worth making explicitly. Status 1
  means "the fleet is unhealthy", which an on-call engineer investigates.
  Status 2 means "you called me wrong", which the author of the pipeline
  has to fix. An empty inventory is the second kind.

  The script is the acceptance test, but the unit tests in `cmd/sweep`
  describe the same contract one layer down, and they should stay in step.
  `TestRunUsageErrors` from Chapter 4 has a table of inputs that must exit
  with status 2; the solution adds one row to it:

  #code(file: "cmd/sweep/main_test.go", caption: "one new row in TestRunUsageErrors")[```go
		"no targets": {nil, "# nothing to check\n", "no targets in the inventory"},
  ```]

  With the row in place, the unit test fails first when someone removes the
  check, with a message that points at `run`, and the end-to-end script
  confirms that the real binary behaves the same way.
]

#solution(6, 2, title: [A line too long], code: "solutions/ch06/ex2")[
  `bufio.Scanner` stops at the first line longer than its buffer and reports
  `bufio.ErrTooLong` from `Err`. The loop has already counted the lines
  before it, so the failing line is the next one:

  #src("solutions/ch06/ex2/internal/sweep/target.go", region: "ex2")

  The error joins the list of line errors instead of replacing it, so an
  inventory with a bad port on line 2 and a runaway line on line 3 reports
  both, as the parser's contract promises. Any other read error (a broken
  pipe on stdin, an I/O error on a network filesystem) still aborts with
  `reading targets`, because there is no line to blame. The limit comes from
  `bufio.MaxScanTokenSize`, so the message stays true if the code ever sets a
  larger buffer with `Scanner.Buffer`, as long as it uses that constant.

  Why didn't the fuzzer find this? Go's fuzzer keeps inputs small (its
  mutator rarely grows an input past a few kilobytes), so it explores
  structure, not size. Limits such as line lengths, nesting depth and
  maximum counts need explicit table rows. A different fix is to raise the
  limit with `Scanner.Buffer`. That moves the problem rather than solving
  it, because some line is always longer than the limit, and an inventory
  line of 64 KiB is not a real target anyway.
]

#solution(6, 3, title: [A stronger property], code: "solutions/ch06/ex3")[
  The new property says that anything `parseRetryAfter` accepts must be
  either an HTTP date or a string of ASCII digits:

  #src("solutions/ch06/ex3/internal/sweep/probe_fuzz_test.go", region: "fuzz")

  Against the code from Lab 5, the fuzzer finds a counterexample at once:

  #output("ch06/ex3-fuzz.txt", cmd: "go test -run '^$' -fuzz '^FuzzParseRetryAfter$' -fuzztime 60s ./internal/sweep", size: 6.8pt)

  `strconv.ParseInt` accepts a leading `+` or `-`, so `+5` was a valid
  five-second delay, and `+0` and `-0` were valid zeros. The old property only asked
  whether the result was negative, and neither value produces a negative
  delay, so both passed. That is the general lesson: a fuzzer can only find
  violations of the properties you write down, and "doesn't crash" or
  "doesn't go negative" are much weaker than "follows the grammar".

  The fix checks the grammar before converting:

  #src("solutions/ch06/ex3/internal/sweep/probe.go", region: "ex3")
  #src("solutions/ch06/ex3/internal/sweep/probe.go", region: "ex3digits")

  `allDigits` checks bytes, not runes, on purpose: `unicode.IsDigit` would
  accept the Arabic-Indic digit three (`٣`), which is in the acceptance
  test because `strconv` rejects it and the RFC does too. Once the string
  is known to be digits, the only error `ParseInt` can return is
  `ErrRange`, for a number too large for an `int64`. That value is still
  valid by the RFC, so the code treats it as "a very long time" and the
  clamp below turns it into the maximum delay, exactly like
  `99999999999`. Rejecting it would also be defensible; what matters is
  that the choice is deliberate and pinned by a test.

  Is a plus sign worth a fix? A server that sends `Retry-After: +5` is
  broken, and accepting it did no harm. But a parser that follows the
  grammar is one you can reason about, and the next time someone loosens
  it, the fuzz target will say so.
]

#solution(6, 4, title: [Cover the resolver], code: "solutions/ch06/ex4")[
  `CachingResolver` uses one method of `*net.Resolver`, so the interface
  has one method, and it is declared next to its consumer:

  #src("solutions/ch06/ex4/internal/sweep/resolver.go", region: "ex4")

  Nothing else in the package changes. `main` still passes
  `net.DefaultResolver`, which satisfies the interface without knowing it
  exists. The fake in the acceptance test answers after 100 ms, which in a
  `synctest` bubble is virtual time, so the test can hold fifty callers in
  the same lookup, then step over the TTL boundary with `time.Sleep(29 * time.Second)` and `time.Sleep(2 * time.Second)` in no real time at all.
  The cache uses `time.Now` for expiry, and inside a bubble that clock is
  virtual too, which is why no clock interface was needed.

  The cost to the production code is small but real. The type now exports
  an interface that is part of its API, and the field's type changed from
  `*net.Resolver` to `HostResolver`, which breaks any caller that read the
  field back as a `*net.Resolver`. There is also a classic Go trap: a nil
  `*net.Resolver` stored in the interface makes a non-nil interface, so
  code that checked `r.Resolver == nil` to fall back to a default would
  silently stop doing so. `CachingResolver` has no such check, so the trap
  doesn't apply here, but it is the first thing to look for when you turn a
  concrete field into an interface.

  The alternative was to leave the code alone and point a `*net.Resolver`
  at a fake DNS server through its `Dial` field. That tests more of the
  real stack (the resolver's own retries and its parsing of DNS messages),
  but it needs a DNS server written for the test, and real sockets, so the
  TTL check would cost real seconds. For a cache, the interface is the
  better trade.
]

#solution(6, 5, title: [Certificates that expire on demand], code: "solutions/ch06/ex5")[
  `NewTLSServer` follows the shape of `NewServer` from Lab 2: a helper with
  `t.Helper`, `t.Cleanup` and `testing.TB`, in a file of its own,
  `internal/sweep/sweeptest/tls.go`. Its imports are all from the standard
  library:

  #src("solutions/ch06/ex5/internal/sweep/sweeptest/tls.go", region: "head")
  #src("solutions/ch06/ex5/internal/sweep/sweeptest/tls.go", region: "server")

  `httptest.NewUnstartedServer` creates the server without starting it, so
  the test can set `TLS` before `StartTLS`. (`httptest.NewTLSServer` would
  use the package's built-in certificate, which expires in 2084.) The
  certificate is made on the fly:

  #src("solutions/ch06/ex5/internal/sweep/sweeptest/tls.go", region: "cert")

  A self-signed certificate is its own issuer: `CreateCertificate` gets the
  template twice, as the certificate and as its parent, and signs with the
  certificate's own key. `IsCA` and `KeyUsageCertSign` let the pool use it
  as a root, and the IP addresses make it valid for `127.0.0.1` and `::1`,
  the addresses the prober dials. `NotBefore` is an hour in the past, so a
  small clock difference can't make a fresh certificate "not yet valid".
  ECDSA P-256 keys take microseconds to generate; RSA 2048 would take
  noticeably longer for every case.

  The acceptance test then checks two certificates, three days and thirty
  days from expiry, against a 14-day minimum. The three-day case must be
  down after exactly one attempt: an expiring certificate is a permanent
  failure, and retrying it would only delay the report.

  A container would add things this test can't: a different TLS stack
  (OpenSSL in nginx, for instance, rather than Go's on both ends), a real
  certificate chain with an intermediate, name-based virtual hosting with
  SNI, and the network path through Docker's port forwarder. Whether that
  is worth seconds per test depends on what you fear. For "does `sweep`
  compute days to expiry correctly", the in-process test is better; for
  "does `sweep` talk to our load balancers correctly", it isn't enough.
]

#solution(6, 6, title: [A flake budget])[
  Here is one design, as a GitHub Actions workflow. The same structure fits
  any CI system with a scheduler.

  #code(file: ".github/workflows/flakes.yml", caption: "a sketch")[```yaml
name: flakes
on:
  schedule: [{cron: "0 3 * * *"}]   # 03:00 UTC, every night
  workflow_dispatch: {}
jobs:
  shuffle:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions: {issues: write, contents: read}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: {go-version-file: go.mod}
      - name: test, shuffled, five times
        run: |
          go test -race -shuffle=on -count=5 -json ./... > test.json || true
          go run ./internal/tools/flakereport -o report.md < test.json
      - name: open an issue
        if: hashFiles('report.md') != ''
        env: {GH_TOKEN: "${{ github.token }}"}
        run: |
          gh issue create --label flaky --body-file report.md \
            --title "Flaky tests $(date -I)"
  ```]

  `flakereport` is a small program (an hour's work) that reads the
  `go test -json` event stream. Each event names its package and test and
  carries an `Action` (`run`, `pass`, `fail`, `output`). The program collects
  the output of every failing test, finds the `-test.shuffle N` line that
  `go test` prints for each package, and writes one section per failure with
  the replay command, for example
  `go test -race -shuffle=1762184412 -count=1 -run '^TestRegister$' ./flaky`.
  If nothing failed it writes no file, `hashFiles` returns an empty string,
  and no issue is opened. `|| true` keeps a failing test run from ending
  the job before the report is written. The sketch opens one issue per bad
  night; the first refinement below fixes that.

  To check the job, put a `TestRegistry`/`TestRegister` pair like Lab 8's in
  any package. With `-count=5` the second run of each test already meets the
  state of the first, so the pair fails every night, not once a week, which
  shows a property of the design: `-count` finds leaked state reliably, and
  `-shuffle` finds order dependence between _different_ tests over several
  nights.

  The hard part is the people, and the design has to plan for it:

  - *One issue per test, not per night.* Search for an open issue with the
    test's name and add a comment instead of opening a new one; a wall of
    nightly issues gets closed in bulk.
  - *An owner.* Assign the issue to whoever last changed the test file
    (`git log -1 --format=%ae -- file`), not to "the platform team".
  - *A budget.* Agree on a number, such as at most three open flake issues
    per team, and treat going over it like a broken build: new feature work
    waits.
  - *Quarantine is a decision, not a default.* Skipping a test is allowed,
    with `t.Skip` and a link to its issue, and the job lists skipped tests
    in its report, so a quarantine that lasts a month is visible.
  - *No silent retries.* If the main CI pipeline reruns failing tests, the
    flake job is the only place they are counted; keep it that way.
]

#solution(6, 7, title: [Benchmark the alternative], code: "solutions/ch06/ex7")[
  `tabwriter` stores every cell, measures the columns when it is flushed,
  and then writes padded text. The rewrite does the same in two explicit
  passes, with one reused buffer:

  #src("solutions/ch06/ex7/internal/sweep/report.go", region: "ex7")

  The first pass formats each latency once (it is needed for the width and
  again for the row) and records the widest cell of every column, counting
  runes rather than bytes so that a target with non-ASCII characters lines
  up the way `tabwriter` would line it up. The second pass appends each row
  into `buf` with `strconv.AppendInt` for the attempt count and
  `appendTruncated` for the detail, writes it, and resets the buffer to
  length zero, keeping its capacity. What is left is one allocation per row,
  the latency string, and the golden files from Lab 3 prove that the output
  is byte for byte what it was.

  Interleaved runs of the two versions, ten each:

  #output("ch06/ex7-benchstat.txt", cmd: "go run golang.org/x/perf/cmd/benchstat@latest old.txt new.txt", size: 6.8pt)

  The allocation count drops from about six per row to one, as designed,
  and the time drops with it, by enough that even this noisy laptop
  measures the change as significant. Now put that in context. A real
  sweep of 300 targets takes as long as its slowest target, hundreds of
  milliseconds at best, and the table for 300 rows costs well under a
  millisecond either way. No user would ever notice the difference, and
  the new code is three times as long, with width arithmetic that the next
  person to add a column can get wrong (the golden files would catch it,
  which is why they exist).

  A reasonable threshold: accept the faster version when the table is on a
  path that runs often enough for the saving to matter, such as a server
  rendering it per request, or when a profile of a real workload shows the
  reporter in the top few entries. Neither is true for `sweep`, so the
  production code keeps `tabwriter`. The acceptance test is still worth
  keeping in a codebase that does make the switch: `testing.AllocsPerRun`
  turns "this path doesn't allocate much" into a test, and it is built with
  `//go:build !race` because the race detector adds allocations of its own.
]
