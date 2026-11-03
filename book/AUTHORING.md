# Authoring guide for Platform Go chapters

This is the contract every chapter follows. Chapters 4 (`book/chapters/04*.typ`)
and 20 (`book/chapters/20-operators.typ`) are the reference for tone, depth and
layout. Read at least one of them fully before writing.

## The reader and the bar

- A senior engineer with a Go background working in DevOps, platform or SRE,
  preparing for roles that expect Go tooling, Kubernetes, cloud and AI-ops
  skills. They want to *use this at work* and *talk about it in interviews*.
- Cover fundamentals, but at depth: what the runtime/toolchain actually does,
  the trade-offs, the failure modes, what changes at scale. No tutorial filler.
- This must not read like a generic AI-written PDF. Every claim is concrete,
  every listing is real code from this repo, every terminal block is captured
  output from a real run.

## Non-negotiables

1. **No fabricated code or output.** Every listing comes from a file in this
   repo that compiles, passes `go vet`, `golangci-lint run` (v2.15.0, repo
   `.golangci.yml`) and `go test -race`. Every terminal block is produced by a
   capture script (`book/scripts/capture-chNN.sh`) writing into
   `book/output/chNN/`. If you cannot run something, say so in the text or
   leave it out; never invent output.
2. **Verify APIs and versions** against primary sources before writing about
   them: `go doc`, the module cache, `~/.hermes/cache/scratch/research/go1.2X.md`
   (release notes for Go 1.24 to 1.27), official docs. The book targets
   **Go 1.27** (toolchain go1.27.3). Mark version-specific features with
   `#newingo("1.NN")[...]`, using the version that introduced them.
3. **Listings fit the page:** max 86 columns (tabs = 4).
   `python3 book/scripts/check_widths.py --max 86` must report 0. Wrap code in
   the source itself (gofmt-friendly multi-line signatures), never by hand in
   the book.
4. **Production quality code:** contexts and timeouts everywhere, bounded
   concurrency, no goroutine leaks (use `go.uber.org/goleak` in packages that
   start goroutines), errors wrapped with useful context, doc comments on all
   exported identifiers, tests for behaviour that matters (including failure
   paths). Prefer the standard library.

## Where code goes

- Reusable libraries: `pkg/<name>`. Tool-private code: `internal/<name>`.
  Commands: `cmd/<name>`. Focused demo programs: `examples/chNN/<name>`.
- Root module is `github.com/rahulbalajee/platform-go` (go 1.27.0). These
  dependencies are already in go.mod for you: `golang.org/x/sync`,
  `golang.org/x/time`, `golang.org/x/sys`, `go.uber.org/goleak`,
  `github.com/google/go-cmp`, `github.com/rogpeppe/go-internal` (testscript),
  `github.com/creack/pty`.
- **Do not run `go mod tidy` in the root module** and avoid adding other root
  dependencies. Heavy or demo-only dependencies (testcontainers, extra tools)
  go in a nested module under `examples/chNN/<name>/` with its own `go.mod`
  (`module github.com/rahulbalajee/platform-go/examples/chNN/<name>`,
  `go 1.27.0`); there `go mod tidy` is fine. Nested modules must pass
  `go vet` and `go test ./...` on their own.
- Linux-only code (procfs, cgroups) uses build tags and must still let the
  module build on macOS. To run Linux code for real on this Mac, cross-compile
  (`CGO_ENABLED=0 GOOS=linux GOARCH=arm64`) and package it into a `FROM scratch`
  image (see `projects/watchtower/hack/scratch.Dockerfile`), then `docker run`.
  Pulling images from Docker Hub through Docker Desktop's proxy has been timing
  out on this machine, so prefer scratch images; if you try a pull, wrap it in a
  timeout and fall back.
- Build-track code lives in `workbook/chNN/` and `solutions/chNN/` (see
  "The build track"); those are nested modules and may use any dependencies
  they need, with their own `go.mod`.
- Several authors work in this repo **at the same time**. Only create or edit
  files in your own areas. Run `go test`/`golangci-lint` on your own packages
  (e.g. `go test -race ./pkg/fsx/...`). Failures in packages you did not touch
  are someone else's work in progress: ignore them. Do not edit
  `book/main.typ`, `book/plan.typ`, `book/template/*`, `go.mod`, CI, or any
  existing file whose `// START x OMIT` regions are used by other chapters
  (grep `book/chapters` for `#src(` first). Do not commit; the editor
  integrates and commits.

