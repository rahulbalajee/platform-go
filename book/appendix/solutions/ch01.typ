#import "../../template/book.typ": *

#solutions-for(1, "The Platform Engineer's Go: Toolchain, Modules, and the Monorepo")

Exercise 1.1 starts from your tools module at the end of Lab 5
(`workbook/ch01/step1`); the other code exercises start from `stamp` at the
end of Lab 9 (`workbook/ch01/step4`). Copy the acceptance tests from
`workbook/ch01/exercises/exK` into your module, keeping their
subdirectories, and watch them fail before you start. When you are done,
`go test -race ./...` and `golangci-lint run ./...` should both be clean, and
the tests you had before must still pass.

#solution(1, 1, title: [A new phase], code: "solutions/ch01/ex1")[
  Three places in `phase.go` name the last phase, and all three change. The
  constant goes at the end of the block, so no existing value moves:

  #src("solutions/ch01/ex1/rollout/phase.go", region: "phase")

  `Phases` lists it, and `MarshalText`'s upper bound moves to it:

  #src("solutions/ch01/ex1/rollout/phase.go", region: "parse")
  #src("solutions/ch01/ex1/rollout/phase.go", region: "text")

  Then `go generate ./...`, and one more edit you may not have expected:
  `TestStringAndParse` indexes its `want` slice by position for every phase
  in `Phases()`, so it panics with `index out of range [6] with length 6`
  until `"aborted"` is added to it. A test that enumerates every value of an
  enum is right to break when the enum grows.

  The freshness check did not fire because it only checks the constants
  that existed when `stringer` last ran. Appending a constant moves none of
  them, so `x[PhaseRolledBack-5]` still compiles, and a stale
  `phase_string.go` quietly prints the new phase as `Phase(6)`. The
  acceptance test catches that through `String` and `ParsePhase`, and the
  CI step from Lab 5 (`go generate ./...` followed by
  `git diff --exit-code`) catches it before review. The check is good at
  inserted and reordered constants, which are the dangerous changes, and
  silent about appended ones.

  The bound in `MarshalText` is the trap the second test sets: forget it and
  `json.Marshal(PhaseAborted)` fails with `invalid phase 6`. There are two
  ways to stop it recurring. An unexported sentinel after the last constant
  (`phaseEnd`) and a check of `p >= phaseEnd` would follow every append
  automatically, but `stringer` gives the sentinel a name too, and
  `Phases()` still has to be edited by hand. `slices.Contains(Phases(), p)`
  ties the bound to the list, so the list becomes the only thing to update,
  at the cost of a linear scan on every marshal (seven elements, so
  nothing). The solution keeps the explicit bound, because the test for the
  value after the last phase makes a forgotten update fail loudly.
]

#solution(1, 2, title: [How old a Go can build stamp?])[
  At `go 1.23.0`, `go vet` flags the stamp tests, and so does `go test`,
  which in Go 1.27 runs the `stdversion` analyzer before compiling:

  #output("ch01/ex2-go123.txt", cmd: "go vet ./...")
  #output("ch01/ex2-go123-test.txt", cmd: "go test ./... 2>&1 | tail -4")

  `t.Context` arrived in Go 1.24. (`stdversion` names it
  `testing.(*B).Context` because the method is defined on a type that `T`
  and `B` share.) At `go 1.20`, the `go` command refuses before any
  analyzer runs, because `go.mod` is no longer consistent with its own
  requirements:

  #output("ch01/ex2-go120.txt", cmd: "go vet ./...")

  That is minimal version selection applied to the `go` line, exactly as in
  Lab 2's `go mod graph | grep ' go@'`: `go-cmp` v0.7.0 requires Go 1.21, so
  the build list's Go version cannot be lower, and `go mod tidy` would raise
  the line back to `1.21`. The `buildinfo` package on its own would compile
  at 1.21 too; its newest API is `sync.OnceValue`, from Go 1.21.

  The reason no analyzer sees is `omitzero`. A struct tag is a string the
  compiler never interprets, and `encoding/json` in a toolchain older than
  Go 1.24 ignores options it doesn't know. Built with go1.23,
  `stamp -version -json` of a build without VCS information prints
  `"time": "0001-01-01T00:00:00Z"`, and every consumer that treats the
  presence of `time` as meaningful gets it wrong. `TestJSONOmitsUnknownFields`
  from Lab 9 is the test that fails under that toolchain, which is the case
  for writing tests about the shape of output and not only about values.

  So the honest answer is `go 1.24.0`: the `go` line is a promise that any
  toolchain at or above it builds the module _and_ behaves as tested. A line
  of `1.21` would build with go1.23 and ship broken JSON. For a library that
  would be the end of it; `stamp` is an application, so its `toolchain` line
  stays at the current patch release whatever the `go` line says.
]

