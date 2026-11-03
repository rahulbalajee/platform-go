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
- Several authors work in this repo **at the same time**. Only create or edit
  files in your own areas. Run `go test`/`golangci-lint` on your own packages
  (e.g. `go test -race ./pkg/fsx/...`). Failures in packages you did not touch
  are someone else's work in progress: ignore them. Do not edit
  `book/main.typ`, `book/plan.typ`, `book/template/*`, `go.mod`, CI, or any
  existing file whose `// START x OMIT` regions are used by other chapters
  (grep `book/chapters` for `#src(` first). Do not commit; the editor
  integrates and commits.

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
  `#exercises(...)` (4–6 substantial exercises).
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