## The build track (every chapter, from checkpoint 3 on)

The book exists to drive a learning loop: **learn, implement, fail, come back
to the text, fix**. A reader with only the PDF and an empty directory must be
able to build every project, one working step at a time, know whether each
step is right, and find their way back to the explanation when it is not.
Readers range from people who have never programmed (they start at Chapter 0)
to senior engineers. Assume the reader has read the earlier chapters, and no
more.

1. **Shape of a project chapter.** After the opener, a short "What we're
   building" section shows the finished tool in action (real captured output)
   and a step plan table: step, what it adds, Go concepts it introduces. Then
   3 to 8 build steps, each `#step(k, N, "Title", label: <sec-..>)`. Step 1
   is the smallest program that runs end to end, starting from `mkdir` and
   `go mod init`. Each later step adds one idea. The explanations (why,
   trade-offs, failure modes, `#production`, `#internals`, `#interview`)
   live in the step where the idea first matters; a deep-dive section after
   the build is fine for material that does not fit a step.
2. **Every line is in the PDF.** New files are printed whole, including the
   `package` clause and imports. For changed files, print every changed line
   inside regions big enough to place them without guessing: whole functions
   or types, the import block whenever it changes, and a sentence saying
   where it goes ("replace `run` in `main.go` with:"). `go.mod` and `go.sum`
   come from commands the text shows (`go mod init`, `go get`). The coverage
   check enforces this mechanically.
3. **One snapshot module per step:** `workbook/chNN/stepK/` is a complete Go
   module with the short module path a reader would choose (`module sweep`),
   `go 1.27.0`, only the dependencies that step needs, and its tests. It
   passes gofmt, `go vet`, `go test -race` and `golangci-lint` with the repo
   config. All build-step listings come from these files via `#src` regions.
   Snapshots never import the root module.
4. **Each step ends with `#checkpoint(step: k, of: N, title: [...])[...]`:**
   what the reader should have now (the file tree), the commands to run and
   their real output captured from the snapshot, and a
   `#troubleshoot(([symptom], [cause], [fix / @sec-x]), ...)` table of 3 to 6
   real failure modes. Produce those by breaking a copy of the snapshot in the
   capture script (drop an import, forget `defer resp.Body.Close()`, write to
   a nil map, leak a goroutine under goleak, use `=` for `:=`) and capturing
   the exact compiler, vet, test or runtime output. Never invent error text.
5. **Tests are part of each step** and printed with it. Show the reader how to
   run them and what passing looks like.
6. **Production code.** If a chapter's final step is the code other chapters
   reuse (`pkg/...`, `internal/...`, `projects/...`), add `workbook/chNN/SYNC`
   pairing each final-step file with its production file
   (`workbook/ch04/step7/retry/retry.go = pkg/retry/retry.go`) plus
   `@import sweep/retry = github.com/rahulbalajee/platform-go/pkg/retry`
   rewrites. The sync check keeps both identical apart from OMIT markers and
   import paths. Keep every region other chapters use (grep `book/chapters`).
7. **`#goconcept(title: [...])[...]` boxes** introduce each Go language
   feature or standard-library abstraction where the chapter first uses it:
   interfaces and implicit satisfaction, `io.Reader`/`io.Writer`,
   `io.ReadAll`, `defer`, errors as values, pointers versus values, slices
   and maps, structs and methods, goroutines and channels, `context`,
   generics, struct tags, and so on. Write for someone new to Go: what it is,
   the smallest example, the common mistake, and (briefly) how it compares to
   Python, Java or JavaScript when that helps. Chapter 0 teaches the language
   in full; elsewhere keep boxes to 5-15 lines and point to Chapter 0 in plain
   text.
8. **Concept-heavy chapters** (toolchain, testing, parts of the OS chapter)
   use **labs** instead of one project: the same `#step` and `#checkpoint`
   machinery, titled "Lab k: ...", where the reader performs tasks and checks
   real expected output. Any code a lab asks the reader to write follows the
   snapshot and coverage rules.