#solution(1, 3, title: [Refuse to ship a dirty build], code: "solutions/ch01/ex3")[
  The reasons are exported values, so callers can test for them:

  #src("solutions/ch01/ex3/buildinfo/releasable.go", region: "errors")

  `Releasable` has to recognise pseudo-versions. All three forms end the
  same way: a 14-digit UTC timestamp, a dash and a 12-character commit
  prefix, optionally followed by build metadata such as `+dirty`. A tag never
  looks like that, including pre-release tags such as `v1.5.0-rc.1`, so
  anchoring a regular expression at the end of the string separates the two
  without parsing semantic versions.
  `golang.org/x/mod/module.IsPseudoVersion` does the same job precisely, and is
  the better choice in a module that already depends on `x/mod`; here it
  would be a new dependency for one regular expression. The method collects
  every reason that applies:

  #src("solutions/ch01/ex3/buildinfo/releasable.go", region: "releasable")

  The `switch` makes `ErrNoVersion` and `ErrPseudoVersion` exclusive,
  because `devel` is not a pseudo-version and reporting both would be noise.
  The other two checks are independent, so a `go run` build with local
  changes reports all three of its problems at once, which is what the
  "everything wrong" case asks for. `errors.Join` keeps each wrapped error
  visible to `errors.Is` and returns `nil` when the slice is empty, so the
  happy path needs no special case. Wrapping `ErrPseudoVersion` with `%w`
  adds the offending version to the message without hiding the sentinel.

  Checking `Modified` _and_ the `+dirty` suffix looks redundant, but the two
  come from different places: a pipeline can override the version with `-X`
  while the toolchain still records `vcs.modified=true`, and the reverse can
  happen with a hand-typed version. A release pipeline would call this from
  the binary it is about to publish, for example through a hidden flag that
  prints `Releasable()` and exits non-zero, before any upload.
]

#solution(1, 4, title: [User-Agent on every request], code: "solutions/ch01/ex4")[
  #src("solutions/ch01/ex4/buildinfo/transport.go", region: "transport")

  The contract of `http.RoundTripper` says an implementation should not
  modify the request it is given. Callers reuse requests, log them and
  retry them, and a transport that sets a header on the caller's request
  changes all three behind their back. `req.Clone` copies the headers, so
  the clone can be changed freely, and it keeps the request's context,
  which the second test checks: a transport that built a fresh request
  would lose the caller's deadline. Cloning only when the header is missing
  keeps the path allocation-free for callers that set their own.

  `req.Header.Get` returns `""` both when the header is absent and when a
  caller set it to the empty string. The standard transport treats an
  explicit empty `User-Agent` as "send none"; to honour that, test for the
  key with `_, ok := req.Header["User-Agent"]` instead. The solution doesn't,
  because a tool that wants to suppress its own `User-Agent` is unusual, but
  it is a one-line change if yours does.

  The alternative, setting the header at every call site, works until
  someone adds a call site. A transport is set once, where the client is
  built, and every request through that client carries the version. Build
  that client once and share it: the wrapper is cheap, but a new
  `http.Transport` per request would throw away its connection pool.
]

#solution(1, 5, title: [A build_info metric], code: "solutions/ch01/ex5")[
  #src("solutions/ch01/ex5/buildinfo/metric.go", region: "metric")

  The exposition format is line-oriented: `# HELP` and `# TYPE` lines name
  the metric, then one sample line with the labels in braces and the value.
  The indexed verbs (`%[1]s`) let one format string use the name three
  times. Labels are written in alphabetical order; Prometheus doesn't
  require an order, but a fixed one makes the output testable and diffable.

  Two kinds of input need cleaning. A program name can contain characters a
  metric name cannot (`my-tool.v2`), and replacing each with `_` is the
  convention exporters follow; a leading digit gets a `_` in front instead
  of being replaced, so `9lives` keeps its digit. Label values may contain
  anything, so backslash, double quote and newline must be escaped, and the
  order matters: escaping quotes without first escaping backslashes would let
  a value ending in a backslash swallow the closing quote. A
  `strings.Replacer` applies all three in a single pass over the input, so
  they cannot interfere with each other.

  An empty `revision` label is written as `revision=""`. Prometheus treats
  an empty label value the same as a missing label, so builds without VCS
  information and builds with it still belong to the same metric. In a real
  service you would not write this by hand: `prometheus/client_golang`
  registers a gauge with these labels and sets it to 1 at startup (Chapter
  17 does that), and its `collectors.NewBuildInfoCollector` exports a
  similar `go_build_info` series from the same `debug.ReadBuildInfo` data.
  Writing the format once is still the best way to understand what the
  library produces, and a tool that only runs in CI can push this text to a
  Pushgateway with no client library at all.
]