9. **Exercises** use `#exercise-set(N, (tier: "warm-up" | "core" | "stretch",
   title: [...], body: [...], hint: [...], tests: "workbook/chNN/exercises/exK"), ...)`,
   with 5 to 8 per chapter: at least two warm-up, two core, one stretch.
   Code exercises ship acceptance tests in `workbook/chNN/exercises/exK/`
   (test files only, plus a `BASE` file naming the step dir if not the last
   step) that **fail** on the base step, and a full solution module in
   `solutions/chNN/exK/` containing identical copies of those tests.
   Design or analysis exercises get a written solution only. Every exercise
   gets a worked solution in `book/appendix/solutions/chNN.typ`: begin with
   `#solutions-for(N, "Chapter title")`, then one
   `#solution(N, K, title: [...], code: "solutions/chNN/exK")[...]` per
   exercise that explains the approach, the alternatives and the traps, with
   listings via `#src` from the solution module.
10. **Verify before reporting:**
    `python3 book/scripts/check_workbook.py --chapter NN --race` reports
    0 failures (coverage, modules, exercises, sync), `check_widths.py`
    reports 0, the harness compiles, and visual QA is clean.

The old `#exercises(...)` helper remains only until every chapter is
converted; new and retrofitted chapters use `#exercise-set`.

### Reference chapters and lessons from the pilot

**Chapter 4 is the model** for a project chapter (`book/chapters/04*.typ`,
`workbook/ch04`, `solutions/ch04`, `book/scripts/capture-ch04.sh`,
`book/appendix/solutions/ch04.typ`); **Chapter 0** shows how deep a
`#goconcept` can go for a beginner. Read both before starting. What the pilot
learned:

- **Work backwards from production.** Make the final step equal to the
  production code first (SYNC passes), then derive earlier steps by removing
  features. Keep OMIT regions in the final files; SYNC ignores OMIT markers
  and blank lines, which is what makes this practical.
- **Troubleshoot cells quote captured text.** The capture script writes the
  key lines of each deliberately broken run to `book/output/chNN/ts/*.txt`,
  and the "If you see" cell is `#quote-output("chNN/ts/name.txt")`. Never type
  an error message into a table.
- **Capture-script pattern** (copy it from `capture-ch04.sh`): `use_step N`
  points the reader's working directory at snapshot N; `deps` replays the
  reader's `go get`/`go mod tidy` on the previous step's `go.mod` and asserts
  the result equals the snapshot's; `broken`/`edit` applies a scripted edit
  to a copy and fails if the edit did not apply, so troubleshoot captures
  cannot silently go stale.
- **Grow tests, don't rewrite them.** Structure tests so each step adds table
  rows or new test functions rather than changing old ones; then only the new
  region needs printing. Reprinting the same 60-line test in three steps is
  what made Chapter 4 long.
- **Timing tests:** `testing/synctest` with `httptest.NewTestServer` makes
  timeout and retry assertions exact and instant. Use it wherever time matters.
- **Analysis exercises may have solution modules** (a simulation or
  benchmark): real numbers beat arithmetic, and they expose traps.
- **Keep internet-dependent captures to one checkpoint at most**; certificate
  ages and DNS answers change on every run. Prefer a local server program in
  the snapshot (Chapter 4's `cmd/fleet`).
- **Generated files:** list glob patterns (relative to a step dir) of files
  produced by commands the book prints (`kubebuilder init`, `controller-gen`,
  `stringer`, `go generate`) in `workbook/chNN/GENERATED`; coverage skips
  them. The checkpoint must show the generating command.
- **Layout:** header bars of checkpoints, callouts and exercises are sticky;
  use `#needspace(14em)` before a checkpoint that starts with a tall block if
  a header still strands. `workbook/go.mod` fences all exercise overlays out
  of the root module.
- **The coverage report names ranges and the enclosing declaration**
  ("lines 6-10 in `func TestGreet`"), so fix it by widening or adding the
  region around that declaration.

## Typst template API (`book/template/book.typ`)

Start the chapter file with `#import "../template/book.typ": *`, then:

- `#chapter(N, "Title", label: <ch-x>, abstract: [...], learn: ([...], ...), build: [...])`
  for the opener (see Chapter 4).
- Sections: `== Title <sec-x>`, `=== Subsection`. Labels must be unique book-wide;
  prefix them with a chapter-specific prefix (e.g. `<sec-tc-modules>`).
- `#src("path/from/repo/root.go", region: "name")` shows code between
  `// START name OMIT` and `// END name OMIT` in the file (those marker lines are
  dropped). Without `region:` it shows the whole file. Works for YAML, Makefiles,
  txtar and so on.
- `#code(file: "label")[```go ... ```]` for short inline-authored snippets
  (anti-patterns, sketches). Keep these rare; real code goes through `src`.
- `#output("chNN/file.txt", cmd: "the exact command")` shows captured output
  as a terminal block. Optional `size: 6.4pt` for unavoidably wide output.
  `#session(("cmd1", "chNN/a.txt"), ("cmd2", none), ...)` for multi-step
  sessions. The `cmd:` text must be exactly what the capture script ran.
  A command line ending in `\` continues on the next line. Terminal blocks
  fit about 93 monospace characters at the default size.
- Callouts: `#note[...]`, `#tip[...]`, `#warning[...]`, `#production[...]`,
  `#interview[...]`, `#internals[...]`, each with optional `title: [...]`;
  `#newingo("1.27", title: [...])[...]`.
- Figures: `#fig(caption: [...], placement: auto)[ #diagram(...) ] <fig-x>`
  using fletcher via `dnode((x, y), [label], kind: "default" | "accent" | "dark" | "muted" | "warn" | "good")`
  and `dedge((a), (b), "-|>", label: [..])`. Keep diagrams within about 5.5in
  width: few columns, short node labels. `placement: auto` floats the figure
  to avoid half-empty pages; refer to it with `@fig-x`.
- Tables: plain `#table(columns: ..., table.header(...), ...)`; the template
  styles them.
- `#kbd("Ctrl-C")` for keys. End every chapter with `#takeaways(...)` and
  `#exercise-set(...)` (see the build track).
- Build track: `#step(k, N, "Title", label: <sec-x>)`, `#checkpoint(step: k, of: N, title: [...])[...]`,
  `#troubleshoot(([symptom], [cause], [fix]), ...)`, `#goconcept(title: [...])[...]`,
  and in `book/appendix/solutions/chNN.typ`: `#solutions-for(N, "Title")`,
  `#solution(N, K, title: [...], code: "solutions/chNN/exK")[...]`.
- Cross-references: use labels only within your own chapter. Refer to other
  chapters in plain text ("Chapter 6"), not `@labels`, because other chapters
  are being written concurrently. Chapter 4 and 20 exist and may be mentioned
  in plain text too.

## Chapter shape

- 30–45 pages. 8–12 `==` sections. At least two diagrams, at least one
  `#production`, one `#interview`, and `#warning`s where people really get hurt.
- Open with a concrete platform-engineering problem, build the project through
  the chapter, end with what to remember and exercises.
- Explain *why*, show the trade-offs, name the failure modes, and say what
  changes at scale (1,000 services, 5,000 nodes, 200 engineers).

## Prose style

Load the `humanizer` skill. Plain, specific, confident sentences. No filler
openers, no "In today's fast-paced world", no "Let's dive in", no rule-of-three
lists for rhythm, no inflated words ("robust", "seamless", "leverage",
"crucial", "delve"). Avoid em dashes: use commas, colons, parentheses or two
sentences. Prefer numbers and real examples to adjectives.

## Build and QA loop

1. Harness: create `book/_chNN.typ` (ignored by git) containing
   `#import "template/book.typ": *`, `#show: book`, `#include "chapters/NN-name.typ"`.
2. Compile from the repo root:
   `typst compile --root . --font-path book/fonts book/_chNN.typ /tmp/chNN-{p}.png --ppi 100`
3. Contact sheets: `/Users/rahulbalajee/.hermes/environments/documents/gen-07c27b5e8d814bc39801db49827ff6b2/venv/bin/python book/scripts/contact.py /tmp/csNN $(ls /tmp/chNN-*.png | sort -t- -k2 -n) --per 8 --cols 4`
   and inspect every sheet with vision; zoom into suspicious pages. Fix
   overflowing or wrapped code and terminal lines, clipped or overlapping
   diagram labels, half-empty pages, orphaned headings, and anything that looks
   amateur. Repeat until clean.
4. `python3 book/scripts/check_widths.py --max 86` reports 0.
5. Final report: files created or changed, the exact verification commands
   you ran with their results, page count, and anything unresolved.