#solution(1, 6, title: [An escape hatch for the vulnerability gate])[
  `govulncheck` v1.9.0 has no flag to suppress findings, so the gate needs a
  filter of its own. With `-format json`, it writes a stream of JSON
  messages, each with one of the keys `config`, `progress`, `SBOM`, `osv`
  (the advisory) or `finding`. A finding names its advisory in `osv`, its
  `fixed_version` (empty when there is no fix), and a `trace` of frames from
  the vulnerable symbol back to your code. Findings come at three levels:
  module, package and symbol. Only those whose first frame names a
  `function` are the "your code is affected" findings of the text output;
  the others are the "imported but not called" notes.

  The allowlist lives in the repository, next to `go.mod`, so changes to it
  are reviewed like code:

  #code(file: "vuln-allow.yaml")[```yaml
- id: GO-2026-6348
  module: google.golang.org/grpc
  owner: team-platform
  reason: >
    Only reachable through the debug channelz server, which is not
    started in production builds (see cmd/server/flags.go).
  ticket: PLAT-1421
  expires: 2026-12-15
```]

  The filter reads the JSON stream, keeps symbol-level findings, and fails
  for any whose advisory is not on the list, or is on it with an `expires`
  date in the past. It also prints every entry that matched nothing: a
  finding that disappeared, because the dependency was upgraded or the code
  path removed, leaves a stale entry, and stale entries are how lists rot.

  Approval is the part that makes the list trustworthy. A `CODEOWNERS` rule
  sends every change to the file to the security owners as well as the
  author's team. Entries must have an expiry no more than 90 days out, an
  owner that is a team rather than a person, a reason that says why the
  finding is not exploitable here or what mitigates it, and a ticket that
  tracks the real fix. Renewing an entry is a new review, not an edit of
  the date.

  The weekly scheduled run that already exists for new advisories does the
  housekeeping: it lists entries that expire within 14 days and opens or
  updates an issue for each owner, and it fails, like any other run, on
  entries that have expired. A small dashboard of allowlisted findings per
  team, with their age, keeps the list visible; a list that only grows is a
  list nobody is working down.

  Two alternatives are worth knowing. `-format openvex` writes the findings
  as an OpenVEX document, and VEX statements ("not affected, because the
  vulnerable code is not in the execute path") are the standard way to
  record these decisions so other scanners and customers can read
  them; an allowlist can be turned into VEX for that purpose. And some teams
  run the gate in report-only mode for advisories with no fix, which is
  simpler but means nobody decides anything until a fix appears.
]

#solution(1, 7, title: [A build-info inventory], code: "solutions/ch01/ex7")[
  The command follows the shape of `stamp`: a tiny `main`, a testable `run`.
  The file starts with its documentation and imports:

  #src("solutions/ch01/ex7/cmd/inventory/main.go", region: "head")

  `run` validates the flags before touching the file system, so every usage
  error exits 2 at once, then scans, filters and sorts:

  #src("solutions/ch01/ex7/cmd/inventory/main.go", region: "run")

  The scan is a `filepath.WalkDir` over regular files.
  `debug/buildinfo.ReadFile` understands ELF, Mach-O and PE, so a Linux
  binary is read on a Mac, which the test checks with a cross-compiled
  `stamp`; a file that is not a Go binary is counted and skipped:

  #src("solutions/ch01/ex7/cmd/inventory/main.go", region: "scan")

  `moduleVersion` looks at the main module as well as the dependencies,
  because the module you ask about may be the one the binary was built from.
  A replaced dependency reports the replacement's version, which is the code
  that was actually linked; an inventory that reported the original would
  call a patched fork vulnerable, or worse, the reverse. The output is a
  `text/tabwriter` table:

  #src("solutions/ch01/ex7/cmd/inventory/main.go", region: "write")

  The version comparison is where a quick solution goes wrong. As strings,
  `v0.9.0` sorts after `v0.60.0`, so a string comparison would report a
  binary with an ancient x/net v0.9.0 as _not_ older than v0.60.0.
  `golang.org/x/mod/semver` compares semantic versions correctly, including
  pre-releases and pseudo-versions, and `semver.IsValid` rejects a version
  written without its `v`, which the usage test checks. A binary without the
  module at all is not "older", so `-older` drops rows whose `MODULE` column
  is `-`.

  Run against an artifact store, the table answers the Friday question:
  `-module golang.org/x/net -older v0.60.0` lists every binary to rebuild.
  Here it is against a directory with the two `stamp` builds, the
  `buildinfo` test binary and the Linux release build of `sweep` from Lab 7:

  #output("ch01/ex7-run.txt", cmd: "go run ./cmd/inventory -module golang.org/x/sync \"$LAB/dist\"")
  #output("ch01/ex7-older.txt", cmd: "go run ./cmd/inventory -module github.com/google/go-cmp -older v0.8.0 \"$LAB/dist\"")
]
