#import "../template/book.typ": *

// Chapter 1's short name for the template's quote-output: a troubleshooting
// row quotes the key lines of a real failure that book/scripts/capture-ch01.sh
// produced by breaking a copy of what the reader has at that point.
#let ts(name) = quote-output("ch01/ts/" + name)

#chapter(1, "The Platform Engineer's Go: Toolchain, Modules, and the Monorepo", label: <ch-toolchain>,
  abstract: [
    Every platform team eventually gets the same question on a bad day: which
    of the binaries we run were built with the vulnerable library, by which
    compiler, from which commit? Go can answer it from the binaries
    themselves, but only if the toolchain is pinned, the module graph is
    understood, and the build is set up to record what went in. This chapter
    covers the machinery under `go build` that most teams never look at, in
    ten labs you run yourself, with this book's own repository as the case
    study.
  ],
  learn: (
    [How the `go` and `toolchain` lines and `GOTOOLCHAIN` decide which compiler actually runs],
    [Minimal version selection, read from real `go mod graph` output, and how `retract`, `exclude` and `replace` change it],
    [`go.sum`, the checksum database, proxies, and private modules on GitHub],
    [Pinning developer tools with the Go 1.24 `tool` directive, and when not to],
    [Workspaces, repository layout, and when a project deserves its own module],
    [Static, reproducible, stamped release builds, and the quality gates in front of them],
  ),
  build: [
    *`stamp`* and its *`buildinfo`* package, over four labs: the package every
    tool in this book uses for `--version`, `User-Agent` and build metadata.
    The last lab's files are the repository's `pkg/buildinfo` and
    `examples/ch01/stamp`.

    #v(4pt)
    A *tools module* that pins `stringer` and `govulncheck` with the `tool`
    directive, and a small module universe served offline, for experiments
    with version selection that you can break on purpose.
  ],
)

== The Friday question <sec-tc-why>

A security advisory lands late on a Friday: an HTTP/2 flaw in
`golang.org/x/net` lets a client exhaust server memory. Your platform team
ships about 140 binaries: CLIs on laptops and CI runners, controllers in
clusters, agents on nodes. Before anyone can patch, someone has to answer
three questions. Which binaries contain the vulnerable package? Which Go
toolchain built each one, since the standard library has its own HTTP/2
code? Which commit does each binary come from, so the fix can be released
from the right branch?

Teams that can't answer these questions spend the weekend grepping
repositories and guessing which version of which `go.sum` produced which
artifact. Teams that can answer them run one command against their artifact
store. The difference is not tooling budget. It is a handful of decisions
about toolchains, modules and builds, made long before the advisory. This
chapter is about those decisions.

Before the mechanics, here is why Go is the default language for this kind
of software. The reasons are the same properties this chapter teaches you to
protect.

*Static binaries.* With cgo disabled, the Go linker produces a single
executable that depends on nothing but the kernel. This is the release build
of `sweep` from Chapter 4 for Linux, which you build yourself in Lab 7,
examined by `file`:

#output("ch01/build-file.txt", cmd: "file -b \"$LAB/sweep-linux-amd64\" | tr , \"\\n\" | grep -v BuildID")

No glibc version to match, no shared libraries to install, nothing to break
when the base image changes. It runs in a `FROM scratch` container, which is
how Chapter 20 ships the `watchtower` operator, and it can be copied onto a
bastion host with `scp`.

*Cross-compilation is an environment variable.* `GOOS` and `GOARCH` select
the target, and the toolchain needs nothing else installed for pure Go code:

#output("ch01/dist-count.txt", cmd: "go tool dist list | wc -l")

Forty-seven operating system and architecture pairs, from one machine. A
release pipeline builds Linux amd64 and arm64, macOS arm64 and Windows
binaries from a single Linux runner (@sec-tc-build has the sizes).

*Fast builds.* The compiler was designed for build speed, and the build
cache makes repeat builds nearly free. Here is `sweep` built twice against an
empty cache, so the first build also compiles the standard library:

#session(
  ("time GOCACHE=\"$LAB/gocache\" go build -o /dev/null ./cmd/sweep", "ch01/build-cold.txt"),
  ("time GOCACHE=\"$LAB/gocache\" go build -o /dev/null ./cmd/sweep", "ch01/build-warm.txt"),
)

The cold build, standard library included, kept every core busy: its CPU
time (user plus sys) is several times its wall time. The warm one needed
well under a second of CPU,
because everything came from the cache; its wall time depends mostly on how
busy the machine is. CI pipelines that run `go vet`, a linter and
the race detector across a whole repository on every push stay inside the
time budget developers will tolerate.

*A standard library written for servers.* `net/http` with HTTP/2,
`crypto/tls` and `crypto/x509`, `encoding/json`, `os/exec`, `context`, and
since Go 1.24 a FIPS 140-3 validated cryptographic module. A health checker,
a webhook receiver or a TLS-terminating proxy needs no third-party code at
all, and every third-party module you avoid is one less entry in the Friday
advisory.

*The ecosystem is written in Go.* Kubernetes, etcd, containerd, runc, the
Docker engine, Prometheus, Terraform and its providers, Helm, Argo CD, Flux,
Istio's control plane, CoreDNS, Vault, Consul, cert-manager and Cilium's
agent are Go programs. Their client libraries (`client-go`,
`controller-runtime`, the AWS, Google Cloud and Azure SDKs) are Go first.
When a platform tool needs to speak a system's native API, the best library
for it is usually the one the system's own authors use.

The trade-offs are real too. A small CLI is around 10 MB. The garbage
collector costs memory headroom, which rarely matters for tools but does for
node agents on small machines (Chapter 30). Some libraries exist only in C,
and calling them through cgo gives up the static binary and easy
cross-compilation. Go's answer to most of these is to keep the binary
self-contained and make its contents inspectable, which brings us back to the
Friday question.

== How the labs work <sec-tc-labs>

Most of this chapter is about the `go` command, not about a program, so it
is organised as ten labs instead of one project. Each lab has you run real
commands against real modules, explains what happened and why, and ends with
a checkpoint: what you should have, the commands to run, the output to
expect, and a table of the failures people actually hit, each one produced
by breaking a copy of the lab on purpose. Four labs have you write code, a
small command called `stamp` and a tools module, and those follow the same
rule as every build step in this book: every line you need is printed here.

#table(
  columns: (auto, 1.2fr, 1fr),
  table.header([Lab], [What you do], [Go and tooling you meet there]),
  [1 #h(3pt) Which Go runs?], [Run three toolchains from one `go` command; set the `go` and `toolchain` lines], [`go.mod`, `GOTOOLCHAIN`, `go env`, `go get go@`],
  [2 #h(3pt) Minimal version selection], [Read real build lists; resolve a module universe offline; upgrade on purpose], [module versions and pseudo-versions, `go mod graph`, `go list -m`, `GOPROXY`],
  [3 #h(3pt) Retract, exclude, replace], [Withdraw, refuse and swap module versions], [`retract`, `exclude`, `replace`, `go mod edit`],
  [4 #h(3pt) Checksums and proxies], [Corrupt `go.sum` and the module cache and watch Go refuse], [`go.sum`, `go mod verify`, `sum.golang.org`, `GOPRIVATE`, `GOFLAGS`],
  [5 #h(3pt) A pinned code generator], [Start a tools module; generate `String` methods with `stringer`], [`tool` directive, `go generate`, `iota`, `fmt.Stringer`, `encoding.TextMarshaler`],
  [6 #h(3pt) Workspaces and layout], [Join two modules; run into the `internal` rule], [`go.work`, `cmd/`, `internal/`, `pkg/`, nested modules],
  [7 #h(3pt) Release builds], [Build static, cross-compiled, reproducible binaries; write `stamp`], [`CGO_ENABLED`, `-trimpath`, `-ldflags`, VCS stamping, `runtime/debug`, a testable `main`],
  [8 #h(3pt) A buildinfo package], [Turn the toolchain's stamp into one value with a `-version` flag], [`sync.OnceValue`, unexported helpers, same-package tests, `go-cmp`],
  [9 #h(3pt) Release stamping], [Let a pipeline set version, commit and time with `-X`; add JSON], [`-ldflags -X`, struct tags and `omitzero`, `os/exec` in tests],
  [10 #h(3pt) Quality gates], [Vet, lint and scan for vulnerabilities, as CI does], [`go vet`, `golangci-lint`, `govulncheck`, the CI contract],
)

After the labs, @sec-tc-scale covers what changes when 200 engineers share
these decisions, and the exercises extend `stamp` and the tools module.

=== Setting up

You need Go 1.27 (Chapter 0 installs it), `git`, a terminal, and network
access. Every lab works inside one directory, which the commands call
`$LAB`, and several labs use a clone of this book's repository as the
example of a real multi-module codebase. Create both:

#code(file: "terminal")[```sh
export LAB="$HOME/ch01"
mkdir -p "$LAB" && cd "$LAB"
git clone https://github.com/rahulbalajee/platform-go
```]

`export` sets the variable for this terminal only; in a new terminal, run
the first line again. Lab 1 also needs an older Go next to your own, and
Lab 10 needs `golangci-lint`; each lab says how to get them.

Your output will differ from the book's in the details that are supposed to
differ: version numbers if your Go is newer, dates, commit hashes, timings,
and anything that comes from the internet, such as the vulnerability
database. Everything else should match. If it doesn't, the troubleshooting
table at the end of the lab lists the failures we produced on purpose, with
the exact message each one prints.

The code you write has complete reference copies in the repository: the
tools module of Lab 5 is `workbook/ch01/step1`, and `stamp` after Labs 7, 8
and 9 is `workbook/ch01/step2`, `step3` and `step4`. Each one passes
`go vet`, `go test -race` and `golangci-lint`. The last one is not a toy:
`pkg/buildinfo` and `examples/ch01/stamp` in the repository are the same
files with a longer import path, and a check in CI keeps them identical.

#step(1, 10, "Lab 1: Which Go runs?", label: <sec-tc-toolchain>)

Open the root `go.mod` of the repository you cloned. It starts like this;
the rest lists the modules that later parts of the book use, such as cobra
for the command-line tools of Part II:

#src("go.mod", head: 12)

#goconcept(title: [The `go.mod` file])[
  A _module_ is a tree of packages that is versioned and released together,
  rooted at a `go.mod` file (Chapter 0 created one with `go mod init`). The
  `module` line names it, and every import path inside starts with that
  name. `require` lines list the other modules the build needs, each with
  the _minimum_ version it needs; `// indirect` marks modules that no package
  of this module imports directly. Later labs meet the rest: `tool`,
  `replace`, `exclude` and `retract`. The `go` command edits this file for
  you (`go get`, `go mod tidy`), and you should let it: hand edits are how
  the troubleshooting tables in this chapter get their rows. Next to it,
  `go.sum` holds checksums, which Lab 4 takes apart. Python's
  `requirements.txt` and npm's `package.json` are the closest relatives, but
  as Lab 2 shows, Go needs no lock file.
]

Two lines at the top describe the module's dependency on Go itself. The `go`
line is the _minimum_ Go version required to use the module. Since Go 1.21 it
is a hard requirement: a toolchain older than the `go` line refuses to build
the module rather than producing confusing compile errors. It also sets the
language version, so features like range-over-func iterators are only
available when the `go` line allows them. The `toolchain` line is a
_preference_: the toolchain the module's developers want used when they work
in it. Libraries that are consumed by others keep a conservative `go` line
and can still ask for a newer toolchain for their own development.

=== An older Go on your PATH

To see the `go` command switch toolchains, it has to start from an older one,
the way it does on the laptop of a colleague who installed Go last spring.
The machine this book was written on has Go 1.26.4 installed system-wide.
Reproduce that in this terminal with the `golang.org/dl` wrapper, which
downloads a given release into `~/sdk` (`go install` puts the wrapper itself
in `~/go/bin`, which Chapter 0 added to your `PATH`):

#code(file: "terminal")[```sh
go install golang.org/dl/go1.26.4@latest
go1.26.4 download
export PATH="$HOME/sdk/go1.26.4/bin:$PATH"
```]

From now on, in this terminal, `go` on your `PATH` is 1.26.4. The repository
needs 1.27. Watch what happens:

#session(
  ("cd \"$LAB\"", none),
  ("go version", "ch01/tc-outside.txt"),
  ("cd \"$LAB/platform-go\"", none),
  ("go version", "ch01/tc-version.txt"),
  ("GOTOOLCHAIN=local go version", "ch01/tc-local.txt"),
  ("go env GOTOOLCHAIN GOVERSION GOROOT", "ch01/tc-env.txt"),
)

Outside any module, the `go` binary on `PATH` reports 1.26.4. Inside the
repository it reports 1.27.3. Since Go 1.21 the distribution is a `go`
command plus a bundled toolchain, and the command is allowed to run a
_different_ toolchain when the module asks for one. It read the `toolchain`
line, found go1.27.3 in the module cache, and re-executed itself as that
version. `GOROOT` shows where that toolchain lives: it was downloaded as an
ordinary module, `golang.org/toolchain`, at version
`v0.0.1-go1.27.3.darwin-arm64`. If your module cache doesn't have it yet, the
first command prints `go: downloading go1.27.3` and fetches about 70 MB.

#newingo("1.24", title: [Tracing toolchain selection])[
  `GODEBUG=toolchaintrace=1` makes the `go` command explain its choice. The
  output is long, so the capture folds it:
  #output("ch01/tc-trace.txt", cmd: "GODEBUG=toolchaintrace=1 go version 2>&1 | fold -s -w 88")
  This is the first thing to run when a CI job and a laptop disagree about
  which compiler built something.
]

=== The GOTOOLCHAIN setting

`GOTOOLCHAIN` controls the switching.

#goconcept(title: [The `go` command's settings])[
  `go env` prints the settings the `go` command runs with: `GOROOT` (where
  the toolchain lives), `GOPATH` and `GOMODCACHE` (where downloaded modules
  go), `GOPROXY`, `GOOS`, `GOARCH` and about forty more. Each one is read
  from three places, first match wins: the process environment
  (`export GOPROXY=...`, or `GOOS=linux go build` for a single command), then the
  per-user file that `go env -w NAME=value` writes, then `$GOROOT/go.env`
  inside the installed distribution. `go env -u NAME` removes a `-w` value.
  Because the environment wins, a variable exported in one terminal and
  forgotten is a classic cause of "it works in the other window"; Labs 2 to
  4 export a few on purpose, and Lab 5 shows what happens if you forget to
  remove them.
]

The official releases' `go.env` sets `GOTOOLCHAIN=auto`. Linux distributions
that repackage Go sometimes change that default, which is one reason two
machines with "the same Go" can behave differently.

#table(
  columns: (auto, 1fr),
  table.header([Value], [Behaviour]),
  [`local`], [Always use the bundled toolchain. Refuse to work in a module whose `go` line is newer.],
  [`auto`], [Short for `local+auto`: start from the bundled toolchain, switch to a newer one if `go.mod` or `go.work` asks, finding it on `PATH` or downloading it.],
  [`path`], [Short for `local+path`: like `auto`, but never download. The newer toolchain must be on `PATH` as a binary named, say, `go1.27.3`.],
  [`go1.27.3`], [Always run exactly that toolchain, from `PATH` or downloaded, whatever the module says.],
  [`go1.27.3+auto`], [Start from go1.27.3 instead of the bundled toolchain, and still switch to anything newer a module requires.],
)

The selection logic is short enough to draw. @fig-tc-select shows it for the
`+auto` and `+path` forms; `local` and a bare version stop at the first step.

#fig(placement: auto, caption: [How the `go` command picks a toolchain at startup. Commands such as `go get` can also switch mid-run when they add a dependency that needs a newer Go.])[
  #diagram(
    spacing: (16pt, 14pt),
    dnode((1, 0), [`go` command starts\ bundled toolchain go1.26.4], kind: "dark"),
    dnode((1, 1), [read `GOTOOLCHAIN`\ env → `go env -w` → `$GOROOT/go.env`], kind: "accent"),
    dnode((0, 2), [`local`\ bundled only, or refuse], kind: "muted"),
    dnode((1, 2), [`go1.27.3`\ exactly that version], kind: "muted"),
    dnode((2, 2), [`+auto` / `+path`\ read `go.work` or `go.mod`], kind: "accent"),
    dnode((2, 3), [`toolchain` line, else `go` line:\ newer than the default?], kind: "default"),
    dnode((1, 4), [yes: run `go1.27.3` from `PATH`,\ else download `golang.org/toolchain`\ (`+auto` only)], kind: "good"),
    dnode((3, 4), [no: run the\ default toolchain], kind: "muted"),
    dedge((1, 0), (1, 1), "-|>"),
    dedge((1, 1), (0, 2), "-|>"),
    dedge((1, 1), (1, 2), "-|>"),
    dedge((1, 1), (2, 2), "-|>"),
    dedge((2, 2), (2, 3), "-|>"),
    dedge((2, 3), (1, 4), "-|>"),
    dedge((2, 3), (3, 4), "-|>"),
  )
] <fig-tc-select>

The two restrictive settings fail loudly, which is what you want in some
places. Still in the clone:

#session(
  ("GOTOOLCHAIN=local go build ./...", "ch01/tc-local-build.txt"),
  ("GOTOOLCHAIN=path go version", "ch01/tc-path.txt"),
)

Downloaded toolchains are verified like any other module: the `go` command
checks them against the public checksum database, and `GOPRIVATE` and
`GONOSUMDB` do not apply to them. If you set `GOSUMDB=off`, toolchain
downloads fail for lack of verification rather than running an unverified
compiler. The download goes through `GOPROXY`, which matters as soon as a
company runs its own proxy (@sec-tc-scale).

#warning(title: [Corporate proxies and toolchain switching])[
  An internal module proxy that only mirrors an allow-list of modules will
  usually not serve `golang.org/toolchain`. The first developer who runs
  `go build` in a repository whose `toolchain` line is newer than their
  installed Go gets `toolchain not available`, which reads as if the release
  doesn't exist (the checkpoint below reproduces it). Either mirror
  `golang.org/toolchain` (each version is about 70 MB per platform) or
  install toolchains by other means and set `GOTOOLCHAIN=path`, so the
  failure message names the missing binary.
]

=== Managing the lines with go get

Edit the `go` and `toolchain` lines with `go get`, not by hand. The `go`
command treats them as dependencies and keeps them consistent. Create a
module with the 1.26.4 on your `PATH`:

#session(
  ("mkdir \"$LAB/svc\" && cd \"$LAB/svc\"", none),
  ("go mod init example.com/svc", "ch01/tc-init.txt"),
  ("cat go.mod", "ch01/tc-gomod1.txt"),
  ("go get go@1.27.0 toolchain@go1.27.3", "ch01/tc-get.txt"),
  ("cat go.mod", "ch01/tc-gomod2.txt"),
)

`go mod init` wrote the full version of the toolchain that ran it, `1.26.4`.
For an application that is harmless; for a library it needlessly forces
every consumer onto that patch release. (The Go 1.26 release notes describe
`go mod init` writing an older default; the go1.26.4 and go1.27.3 toolchains
used for this book still write their own version, so set the line
deliberately.) Raising the requirement to 1.27.0 needed a newer toolchain, so
`go get` switched to go1.27.3 _in the middle of the command_ and recorded
the toolchain it used.

Now remove the `toolchain` line and see what the `go` line alone selects:

#session(
  ("go get toolchain@none", "ch01/tc-none.txt"),
  ("go version", "ch01/tc-none-version.txt"),
)

go1.27.0, the oldest release that satisfies `go 1.27.0`, and not the latest
patch with its security fixes. This is minimal version selection, the same
rule Lab 2 applies to modules, applied to the compiler. It is why
applications and tools should carry a `toolchain` line naming the current
patch release, and why bumping it belongs in the same automated update flow
as any other dependency. Since Go 1.25 the `go` command no longer adds a
`toolchain` line on its own when it raises the `go` line, so the line only
changes when someone decides it should. The modules you create in Labs 5 and
7 follow this policy from their first commit.

#production(title: [A toolchain policy that survives 200 engineers])[
  Libraries: `go` line at the oldest Go release you still test against, no
  `toolchain` line. Applications and tools: `go` line at the current minor
  release, `toolchain` line at its latest patch, bumped by a bot in its own
  pull request so the CI run proves the upgrade. CI: install the version from
  `go.mod` (`actions/setup-go` with `go-version-file: go.mod`, as this
  repository does), and consider `GOTOOLCHAIN=local` on build runners so an
  unexpected switch is a failure instead of a silent download. Developer
  laptops: leave `auto` on, so nobody needs to manage Go versions by hand.
]

#interview(title: [“What happens when go.mod needs a newer Go than you have installed?”])[
  Since Go 1.21 the `go` line is a minimum requirement, not a hint. With the
  default `GOTOOLCHAIN=auto`, the `go` command reads the `toolchain` line (or
  the `go` line), finds that version on `PATH` or downloads it as the
  checksum-verified module `golang.org/toolchain`, and re-executes itself
  with it. With `GOTOOLCHAIN=local` it refuses with "go.mod requires go >=
  1.27.0". Mention `GODEBUG=toolchaintrace=1` for debugging, that
  `go get go@1.N` is how you change the requirement, and that the `go` line alone
  selects the `.0` release, which is why applications pin a patch release
  with the `toolchain` line.
]

#checkpoint(step: 1, of: 10, title: [Which Go runs?])[
  Your `$LAB/svc/go.mod` has a `go` line and no `toolchain` line:
  #output("ch01/l1-cp-gomod.txt", cmd: "cat go.mod")
  One `go` command, three toolchains, chosen by the directory you run it in:
  #session(
    ("cd \"$LAB\" && go version", "ch01/l1-cp-lab.txt"),
    ("cd \"$LAB/svc\" && go version", "ch01/l1-cp-svc.txt"),
    ("cd \"$LAB/platform-go\" && go version", "ch01/l1-cp-repo.txt"),
  )
  When you are done, open a new terminal (or remove `~/sdk/go1.26.4/bin`
  from `PATH`) and run `export LAB="$HOME/ch01"` again: the remaining labs
  use the Go you installed.
  #troubleshoot(
    ([#ts("tc-local-build.txt")], [`GOTOOLCHAIN=local` (set in the environment, by `go env -w`, or by a distribution's `go.env`) and a `go` line newer than the installed Go.], [Unset it (`go env -u GOTOOLCHAIN`), or install the version. See "The GOTOOLCHAIN setting".]),
    ([#ts("tc-path.txt")], [`GOTOOLCHAIN=path` and no binary named after the version on `PATH`.], [Install it with `golang.org/dl`, or allow downloads with `auto`.]),
    ([#ts("l1-proxy.txt")], [The proxy cannot serve `golang.org/toolchain` (here `GOPROXY=off`; in companies, an allow-list proxy). The version does exist.], [Mirror the toolchain module, or install it and use `GOTOOLCHAIN=path`.]),
    ([#ts("l1-sumdb.txt")], [`GOSUMDB=off`. Toolchains are never run unverified.], [Turn the checksum database back on for `golang.org/toolchain`.]),
    ([#ts("l1-invalid.txt")], [A hand-edited `toolchain 1.27.3`; the name needs its `go` prefix.], [`go get toolchain@go1.27.3`. See "Managing the lines with go get".]),
  )
]

#step(2, 10, "Lab 2: Minimal version selection", label: <sec-tc-modules>)

A module's path (`github.com/rahulbalajee/platform-go`) is both its name and
the prefix of every import path inside it. Its versions are tags in the
repository it lives in.

#goconcept(title: [Module versions])[
  Go module versions are _semantic versions_: `v1.4.0` is major 1, minor 4,
  patch 0. A minor release adds features without breaking callers, a patch
  release only fixes bugs, and a major release may break anything. `v0.x.y`
  promises nothing, which is why many young libraries stay there. Untagged
  commits get a _pseudo-version_ such as
  `v0.0.0-20261103081532-b0977b0a7e31`: a base version, the commit time in
  UTC, and a 12-character commit hash prefix, so they still sort in commit
  order. After a tag, the base moves up: the commit after `v0.1.0` is
  `v0.1.1-0.<time>-<hash>`, which sorts after `v0.1.0` and before any real
  `v0.1.1`. Repositories that had `v2` tags before modules existed appear
  with `+incompatible`. Pseudo-versions also show up in the build
  information of every binary built from an untagged commit, as Labs 7 and 8
  show.
]

=== Semantic import versioning

Go applies one rule that other ecosystems do not: *a new major version is a
new module path.* Version 2 of `example.com/codec` is the module
`example.com/codec/v2`, imported by that path. The rule follows from the
import compatibility rule: if an old package and a new package have the same
import path, the new one must be backward compatible with the old one. A
breaking change therefore needs a new path.

The consequence for platform code is practical. Two major versions of the
same library can be in one build, because to the toolchain they are
unrelated modules. A service can migrate to `codec/v2` one package at a time
while a dependency still uses v1. The cost is that maintainers must create
the `/v2` path, which some projects avoid by staying on v0 forever or by
tagging `+incompatible` versions from before modules existed.

=== Reading the build list

The module graph is a list of edges: "this module version requires at least
that module version". `go mod graph` prints it, one edge per line, and for
the repository's root module that is too many lines to read whole, so filter
it:

#session(
  ("cd \"$LAB/platform-go\"", none),
  ("go mod graph | wc -l", "ch01/mod-graph-count.txt"),
  ("go mod graph | grep '^go.uber.org/goleak'", "ch01/mod-graph-goleak.txt"),
)

Every `go.mod` contributes edges, including those of modules you never
import directly. `goleak` is a test helper the root module requires; the
second command shows what it requires in turn, `testify` among them, and
`testify`'s own requirements are edges in the same graph. The `go` and
`toolchain` requirements appear as nodes too, alongside the modules.

The algorithm that turns this graph into the set of versions used for a build
is *minimal version selection* (MVS), designed by Russ Cox for Go modules.
It is short: start at the main module, walk every reachable requirement, and
for each module keep the _highest_ version anyone requires. That list is the
build list. The rule is easiest to see on the one dependency every module
shares, the Go toolchain itself. Since Go 1.21,
a `go` line is a requirement like any other: `go@1.26.0` means "this module
needs at least Go 1.26.0", and `go get` manages it the way it manages
`require` lines.

#session(
  ("go mod graph | awk '$2 ~ /^go@/ {print $2}' | sort -V | uniq -c", "ch01/mod-go-graph.txt"),
  ("go list -m go", "ch01/mod-go-list.txt"),
)

The `awk` program keeps the edges that end in a `go` version, and `uniq -c`
counts how many modules ask for each. The minimums run from Go 1.21 to
1.26.0, and one module, the root, asks for 1.27.0. MVS selects 1.27.0, the
maximum of the minimums, and that is the oldest toolchain that can build
this module. The same rule
explains the toolchain switch in Lab 1: when a dependency upgrade arrives with
a higher `go` line, `go get` raises yours to match, and every developer's
`go` command fetches the newer toolchain. MVS also never looks at what exists
on the proxy. If `x/sys` v0.50.0 was released this morning, nothing changes
until someone asks for it.

The same rule at a larger scale, in the `watchtower` operator's module:

#session(
  ("cd projects/watchtower", none),
  ("go mod graph | awk '$2 ~ /^golang.org\\/x\\/net@/ {print $2}' | sort -V | uniq -c", "ch01/mod-xnet.txt"),
  ("go list -m golang.org/x/net", "ch01/mod-xnet-list.txt"),
)

Seventeen requirements on `golang.org/x/net` at five different minimum
versions, from gRPC, OpenTelemetry, the Kubernetes libraries, the Prometheus
client and the operator itself. The build uses one version, v0.60.0, the
highest anyone asked for. Every library in the build gets a version at least
as new as the one it declared, and never a version that nobody asked for.

=== A module universe you can run

Real dependency graphs are too large to experiment on, and public modules
cannot be edited to show what a retraction looks like. The repository
therefore ships `mkproxy`, a small program that turns a txtar archive (a
plain-text bundle of files, each introduced by a `-- name --` line) into a
directory laid out in the `GOPROXY` protocol, and a universe of modules
written for this chapter: a service, `example.com/app`, uses a logging
library and a metrics library, and both depend on `example.com/codec` at
different minimum versions. @fig-tc-mvs shows the shape.

#fig(placement: auto, caption: [The demo universe. Solid arrows are requirements in the build; MVS selects the highest required version of `codec` (v1.4.0), not the newest one that exists (v1.5.1). `codec/v2` is a different module.])[
  #diagram(
    spacing: (14pt, 22pt),
    dnode((1, 0), [example.com/app], kind: "dark"),
    dnode((0, 1), [log v1.2.0], kind: "default"),
    dnode((1, 1), [metrics v1.2.0], kind: "default"),
    dnode((2, 1), [metrics v1.3.0\ available], kind: "muted"),
    dnode((3, 1), [codec/v2 v2.0.0\ separate module], kind: "accent"),
    dnode((0, 2), [codec v1.3.0], kind: "muted"),
    dnode((1, 2), [*codec v1.4.0*\ selected], kind: "good"),
    dnode((2, 2), [codec v1.5.0\ retracted], kind: "warn"),
    dnode((3, 2), [codec v1.5.1\ newest], kind: "muted"),
    dedge((1, 0), (0, 1), "-|>"),
    dedge((1, 0), (1, 1), "-|>"),
    dedge((1, 0), (3, 1), "-|>"),
    dedge((0, 1), (0, 2), "-|>", label: [≥]),
    dedge((1, 1), (1, 2), "-|>", label: [≥]),
    dedge((2, 1), (2, 2), "--|>"),
  )
] <fig-tc-mvs>

Generate the universe from the clone, then point the `go` command at it. The
two `export` lines make this terminal use the generated proxy and a module
cache of its own under `$LAB`, so nothing touches the internet and your real
module cache stays clean:

#session(
  ("cd \"$LAB/platform-go\"", none),
  ("go run ./examples/ch01/mkproxy -o \"$LAB/mvs\" examples/ch01/mkproxy/universe.txtar", none),
  ("cd \"$LAB/mvs/app\"", none),
  ("export GOPROXY=\"file://$LAB/mvs/proxy\" GONOSUMDB=example.com", none),
  ("export GOMODCACHE=\"$LAB/modcache\" GOFLAGS=-modcacherw", none),
  ("go mod tidy", "ch01/mvs-tidy.txt"),
  ("go list -m all", "ch01/mvs-list.txt"),
  ("go run .", "ch01/mvs-run.txt"),
)

The `log` library asked for `codec` v1.3.0 and runs with v1.4.0, because
`metrics` needs v1.4.0 and there is only one `codec` v1 in a build. That is
the contract MVS relies on: a library declares the oldest version it works
with and must keep working with newer v1 releases. `codec/v2` sits alongside
as a separate module. (`GONOSUMDB=example.com` tells the `go` command these
modules are not in the public checksum database, and `-modcacherw` leaves the
lab's module cache deletable; Lab 4 explains both.) The graph shows every
edge MVS considered:

#output("ch01/mvs-graph.txt", cmd: "go mod graph")

The proxy directory itself is worth a look, because it _is_ the protocol: a
proxy is anything that can serve these files over HTTPS, or from disk.

#output("ch01/mvs-proxy.txt", cmd: "ls -C \"$LAB/mvs/proxy/example.com/codec/@v\"")

`list` names the versions, `.info` gives a version's canonical name and
time, `.mod` is its `go.mod`, and `.zip` holds the source under a
`module@version/` prefix. The `go` command fetches `.mod` files for every
version it needs to consider while building the graph, and `.zip` files only
for versions it selects. `mkproxy` is under 200 lines of standard library code
(`archive/zip`, `encoding/json`) that writes these files; a test in the same
package runs `go list -m all` against the generated proxy, so the universe in
this chapter cannot drift from what the toolchain really does.

=== Upgrades are explicit

Before changing anything, save the tidy state; Lab 3 returns to it several
times:

#session(("cp go.mod go.mod.orig && cp go.sum go.sum.orig", none))

Because nothing changes until someone asks, upgrading is a deliberate act.
`go list -m -u` shows what is available, and `go get` moves requirements:

#session(
  ("go list -m -u all", "ch01/mvs-u.txt"),
  ("go get example.com/metrics@v1.3.0", "ch01/mvs-get.txt"),
  ("go run .", "ch01/mvs-run2.txt"),
)

Upgrading `metrics` raised its own requirement on `codec` to v1.5.0, and MVS
followed: `go get` recorded both changes in `go.mod`. That version turned out
to be bad, which is the next lab's subject.

#internals(title: [Why Go has no lock file])[
  npm, pip and Cargo resolve "the newest version that satisfies the
  constraints" at install time, so the answer changes whenever upstream
  publishes and a lock file must freeze it. MVS only selects versions named
  in some `go.mod`, so the build list is a pure function of the graph. Since
  Go 1.17, `go.mod` also lists every module that provides a package to the
  build (`// indirect` for those you don't import), which lets the `go`
  command prune dependencies' graphs and read far fewer `go.mod` files.
]

#interview(title: [“Explain minimal version selection.”])[
  Every module states the _minimum_ version of each dependency it needs; MVS
  selects, for each module, the highest of those minimums across the graph.
  The result is deterministic, needs no lock file, and a release upstream
  cannot change your build. The trade-off: you get no fixes until you ask
  (`go get -u`, or a bot), and a library's tests may have run against an
  older dependency than your build selects. Give a concrete case: a
  dependency asks for `x/sys` v0.26.0, the module asks for v0.49.0, the
  build uses v0.49.0. Then mention that `go.sum` holds hashes, not versions.
]

#checkpoint(step: 2, of: 10, title: [Minimal version selection])[
  `$LAB/mvs` holds `app`, `fork` and `proxy`, and `$LAB/modcache` the
  downloaded modules. After the upgrade, `app/go.mod` reads:
  #output("ch01/l2-cp-gomod.txt", cmd: "cat go.mod")
  and the graph has the new edges, with `codec` v1.5.0 now the highest
  requirement:
  #output("ch01/l2-cp-graph.txt", cmd: "go mod graph")
  Keep this terminal open: Labs 3 and 4 continue in it, with its exports.
  #troubleshoot(
    ([#ts("l2-gosum.txt")], [`go run` before `go mod tidy`: the requirements are listed but their checksums are not in `go.sum` yet.], [Run `go mod tidy` first.]),
    ([#ts("l2-noproxy.txt")], [A new terminal without the `GOPROXY` export: the `go` command looked for `example.com/log` on the internet.], [Repeat the `export` lines. See "A module universe you can run".]),
    ([#ts("l2-nomod.txt")], [The command ran in `$LAB/mvs`, not in `app`, so there is no module.], [`cd "$LAB/mvs/app"`.]),
  )
]

#step(3, 10, "Lab 3: Retract, exclude, replace", label: <sec-tc-directives>)

Three directives modify version selection. They behave differently enough
that each one is worth seeing in action. Continue in the terminal from Lab 2,
in `$LAB/mvs/app`.

=== retract: the author withdraws a version

`codec` v1.5.0 shipped a bug that silently drops zero-valued fields when
encoding. The maintainers cannot delete the tag: the module proxy has cached
it, and deleting it would break every build that already selected it.
Instead they publish v1.5.1 with a `retract` directive in its `go.mod`:

#output("ch01/mvs-retract-mod.txt", cmd: "cat \"$LAB/mvs/proxy/example.com/codec/@v/v1.5.1.mod\"")

Retractions are read from the latest version of the module, and they change
what tools _recommend_, not what builds use. The `go get` in Lab 2 already
printed a warning with the rationale from the comment. Now:

#output("ch01/mvs-u2.txt", cmd: "go list -m -u all")

The current build is flagged, and `-u` offers the fix. The retracted version
is also hidden from version lists and `@latest` queries:

#session(
  ("go list -m -versions example.com/codec", "ch01/mvs-versions.txt"),
  ("go list -m -retracted -versions example.com/codec", "ch01/mvs-retracted.txt"),
  ("go get example.com/codec@latest", "ch01/mvs-latest.txt"),
)

Builds that already selected v1.5.0 keep working, as the `go run` after the
upgrade showed. That is deliberate: a retraction must never break a build
that is already in production.

=== exclude: the consumer refuses a version

`exclude` lives in the main module's `go.mod` and is ignored everywhere else.
It removes a version from the graph. Its semantics changed in Go 1.16 and
surprise people, so here is what it does when we exclude the version MVS
selected. Restore the saved state first:

#session(
  ("cp go.mod.orig go.mod && cp go.sum.orig go.sum", none),
  ("go mod edit -exclude example.com/codec@v1.4.0", none),
  ("go mod tidy", "ch01/mvs-exclude-tidy.txt"),
  ("go run .", "ch01/mvs-exclude-run.txt"),
)

#warning(title: [`exclude` can push a dependency below its own minimum])[
  Requirements on an excluded version are not redirected to the next version
  up; they are _dropped_. With `metrics`' requirement on v1.4.0 gone, the
  highest remaining requirement was `log`'s v1.3.0, and `go mod tidy`
  silently _downgraded_ the build. `metrics` now runs against an older
  `codec` than it declared it needs, and nothing failed. If you exclude a
  version, pin the replacement at the same time
  (`go get example.com/codec@v1.5.1`) and read the `go.mod` diff.
]

=== replace: use different code

`replace` substitutes the contents of a module, either with another module
version (a fork) or with a directory on disk. The universe has a fork of
`codec` in `$LAB/mvs/fork/codec`:

#session(
  ("cp go.mod.orig go.mod && cp go.sum.orig go.sum", none),
  ("go mod edit -replace example.com/codec=../fork/codec", none),
  ("go list -m example.com/codec", "ch01/mvs-replace-list.txt"),
  ("go run .", "ch01/mvs-replace-run.txt"),
)

Like `exclude`, `replace` only applies in the main module. A library that
ships with a `replace` directive changes nothing for its consumers, who get
the original module and a different program than the library's own tests
exercised. Use `replace` for short-lived fixes in applications, and point it
at a tagged version of a fork (`=> github.com/acme/codec v1.4.1-acme.1`)
rather than a local directory, so CI and colleagues can build. For editing
two modules at once on your machine, a workspace (Lab 6) is the better tool,
because it never touches `go.mod`.

#table(
  columns: (auto, auto, 1fr),
  table.header([Directive], [Written by], [Effect]),
  [`retract`], [module author], [Hides versions from `@latest`, `-versions` and upgrades; warns users who have them. Builds keep working.],
  [`exclude`], [main module], [Removes a version from the graph. Requirements on it are dropped, which can lower the selected version.],
  [`replace`], [main module or `go.work`], [Swaps a module's contents for another version or a directory. Ignored when your module is a dependency.],
  [`ignore`], [main module (Go 1.25)], [Not about versions: hides directories such as `node_modules` from `./...` patterns while keeping them in module zips.],
)

#checkpoint(step: 3, of: 10, title: [Retract, exclude, replace])[
  With the replacement in place, the end of `go.mod` and the build list
  read:
  #session(
    ("tail -2 go.mod", "ch01/l3-cp-tail.txt"),
    ("go list -m all", "ch01/l3-cp-list.txt"),
  )
  Restore the saved state before Lab 4:
  #session(("cp go.mod.orig go.mod && cp go.sum.orig go.sum", none))
  #troubleshoot(
    ([#ts("l3-notidy.txt")], [`go mod edit` changed the requirements, and `go run` refuses to update `go.mod` on its own (`-mod=readonly`, the default since Go 1.16).], [Run `go mod tidy`, then read the diff.]),
    ([#ts("l3-typo.txt")], [The `replace` target path is wrong (here `codex`). Directory replacements are relative to the main module.], [`go mod edit -replace` again with the right path, or `-dropreplace`.]),
    ([#ts("l3-retracted.txt")], [You asked for a retracted version explicitly. `go get` allows it and warns.], [`go get example.com/codec@latest`. See "retract".]),
  )
]

#step(4, 10, "Lab 4: Checksums, proxies and private modules", label: <sec-tc-trust>)

MVS decides _which_ versions to use. A second mechanism makes sure every
machine gets the _same bytes_ for those versions. Continue in the terminal
from Labs 2 and 3, in `$LAB/mvs/app`.

=== go.sum

`go.sum` holds a cryptographic hash of every module version the build has
needed, usually two lines per version:

#output("ch01/mvs-sum.txt", cmd: "cat go.sum")

The `h1:` hash covers the module's zip file; the `/go.mod` line covers only
its `go.mod`, which is all the `go` command needs for versions that take part
in graph construction but are not selected (`codec` v1.3.0 here). When the
`go` command downloads a module into the cache it recomputes the hash and
refuses to use the module if it differs. `go mod verify` re-checks everything
already in the module cache:

#output("ch01/l4-verify.txt", cmd: "go mod verify")

Now break it, the way a bad merge or a compromised mirror would. Open
`go.sum` in an editor, change a few characters of the `h1:` hash on the
`example.com/codec v1.4.0` line (not the `/go.mod` one), save, and build:

#output("ch01/l4-mismatch.txt", cmd: "go run .")

Put the real `go.sum` back with `cp go.sum.orig go.sum`. The module cache is
protected too. Files in it are read-only, but nothing stops someone from
making one writable and "fixing" a bug in place:

#session(
  ("chmod u+w \"$LAB/modcache/example.com/codec@v1.4.0/codec.go\"", none),
  ("echo '// patched in place' >> \"$LAB/modcache/example.com/codec@v1.4.0/codec.go\"", none),
  ("go mod verify", "ch01/l4-tamper.txt"),
)

`go build` does not re-hash the cache on every run, so only `verify` notices.
Removing the module's directory is enough to recover; the next build
unpacks it again from the verified zip:

#session(
  ("rm -rf \"$LAB/modcache/example.com/codec@v1.4.0\" && go mod verify", "ch01/l4-fix.txt"),
  ("go run .", "ch01/l4-fix-run.txt"),
)

=== The checksum database

`go.sum` protects you from a module changing _after_ you first fetched it.
It cannot help the first time: whoever adds a dependency trusts whatever the
proxy or the origin server returned at that moment. The checksum database at
`sum.golang.org` closes that gap. It is a transparency log, an append-only
Merkle tree of `go.sum` lines for every public module version anyone has
fetched, signed by Google and auditable by anyone.

For the rest of this lab, leave the universe. Remove the exports, so the
`go` command uses its defaults again, and go back to the clone:

#session(
  ("unset GOPROXY GONOSUMDB GOMODCACHE GOFLAGS", none),
  ("cd \"$LAB/platform-go\"", none),
  ("grep golang.org/x/sync go.sum", "ch01/trust-sum.txt"),
  ("curl -s https://sum.golang.org/lookup/golang.org/x/sync@v0.24.0 | cut -c1-80", "ch01/trust-sumdb.txt"),
)

The database's record for `x/sync` v0.24.0 has the same two lines as the
repository's `go.sum`. The first line of the record is its position in the
log, then come the two `go.sum` lines, then a signed tree head (the log size
and root hash). Before writing a new line to `go.sum`, the `go` command
checks it against this log and verifies the log's consistency with what it
has seen before. A proxy that serves different bytes to you than to everyone
else gets caught, which is why the public proxy does not need to be trusted.
If an author moves a tag to different code, the checksum database still holds
the original hash, and every fresh download of the new bytes fails
verification.

=== Proxies and the resolution path

#fig(placement: auto, caption: [How the `go` command obtains a module version it does not have in its cache.])[
  #diagram(
    spacing: (18pt, 13pt),
    dnode((0, 0), [needs `example.com/m@v1.2.3`], kind: "dark"),
    dnode((0, 1), [path matches `GOPRIVATE`\ or `GONOPROXY`?], kind: "accent"),
    dnode((1, 1), [direct: `git` over HTTPS/SSH\ `.netrc`, `GOAUTH`, `insteadOf`], kind: "warn"),
    dnode((0, 2), [`GOPROXY` list, in order\ `,` falls through on 404/410\ `|` falls through on any error], kind: "default"),
    dnode((0, 3), [path matches `GONOSUMDB`\ or `GOPRIVATE`?], kind: "accent"),
    dnode((1, 3), [skip the checksum database], kind: "muted"),
    dnode((0, 4), [verify with `GOSUMDB`\ (`sum.golang.org`)], kind: "good"),
    dnode((0, 5), [compare with `go.sum`, add if missing,\ unpack into `GOMODCACHE`], kind: "default"),
    dedge((0, 0), (0, 1), "-|>"),
    dedge((0, 1), (1, 1), "-|>", label: [yes]),
    dedge((0, 1), (0, 2), "-|>", label: [no]),
    dedge((1, 1), (1, 3), "-|>"),
    dedge((0, 2), (0, 3), "-|>"),
    dedge((0, 3), (1, 3), "-|>", label: [yes]),
    dedge((0, 3), (0, 4), "-|>", label: [no]),
    dedge((1, 3), (0, 5), "-|>"),
    dedge((0, 4), (0, 5), "-|>"),
  )
] <fig-tc-fetch>

@fig-tc-fetch shows the whole path. `GOPROXY` defaults to
`https://proxy.golang.org,direct`: try Google's module mirror, and if it
answers 404 or 410, clone from the origin. The separator matters. After a
comma the `go` command only tries the next entry on "not found"; any other
error, such as a 403 or a timeout, is final. After a pipe (`|`) it moves on
after any error. The comma is what lets a company proxy act as a gatekeeper:
a 403 for a blocked module stops the download instead of falling through to
the internet. `off` disables downloads entirely, which is useful in hermetic
build steps that should only use a pre-populated cache. Lab 2's universe used
a third kind of entry, a `file://` URL, which is how air-gapped environments
serve a proxy from a mounted directory.

=== Private modules on GitHub

Private code needs three things: the `go` command must not ask public
services about it, it needs credentials, and it must know which repository
to clone. `GOPRIVATE` handles the first. It is a list of path globs, and it
is the default for both `GONOPROXY` (fetch directly) and `GONOSUMDB` (don't
consult the checksum database, which would leak the module path and fail
anyway; the troubleshooting table shows that failure for Lab 2's modules):

#output("ch01/trust-private.txt", cmd: "GOPRIVATE='github.com/acme/*' go env GOPRIVATE GONOPROXY GONOSUMDB")

For credentials, the `go` command runs `git`, which authenticates the way
`git` always does. For GitHub there are two common setups. On laptops,
developers usually have SSH keys, so a URL rewrite makes `git` use SSH for
HTTPS URLs:

#code(file: "~/.gitconfig")[```
[url "git@github.com:"]
	insteadOf = https://github.com/
```]

In CI, a read-only token works better than an SSH key. Put it in `~/.netrc`
(`machine github.com login x-access-token password` followed by the token),
or add a `git config` URL rewrite from `https://github.com/` to an HTTPS URL
that carries the token as its password. Either way, keep it out of logs. Go
1.24 added `GOAUTH`, which generalises the `.netrc` lookup: the default is
`netrc`, `git <dir>` asks a `git` credential helper, and a custom command can
return arbitrary HTTP headers (for example a short-lived bearer token for a
private proxy) scoped to URL prefixes, something `.netrc` cannot do.

#warning(title: [Two private-module mistakes that leak or break])[
  `GOPRIVATE` turns off checksum database verification for its paths. Add
  `GOINSECURE` for the same paths (to reach an internal Git server without
  TLS) and nothing verifies that code at all: anyone on the network path can
  serve you a module. And putting a token in a `GOPROXY` URL works, but
  environment variables end up in CI logs, crash reports and `go env` output
  pasted into issues. Prefer `.netrc` or `GOAUTH`.
]

=== GOFLAGS and friends

`GOFLAGS` holds default flags for every `go` command that understands them,
space-separated. `-mod=readonly` (the default since Go 1.16, so you rarely
set it) makes any command that would need to change `go.mod` fail instead,
which is what CI wants; Lab 3's troubleshooting table shows the
message. `-modcacherw` leaves the module cache writable so scratch
directories can be deleted, as Lab 2 did. Setting `-trimpath` here is
tempting but hides it from anyone reading the build command; put release
flags in the Makefile or the release tool.

=== Vendoring

`go mod vendor` copies every package the build needs into `vendor/`, and the
`go` command uses it automatically when it exists (for `go` lines of 1.14 and
later). It answers real requirements: air-gapped builds, auditors who want
every line of shipped source in the repository, build systems such as Bazel
that dislike network access. Its costs scale with the dependency graph:

#session(
  ("cd projects/watchtower", none),
  ("go mod vendor && du -sh vendor && find vendor -name \"*.go\" | wc -l", "ch01/vendor.txt"),
  ("rm -rf vendor", none),
)

That is `watchtower`: 69 MB and over five thousand Go files, and every
dependency bump becomes a diff of thousands of lines that nobody reviews. With
the checksum database and an internal proxy (@sec-tc-scale) giving
availability and integrity, most teams do not need to vendor. If you do, keep
`go.sum` and run `go mod vendor` in CI followed by `git diff --exit-code` so
nobody edits vendored code by hand.

#checkpoint(step: 4, of: 10, title: [Checksums, proxies and private modules])[
  Your terminal is back to the `go` command's defaults, and the module cache
  holds what `go.sum` says:
  #session(
    ("go env GOPROXY GONOSUMDB GOMODCACHE GOFLAGS", "ch01/l4-cp-env.txt"),
    ("go mod verify", "ch01/trust-verify.txt"),
  )
  #troubleshoot(
    ([#ts("l4-mismatch.txt")], [The bytes do not match `go.sum`: an edited `go.sum`, a moved tag, or a tampered download.], [Never "fix" it by deleting the line. Find out which side changed; restore `go.sum` from version control.]),
    ([#ts("l4-tamper.txt")], [Files in the module cache were edited after download.], [Delete that module's directory (or `go clean -modcache`) and build again.]),
    ([#ts("l4-nosum.txt")], [`go.sum` was deleted or not committed.], [`go mod tidy`, then review the new `go.sum` before committing it.]),
    ([#ts("l4-sumdb.txt")], [A module path the public checksum database cannot know about, without `GONOSUMDB` or `GOPRIVATE`.], [Set `GOPRIVATE` for your company's paths. See "Private modules on GitHub".]),
  )
]

#step(5, 10, "Lab 5: A code generator pinned with the tool directive", label: <sec-tc-tools>)

Projects depend on programs as well as packages: code generators such as
`stringer` and `controller-gen`, `govulncheck`, protobuf plugins. For years
the convention was a `tools.go` file with blank imports behind a build tag,
so that `go.mod` would record the versions, plus a Makefile that ran
`go install` for each one. It worked, but it was folklore.

#newingo("1.24", title: [The `tool` directive])[
  `go get -tool <package>` adds a `tool` line to `go.mod` (and the `require`
  lines for its module), and `go tool <name>` builds and runs it at exactly
  that version, caching the binary in the build cache. The `tool`
  meta-pattern means "all tools of this module", so `go get tool` upgrades
  them all and `go install tool` installs them into `GOBIN`.
]

In this lab you start the module that holds your team's tools, pin
`stringer` in it, and use it to generate code. Open a *new terminal*, so
none of Lab 2's exports are left, and set `$LAB` again:

#session(
  ("export LAB=\"$HOME/ch01\"", none),
  ("mkdir \"$LAB/tools\" && cd \"$LAB/tools\"", none),
  ("go mod init tools", "ch01/l5-init.txt"),
  ("go get go@1.27.0 toolchain@go1.27.3", "ch01/l5-goget.txt"),
  ("go get -tool golang.org/x/tools/cmd/stringer@v0.52.0", "ch01/tools-get.txt"),
  ("cat go.mod", "ch01/l5-gomod.txt"),
)

`go mod init` wrote the version of the Go you run, and the second command
applied Lab 1's policy for tools: the `go` line at the minor release, the
`toolchain` line at its patch. The `tool` line names the package; the
`require` lines, marked `// indirect` because no package imports them, pin
the versions, and `go.sum` pins the bytes.

=== An enum that names itself

The module's one package models the phases of a progressive rollout, the
kind of enum that ends up in logs, JSON and metrics labels and is tedious to
keep in sync by hand. Create `rollout/phase.go`, starting with the package
documentation:

#src("workbook/ch01/step1/rollout/phase.go", region: "head")

Then the type, its constants, and the line that tells `go generate` what to
run:

#src("workbook/ch01/step1/rollout/phase.go", region: "phase")

#goconcept(title: [Named types and `iota`])[
  `type Phase int` creates a new type whose values are integers but which
  the compiler keeps apart from plain `int`: a function that takes a `Phase`
  won't accept a stray `3`. Inside a `const` block, `iota` counts from zero,
  and a constant with no expression repeats the previous one, so
  `PhaseCanary` is 1 and `PhaseRolledBack` is 5. Chapter 0 introduced both.
  The numbers are an implementation detail here, which is the point of the
  comments after each constant: they are the names the outside world sees.
  Java's `enum` and Python's `Enum` attach names to values for you; Go
  leaves that to a method you write, or have a tool write.
]

#goconcept(title: [`//go:generate` and `go generate`])[
  A comment that starts exactly with `//go:generate` (no space after `//`)
  is a directive: `go generate ./...` finds it and runs the rest of the line
  as a command, in the directory of the file. Nothing else runs it;
  `go build` and `go test` ignore it, so generated files are committed to the
  repository like any other source. Here the command is `go tool stringer`,
  which runs the version pinned in `go.mod`, so every developer and CI job
  generates identical code. `-type=Phase` names the type, and
  `-linecomment` uses each constant's line comment as its name instead of
  the identifier.
]

Two helpers go after the constants: a list of every phase, and the reverse
of `String`:

#src("workbook/ch01/step1/rollout/phase.go", region: "parse")

Finally, two methods that make phases readable in JSON, which rely on
interfaces from the standard library.

#goconcept(title: [Interfaces you implement without saying so: `fmt.Stringer` and `encoding.TextMarshaler`])[
  An interface lists methods; any type that has those methods satisfies it,
  with no `implements` keyword (Chapter 0 covers interfaces). Two from the
  standard library matter here. `fmt.Stringer` is `String() string`: once
  `Phase` has that method, `fmt.Println(p)` and `%v` print `canary` instead
  of `1`. `encoding.TextMarshaler` is `MarshalText() ([]byte, error)`, and
  `encoding.TextUnmarshaler` is `UnmarshalText([]byte) error` on a pointer
  receiver (it has to change the value). `encoding/json` checks for them, so
  a `Phase` field becomes `"canary"` in JSON and is parsed back, and YAML
  libraries do the same. The pointer receiver matters: `UnmarshalText` on a
  value receiver would set a copy and change nothing.
]

#src("workbook/ch01/step1/rollout/phase.go", region: "text")

The package doesn't compile yet, because nothing has written `String`:

#output("ch01/l5-nogen.txt", cmd: "go build ./...")

That is `stringer`'s job. `go tool` lists the module's tools, and
`go generate` runs the directive with the pinned version:

#session(
  ("go tool | grep -F '('", "ch01/tools-list.txt"),
  ("go generate -x ./...", "ch01/tools-generate.txt"),
)

`-x` prints each command as it runs. The generated `phase_string.go` is
committed, so building the package never needs the generator. Its `String`
method slices one constant string, `"pendingcanaryprogressing..."`, using an
array of offsets, which costs no allocation and no map lookup. Above it sits a
function with a blank name:

#output("ch01/tools-phase-string.txt", cmd: "sed -n '/^func _/,/^}/p' rollout/phase_string.go", size: 6.6pt)

It is a compile-time freshness check. If someone inserts a phase without
regenerating, the constant values shift, one of the array indexes goes out of
range, and the build fails with "invalid argument: index out of bounds"
instead of logging the wrong phase name (the troubleshooting table has the
real message). Pair it with a CI step that runs `go generate ./...` and then
`git diff --exit-code`, so a stale generated file cannot be merged.

=== Tests

Create `rollout/phase_test.go`. The first test checks every name in both
directions, and the fallback `stringer` writes for values outside the set:

#src("workbook/ch01/step1/rollout/phase_test.go", region: "string")

The second checks the JSON form, including the two ways it must fail:

#src("workbook/ch01/step1/rollout/phase_test.go", region: "json")

=== Tools share your module graph

A `tool` line is a real dependency. Its module's requirements take part in
MVS together with your code's requirements. Here is what happens when someone
adds `govulncheck` as a tool of the `watchtower` operator, in the clone:

#session(
  ("cd \"$LAB/platform-go/projects/watchtower\"", none),
  ("go get -tool golang.org/x/vuln/cmd/govulncheck@v1.9.0", "ch01/tools-wt-get.txt"),
  ("git checkout -- go.mod go.sum", none),
)

Adding a vulnerability scanner upgraded the operator's _runtime_ HTTP/2
stack, `golang.org/x/net`, from v0.60.0 to v0.61.0, along with `x/sys` and
`x/text`. In this case the upgrade happens to be welcome (Lab 10 shows why),
but a pull request titled "add govulncheck" should not change what runs in
production. The more tools a module pins, the more of these interactions
there are. The `git checkout` throws the experiment away.

The fix is to keep tools in their own module, as you just did, and run them
from anywhere with `-modfile`. The repository's tools module is
`examples/ch01/tools`; from the clone's root:

#session(
  ("cd \"$LAB/platform-go\"", none),
  ("go tool -modfile=examples/ch01/tools/go.mod govulncheck -version", "ch01/tools-modfile.txt"),
)

Lab 10 adds `govulncheck` to your own tools module, which then matches the
repository's exactly.

#production(title: [Which tools belong in go.mod])[
  Put a tool in the main `go.mod` when its version must match a library the
  code uses: `controller-gen` with `controller-runtime`, `protoc-gen-go` with
  `google.golang.org/protobuf`, `mockgen` with its runtime package. Generated
  code and the library must agree, and sharing the graph enforces it. Put
  independent tools (scanners, linters, release tooling) in a separate tools
  module or install them as pinned binaries. This repository pins
  `golangci-lint` by version in CI and lets the GitHub Action download the
  release binary. Pinned as a tool in a scratch module, it brings a build
  list of about 400 modules, more than twice the operator's, and none of it
  belongs in anyone's build list.
]

#checkpoint(step: 5, of: 10, title: [A code generator pinned with the tool directive])[
  In `$LAB/tools` you have three Go files, one of them generated:
  #output("ch01/l5-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch01/tools-test.txt", cmd: "go vet ./... && go test ./...")
  #troubleshoot(
    ([#ts("l5-nogen.txt")], [`phase_string.go` doesn't exist: `go generate` never ran, or the directive is written `// go:generate`, with a space, which makes it an ordinary comment.], [Fix the directive and run `go generate ./...`.]),
    ([#ts("l5-notool.txt")], [`stringer` is not in this module's `tool` block (a different directory, or the `go get -tool` step was skipped).], [`go get -tool golang.org/x/tools/cmd/stringer@v0.52.0` in this module.]),
    ([#ts("l5-stale.txt")], [A constant was added without regenerating; the freshness check fired.], [`go generate ./...` and commit both files.]),
    ([#ts("l5-linecomment.txt")], [The directive lacks `-linecomment`, so names are the Go identifiers.], [Add the flag and regenerate.]),
    ([#ts("l5-goproxy.txt")], [This terminal still has Lab 2's `GOPROXY` and `GOMODCACHE`.], [`unset GOPROXY GONOSUMDB GOMODCACHE GOFLAGS`, or open a new terminal.]),
  )
]

#step(6, 10, "Lab 6: Workspaces and repository layout", label: <sec-tc-workspaces>)

The repository you cloned contains several modules. Suppose you are changing
`pkg/retry` in the root module and want the `watchtower` operator to use the
change before it is released. Without workspaces you would add a `replace`
directive to `watchtower/go.mod`, and then have to remember to remove it. A
workspace does the same thing from a file that is not part of either module.
A `go.work` file affects every `go` command run beneath its directory, so
this lab creates one in your clone and removes it at the end:

#session(
  ("cd \"$LAB/platform-go\"", none),
  ("go work init . ./projects/watchtower", none),
  ("cat go.work", "ch01/ws-cat.txt"),
  ("go list -m", "ch01/ws-list.txt"),
  ("go env GOWORK", "ch01/ws-env.txt"),
)

Both modules are now _main modules_. Packages from one see the other's
working tree directly, `go build ./...` and `go test ./...` work from either
directory, and the Go 1.25 `work` pattern (`go test work`) means "every
package in every module of the workspace". Now look at what MVS does with two
main modules:

#session(
  ("cd projects/watchtower", none),
  ("go list -m golang.org/x/sync golang.org/x/sys golang.org/x/time", "ch01/ws-versions.txt"),
  ("GOWORK=off go list -m golang.org/x/sync golang.org/x/sys golang.org/x/time", "ch01/ws-versions-off.txt"),
)

In the workspace, the requirements of _both_ modules feed one build list, so
the operator builds with the root module's newer `x/sync`, `x/sys` and
`x/time`. Outside it, `watchtower` uses its own. Tests that pass in the
workspace exercised versions that the released operator will not use.

#warning(title: [Don't commit go.work])[
  A committed `go.work` makes every developer and every CI job build the
  workspace's combined graph instead of each module's own. CI then tests
  versions no consumer of the module will get, as the output above shows,
  and a `go.work` in a parent directory of someone's checkout can silently
  apply to it. Add `go.work` and `go.work.sum` to `.gitignore`, run CI with
  `GOWORK=off` to be explicit, and treat workspaces as a local editing
  convenience. The Go documentation allows one exception: modules that are
  only ever developed together and never consumed separately.
]

=== internal is about import paths

Go imposes very little layout, but the compiler enforces one rule beyond
"a directory is a package".

#goconcept(title: [The `internal` directory])[
  A package whose import path contains an element named `internal` can only
  be imported by code rooted at the parent of that `internal` directory.
  `github.com/acme/tool/internal/engine` is importable from anything under
  `github.com/acme/tool/` and from nothing else. It is how a Go library says
  "this is not part of my API": you can rename, delete or rewrite an
  internal package in any release without breaking anyone, because nobody
  outside can depend on it. Unexported identifiers (lowercase names) do the
  same within a package; `internal` does it for whole packages. There is no
  Java-style package-private modifier or Python underscore convention to
  remember; the compiler checks it.
]

The rule is defined on import paths, not module boundaries, and that has a
consequence for nested modules. This program imports `internal/sweep` from
the root module:

#src("examples/ch01/internaldemo/main.go.txt", lang: "go")

Still in `projects/watchtower`, run `mkdir -p hack/internaldemo` and save
the program there as `main.go`. In the workspace it builds, because the
operator's import path starts with `github.com/rahulbalajee/platform-go/`,
the parent of `internal`. Without the workspace, it fails earlier:
`watchtower` does not require the root module at all.

#session(
  ("go build -o /dev/null ./hack/internaldemo && echo ok", "ch01/internal-ws.txt"),
  ("GOWORK=off go build -o /dev/null ./hack/internaldemo", "ch01/internal-off.txt"),
  ("rm -rf hack/internaldemo", none),
)

Copied into an unrelated module, `example.com/ext`, in a workspace with the
same clone, the compiler refuses:

#session(
  ("mkdir \"$LAB/ext\" && cd \"$LAB/ext\"", none),
  ("go mod init example.com/ext", "ch01/l6-ext-init.txt"),
  ("go work init . ../platform-go", "ch01/l6-ext-work.txt"),
)

Save the same program as `main.go` here, and build:

#output("ch01/internal-ext.txt", cmd: "go build -o /dev/null .", size: 6.4pt)

So a nested module whose path sits under the repository's path _may_ import
the root module's internal packages. Doing so couples their release cycles,
because the root module's internals can change in any commit. If two modules
need to share code, put it in `pkg/` and version it. Now remove both
workspaces:

#session(
  ("rm -f go.work go.work.sum", none),
  ("cd \"$LAB/platform-go\" && rm -f go.work go.work.sum", none),
)

=== Repository layout: one repo, several modules <sec-tc-layout>

Everything else about layout is convention. This repository follows the
conventions most large Go codebases have settled on:

#table(
  columns: (auto, 1fr),
  table.header([Directory], [What lives there]),
  [`cmd/<name>/`], [One directory per binary. `main` packages stay tiny: flag parsing, wiring, and a call into a `run` function that tests can call directly (Lab 7's `stamp`, Chapter 4's `sweep`).],
  [`internal/`], [Code private to this module: `internal/sweep` is `sweep`'s engine. The compiler stops other modules from importing it, so it can change freely.],
  [`pkg/<name>/`], [Libraries meant to be imported by other modules: `conc`, `retry`, `lifecycle`, and this chapter's `buildinfo`. The `pkg/` prefix is a convention, not a rule; it tells readers "public API, keep it stable".],
  [`examples/chNN/`], [Focused programs for one chapter. Heavy dependencies go in nested modules here, such as the tools module `examples/ch01/tools`.],
  [`projects/<name>/`], [The large projects, each its own module: `watchtower` today, `forge`, `ship`, `sentinel` and `oncall` later.],
  [`workbook/`, `solutions/`], [The build steps and exercise solutions of every chapter, each a module of its own.],
  [`book/`], [This book. No Go code, so it costs the `go` command nothing.],
)

==== Why watchtower is its own module

A single module for the whole repository is simpler: one `go.mod`, one
version, atomic changes. The operator gets its own module anyway, for three
reasons that apply to any large project in a shared repository.

*Dependency weight.* Count the build lists, now that the workspace is gone:

#session(
  ("go list -m all | wc -l", "ch01/mod-count-root.txt"),
  ("cd projects/watchtower && go list -m all | wc -l", "ch01/mod-count-wt.txt"),
)

The root module, which holds `sweep`, `plat` and the shared libraries, needs
96. The operator needs 183, most of them Kubernetes and its transitive
dependencies. In one module, a developer working on `sweep` would download
them, every `go.mod` change would involve them, and MVS would apply
Kubernetes' requirements to the CLI's build. Worse, Kubernetes libraries move
in lockstep (`k8s.io/api`, `apimachinery` and `client-go` at matching minor
versions), so a CLI dependency that drags `x/net` forward can force an
operator upgrade nobody planned.

The root module weighs every dependency this way. Chapter 9 needs one small
package from `client-go` and copies it, because requiring `client-go` would
add 37 modules for about 1,300 lines of code. Chapter 10 requires gRPC, CEL
and a WebAssembly runtime, 44 modules between them, because there the
dependency is the feature.

*Release cadence.* Each module is versioned separately. Tags for a nested
module carry its directory as a prefix, so a `watchtower` release would be
tagged `projects/watchtower/v0.3.0` and a root module release `v0.5.0`, and
neither forces a release of the other.

*CI isolation.* The operator's jobs need `envtest` binaries and a kind
cluster; the root module's job needs neither. Separate modules give separate,
cacheable jobs, which is how `.github/workflows/ci.yml` is split
(Lab 10).

Multi-module repositories have costs. A change that spans modules needs a
workspace locally and two steps upstream: release the library, then bump the
consumer. Every tool must loop over modules (`go test ./...` at the root does
_not_ descend into nested modules). The Kubernetes project lives with this at
the largest scale: its main repository holds the libraries under `staging/`,
and a publishing bot exports them as the separate `k8s.io/api`,
`k8s.io/client-go` and other repositories that the rest of the world imports.

#checkpoint(step: 6, of: 10, title: [Workspaces and repository layout])[
  The clone is a single main module again, with nothing left over:
  #session(
    ("go list -m", "ch01/l6-cp-list.txt"),
    ("git status --short | wc -l", "ch01/l6-cp-status.txt"),
  )
  #troubleshoot(
    ([#ts("l6-modmod.txt")], [`GOFLAGS=-mod=mod` (common in CI scripts) and a `go.work` file, possibly one in a parent directory you forgot.], [Remove the flag, or run with `GOWORK=off`. Check `go env GOWORK`.]),
    ([#ts("internal-ext.txt")], [An import of another module's `internal` package from outside its tree.], [Use a `pkg/` package, or copy the code. See "internal is about import paths".]),
    ([#ts("internal-off.txt")], [Outside the workspace, the module does not require the module that provides the package.], [Use the workspace for local work; `go get` the module (and release it) for real.]),
    ([#ts("l6-nodir.txt")], [A typo in a `go work use` or `go work init` path.], [Paths are directories relative to `go.work`.]),
  )
]

#step(7, 10, "Lab 7: Release builds and what they record", label: <sec-tc-build>)

A release build answers the Friday question in advance. Here is the one this
repository uses for Linux, run in your clean clone:

#session(
  ("cd \"$LAB/platform-go\"", none),
  ("CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \\\n  -ldflags=\"-s -w\" -o \"$LAB/sweep-linux-amd64\" ./cmd/sweep", "ch01/build-release.txt"),
  ("go version -m \"$LAB/sweep-linux-amd64\"", "ch01/build-vm.txt"),
)

`go version -m` reads the build information embedded in the binary: the
toolchain, the main package, the main module's version, every dependency
module with its `go.sum` hash, the build settings, and the commit. No access
to the source repository is needed, so this works on a binary pulled out of a
container image years later. Since Go 1.25, `go version -m -json` prints the
same data as JSON for inventory tooling. Each flag earns its place.

*`CGO_ENABLED=0`* produces the static binary from @sec-tc-why. The `net` and
`os/user` packages fall back to pure Go implementations, including a pure Go
DNS resolver that reads `/etc/resolv.conf` itself. Cross-compiling disables
cgo by default anyway; setting it explicitly makes native and cross builds
identical.

*`-trimpath`* removes the builder's file system paths from the binary, so
stack traces read `github.com/rahulbalajee/platform-go/internal/sweep/runner.go`
instead of `/home/runner/work/...`. That keeps usernames and directory layouts
out of shipped artifacts, and it is required for reproducible builds, as the
experiment below shows. It also changes what is recorded: with `-trimpath`,
the `go` command leaves `-ldflags` and the C compiler flags (`CGO_CFLAGS`,
`CGO_LDFLAGS` and their relatives) out of the build settings, because they
might contain paths. `CGO_ENABLED` is still recorded, but the
`-ldflags="-s -w"` above is missing from the output for that reason.

*`-ldflags="-s -w"`* tells the linker to drop the symbol table (`-s`) and the
DWARF debugging information (`-w`). Panics still print function names and
line numbers, because the runtime uses its own tables for that, which `-s`
does not remove. What you lose is the ability to attach a debugger such as
Delve to the binary, and symbol names in some profiling tools. For CLIs and
operators, the trade is usually worth it:

#let mib(b) = str(calc.round(int(b) / 1048576, digits: 1)) + " MiB"
#let matrix = csv("/book/output/ch01/build-matrix.csv").slice(1)
#table(
  columns: (1fr, auto, auto, auto),
  align: (left, right, right, right),
  table.header([Target (`sweep`, `CGO_ENABLED=0 -trimpath`)], [Default], [`-s -w`], [Saved]),
  ..matrix.map(r => (
    raw(r.at(0)), [#mib(r.at(1))], [#mib(r.at(2))],
    [#str(calc.round(100 * (1 - int(r.at(2)) / int(r.at(1))))) %],
  )).flatten(),
)

About a third of each binary is symbol tables and debug information. Built
from the same commit, the four platforms differ by less than a megabyte.

=== Microarchitecture levels

The last row of the table builds for `GOAMD64=v3`. Go compiles amd64 code for
the 2003-era baseline instruction set (`v1`) by default, so binaries run on
any x86-64 machine. `v2`, `v3` and `v4` allow progressively newer
instructions: `v3` corresponds to Haswell-era CPUs with AVX2, BMI and FMA, and
since Go 1.25 the compiler emits fused multiply-add instructions at `v3` and
above. On arm64, `GOARM64` selects `v8.0` (the default) through `v9.5`,
optionally with `,lse` or `,crypto` extensions. A binary built for a level
the CPU lacks exits at startup with a message saying so, rather than crashing
on an illegal instruction later.

For I/O-bound platform tools, the gain is negligible: `sweep` shrinks by
about 15 KB and its speed is set by the network. The FMA change also means
floating-point results can differ in the last bits between `v1` and `v3`
builds, which matters if a test compares floats exactly. For CPU-heavy components
(compression in a log shipper, the time-series engine in Chapter 26) measure
before and after. If your fleet is uniform and modern, raising the level is
cheap; if anyone runs your CLI on an old CI runner, keep the default.

=== Reproducible builds

A build is reproducible if the same source and toolchain produce the same
bytes regardless of who builds it, where, or when. That property lets a
third party verify that a published binary came from the published source,
and lets you rebuild an old release and get exactly what you shipped. Clone
the repository twice more, into two different directories:

#code(file: "terminal")[```sh
git clone https://github.com/rahulbalajee/platform-go "$LAB/a"
git clone https://github.com/rahulbalajee/platform-go "$LAB/b"
```]

Then build the same commit in each, first as usual, then with `-trimpath`:

#session(
  ("cd \"$LAB/a\" && GOOS=linux go build -o ../a.bin ./cmd/sweep", none),
  ("cd \"$LAB/b\" && GOOS=linux go build -o ../b.bin ./cmd/sweep", none),
  ("shasum -a 256 ../a.bin ../b.bin", "ch01/repro-plain-sum.txt"),
  ("cd \"$LAB/a\" && GOOS=linux go build -trimpath -o ../a.bin ./cmd/sweep", none),
  ("cd \"$LAB/b\" && GOOS=linux go build -trimpath -o ../b.bin ./cmd/sweep", none),
  ("shasum -a 256 ../a.bin ../b.bin", "ch01/repro-trim-sum.txt"),
)

Without `-trimpath`, the directory names end up in the binaries and the
hashes differ. With it, the builds are bit-for-bit identical. The Go
toolchain avoids the usual sources of nondeterminism (timestamps, map
iteration order, parallel build order) by design, and since Go 1.21 the
toolchain releases themselves are reproducible. What remains is up to you:
the same toolchain (the `toolchain` line), the same module versions (`go.sum`
and MVS), the same flags and environment (`GOOS`, `GOARCH`, `GOAMD64`,
`CGO_ENABLED`), and a clean checkout, since a modified tree changes the
`vcs.modified` setting and the stamped version, as the next part of this lab
shows. Cgo brings in the C toolchain and its own nondeterminism, which is
one more reason to disable it. Chapter 11 builds on this with GoReleaser,
SBOMs, signatures and SLSA provenance.

=== stamp, part one: what the toolchain recorded

`go version -m` reads build information from the outside. A program can read
its own, which is how a `--version` flag can report the exact commit without
anyone typing it in. In the rest of this lab you start `stamp`, a command
whose first version prints everything the toolchain recorded about its own
build. Labs 8 and 9 turn it into the `buildinfo` package that every tool in
this book uses. `stamp` needs a Git repository of its own, because the
toolchain reads the commit from it:

#session(
  ("mkdir \"$LAB/stamp\" && cd \"$LAB/stamp\"", none),
  ("git init -q", none),
  ("go mod init stamp", "ch01/l7-init.txt"),
  ("go get go@1.27.0 toolchain@go1.27.3", "ch01/l7-goget.txt"),
)

The module path is plain `stamp`, because this is a program, not a library
anyone will import from another repository, and packages inside it are
imported as `stamp/...`. The command lives in `cmd/stamp`, following the
layout table in Lab 6. Create `cmd/stamp/main.go`:

#src("workbook/ch01/step2/cmd/stamp/main.go", region: "head")

#goconcept(title: [A tiny `main` and a testable `run`])[
  `main` takes no arguments and returns nothing; a program reads
  `os.Args`, writes to `os.Stdout` and ends with `os.Exit`. Code written that
  way can only be tested by building and running the binary. So `main` does
  one thing: it calls `run` with the arguments, the output streams and
  nothing else, and exits with the status `run` returns. `run` takes
  `io.Writer`s (Chapter 0), so a test can pass a `bytes.Buffer` and read
  what was printed, and it returns an `int` instead of calling `os.Exit`, so
  the test can check the status. Every command in this book has this shape,
  starting with Chapter 4's `sweep`.
]

`run` parses the flags. There are none yet, but parsing still matters: an
unknown flag must be a usage error with exit status 2, not something that is
silently ignored.

#src("workbook/ch01/step2/cmd/stamp/main.go", region: "run")

`flag.NewFlagSet` with `ContinueOnError` makes `Parse` return an error
instead of exiting the process, which is what lets a test call `run`; Chapter
0 used the global `flag` functions, which suit only `main`. Then the function
that does the work:

#src("workbook/ch01/step2/cmd/stamp/main.go", region: "settings")

#goconcept(title: [`runtime/debug.ReadBuildInfo`])[
  `debug.ReadBuildInfo()` returns a `*debug.BuildInfo` describing the
  running binary, and `false` if it has none (binaries built without module
  support). The fields are what `go version -m` prints: `GoVersion`, `Path`
  (the main package), `Main` (the main module's path and version), `Deps`
  (every other module, with versions and checksums) and `Settings`, a list
  of key-value pairs such as `GOOS`, `-trimpath` and `vcs.revision`. The
  package `debug/buildinfo` reads the same structure from a binary _file_,
  which is how inventory tools scan an artifact store (Exercise 1.7).
]

The test drives `run` the way `main` would. Create `cmd/stamp/main_test.go`:

#src("workbook/ch01/step2/cmd/stamp/main_test.go", region: "imports")
#src("workbook/ch01/step2/cmd/stamp/main_test.go", region: "settings")

Run the tests, then the program with `go run`:

#session(
  ("go vet ./... && go test ./...", "ch01/l7-test.txt"),
  ("go run ./cmd/stamp", "ch01/l7-run.txt"),
)

`go run` recorded the platform and the cgo settings, but the main module's
version is `(devel)` and there is nothing about Git. In the `go` command's
source, only `go build`, `go install` and `go list` load version control
information by default; `go run` and `go test` skip it to stay fast
(`-buildvcs=true` forces it). Commit, and build a real binary:

#session(
  ("git add . && git commit -q -m \"stamp: print build settings\"", none),
  ("go build -o stamp ./cmd/stamp && ./stamp", "ch01/l7-build.txt"),
)

Since Go 1.24, `go build` inside a Git checkout sets the main module's
version from version control: a pseudo-version, because nothing is tagged
yet, built from the commit time and hash. `vcs.revision`, `vcs.time` and
`vcs.modified` record the same facts separately. Now build again, without
changing anything:

#output("ch01/l7-dirty.txt", cmd: "go build -o stamp ./cmd/stamp && ./stamp | grep -E '^(main|vcs)'")

The version gained `+dirty` and `vcs.modified` is `true`, although no source
file changed. Ask Git why:

#output("ch01/l7-status.txt", cmd: "git status --short")

The binary from the first build is an untracked file, and the `go` command
counts _anything_ `git status` reports, untracked files included, as a
modification. A CI job that builds into its checkout, or a code generator
that leaves a temporary file behind, ships every binary as `+dirty`. Ignore
build outputs, commit, and the stamp is clean again. Then tag the commit:

#session(
  ("echo /stamp > .gitignore", none),
  ("git add .gitignore && git commit -q -m \"Ignore the binary\"", none),
  ("go build -o stamp ./cmd/stamp && ./stamp | grep -E '^(main|vcs)'", "ch01/l7-clean.txt"),
  ("git tag v0.1.0", none),
  ("go build -o stamp ./cmd/stamp && ./stamp | grep -E '^(main|vcs)'", "ch01/l7-tag.txt"),
)

On a tagged commit the version is the tag. Tagging changed no file and made
no commit, so the revision and time are the same as in the build before it;
only the version moved. The tag has to be on the commit itself: the next
commit gets a pseudo-version again, built on the tag, as Lab 8 shows. A
binary that says `+dirty` should never reach production, and a release
pipeline can refuse to publish one (Exercise 1.3 writes that check).

#checkpoint(step: 7, of: 10, title: [Release builds and what they record])[
  `$LAB/stamp` is a Git repository with two commits, a tag, and these Go
  files:
  #output("ch01/l7-tree.txt", cmd: "find . -name '*.go' | sort")
  Built on the tagged commit, `stamp` reports the tag and a clean tree, as
  in the last command above. `$LAB/sweep-linux-amd64` is the Linux release
  build of `sweep`, which Lab 10 scans.
  #troubleshoot(
    ([#ts("l7-dirty.txt")], [An untracked file (often the binary itself) or an uncommitted change in the checkout.], [`.gitignore` build outputs; commit; build from a clean checkout in CI.]),
    ([#ts("repro-plain-sum.txt")], [The same commit built in two directories without `-trimpath`.], [Add `-trimpath`. See "Reproducible builds".]),
    ([#ts("l7-exec.txt")], [A binary for another platform (`GOOS=linux`) run on this machine.], [Run it on Linux or in a container; build with your own `GOOS` to run locally.]),
    ([#ts("l7-cgo.txt")], [`CGO_ENABLED=1` while cross-compiling: the host C compiler cannot build for another platform.], [`CGO_ENABLED=0`, or a C cross-compiler.]),
    ([#ts("l7-flag.txt")], [`stamp` has no `-version` flag yet; unknown flags are usage errors.], [Lab 8 adds it.]),
  )
]

#step(8, 10, "Lab 8: A buildinfo package", label: <sec-tc-buildinfo>)

Every tool in this book needs to say what it is: a `--version` flag for
humans, a JSON form for scripts and support bundles, a `User-Agent` for the
APIs it calls, and labels for a `build_info` metric. The raw material is what
Lab 7 printed, but nobody wants to parse `vcs.time` in forty commands. This
lab writes a package that turns the toolchain's stamp into one plain value,
and gives `stamp` a `-version` flag that prints it. Lab 9 adds the second
source of information, the release pipeline.

Create `buildinfo/buildinfo.go` in `$LAB/stamp`. The package documentation
says where the values come from:

#src("workbook/ch01/step3/buildinfo/buildinfo.go", region: "head")

The result is plain data, a struct any caller can copy, compare and print:

#src("workbook/ch01/step3/buildinfo/buildinfo.go", region: "info")

`Devel` is exported, so callers and tests can compare against it instead of
spelling the string. The toolchain's own word for an unknown version is
`(devel)`, with parentheses, and the package normalises it. Next, the
function every caller uses:

#src("workbook/ch01/step3/buildinfo/buildinfo.go", region: "get")

#goconcept(title: [`sync.OnceValue`])[
  `sync.OnceValue(f)` (Go 1.21) returns a function that calls `f` the first
  time it is called, from whichever goroutine gets there first, and returns
  the same result on every call after that. It replaces the older pattern of
  a `sync.Once` plus a package variable, and it is safe for concurrent use
  without any locking in the caller. The build information of a running
  binary never changes, so computing it once is right; `Get` is cheap enough
  to call from every HTTP request that needs a `User-Agent`. `OnceValues`
  does the same for functions that return a value and an error.
]

The work happens in `from`, which takes the toolchain's data as an argument
instead of reading it, so tests can feed it any kind of build:

#src("workbook/ch01/step3/buildinfo/buildinfo.go", region: "from")

#goconcept(title: [Unexported names, and tests in the same package])[
  A lowercase identifier (`from`, `current`) is visible only inside its own
  package; an uppercase one (`Get`, `Info`, `Devel`) is exported (Chapter 0).
  `from` stays unexported because its signature is a testing seam, not an
  API: callers should not care that a `*debug.BuildInfo` is involved. A test
  file that declares `package buildinfo` is part of the package, so it can
  call `from` directly; a test file declaring `package buildinfo_test` would
  see only the exported API, like any other importer. Use the first for unit
  tests of internals and the second for tests of the public contract.
]

`path.Base` takes the last element of the main package's import path, so a
binary built from `.../cmd/sweep` calls itself `sweep`; the `path` package,
not `path/filepath`, because import paths always use forward slashes. A
malformed `vcs.time` leaves `Time` at its zero value rather than failing,
because a `--version` flag must never stop a program from starting.
Finally, the human form, which avoids repeating what a pseudo-version
already says:

#src("workbook/ch01/step3/buildinfo/buildinfo.go", region: "format")

Because `Info` has a `String` method, it satisfies `fmt.Stringer` (Lab 5),
and `fmt.Println(info)` prints this line. `strings.Builder` collects the
pieces without a new string allocation per append.

=== The -version flag

In `cmd/stamp/main.go`, replace everything from the package documentation
through `main` with this; the import block gains the new package:

#src("workbook/ch01/step3/cmd/stamp/main.go", region: "head")

and replace `run`. `printSettings` stays as it was:

#src("workbook/ch01/step3/cmd/stamp/main.go", region: "run")

=== Tests

The unit tests describe each kind of build in the text format that
`go version -m` prints, and `debug.ParseBuildInfo` turns that text back into
a `*debug.BuildInfo`. They compare whole `Info` values with `go-cmp`, a
small library from Google that prints a readable diff when two values
differ. Create `buildinfo/buildinfo_test.go`, starting with the imports:

#src("workbook/ch01/step3/buildinfo/buildinfo_test.go", region: "imports")

The fixtures are three real kinds of build. One detail found while writing
them: `ParseBuildInfo` skips the `go` line, so the `parse` helper restores
`GoVersion` from the fixture.

#src("workbook/ch01/step3/buildinfo/buildinfo_test.go", region: "fixtures")

A table of builds and the `Info` each must produce, with a helper that runs
any such table, because Lab 9 adds a second one:

#src("workbook/ch01/step3/buildinfo/buildinfo_test.go", region: "from")
#src("workbook/ch01/step3/buildinfo/buildinfo_test.go", region: "toolchain")

#goconcept(title: [Comparing values in tests with `go-cmp`])[
  `==` works on structs only when every field is comparable, and when it
  fails it says nothing about _which_ field differed. `cmp.Diff(want, got)`
  from `github.com/google/go-cmp/cmp` returns an empty string when the two
  values are equal and a line-by-line diff otherwise, marked `-` for want and
  `+` for got. It compares `time.Time` values with their `Equal` method, which
  is the right notion of equality for times. The standard library's
  `reflect.DeepEqual` answers only yes or no. The diff output deliberately
  varies its whitespace, so never compare it against a saved string.
]

The `String` cases are a table of small changes to one release build:

#src("workbook/ch01/step3/buildinfo/buildinfo_test.go", region: "string")

and one test checks the real build information of the test binary itself,
which `go test` builds without VCS stamping:

#src("workbook/ch01/step3/buildinfo/buildinfo_test.go", region: "get")

Add the version test to `cmd/stamp/main_test.go`, after the existing tests:

#src("workbook/ch01/step3/cmd/stamp/main_test.go", region: "version")

The test file imports `go-cmp`, which the module doesn't require yet. Add it:

#session(
  ("go get github.com/google/go-cmp@v0.7.0", "ch01/l8-goget.txt"),
  ("go mod tidy", "ch01/l8-tidy.txt"),
)

`go get` records the requirement as `// indirect`; `go mod tidy` looks at
every import, test files included, and marks it as a direct one.

#checkpoint(step: 8, of: 10, title: [A buildinfo package])[
  #output("ch01/l8-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch01/l8-test.txt", cmd: "go vet ./... && go test ./...")
  Commit the package. The commit after the `v0.1.0` tag gets a
  pseudo-version based on the next patch release; tag it, and the version is
  the tag, with the revision and time in parentheses because the tag doesn't
  contain them:
  #session(
    ("git add . && git commit -q -m \"buildinfo: read the toolchain's stamp\"", none),
    ("go build -o stamp ./cmd/stamp && ./stamp -version", "ch01/l8-pseudo.txt"),
    ("git tag v0.2.0", none),
    ("go build -o stamp ./cmd/stamp && ./stamp -version", "ch01/l8-tagged.txt"),
    ("go run ./cmd/stamp -version", "ch01/l8-run.txt"),
  )
  An uncommitted change shows up in the version itself:
  #session(
    ("echo '// work in progress' >> cmd/stamp/main.go", none),
    ("go build -o stamp ./cmd/stamp && ./stamp -version", "ch01/l8-dirty.txt"),
    ("git checkout -q -- cmd/stamp/main.go", none),
  )
  #troubleshoot(
    ([#ts("l8-nocmp.txt")], [The test imports a module that `go.mod` does not require.], [Run the `go get` and `go mod tidy` steps above.]),
    ([#ts("l8-pointer.txt")], [`String` has a pointer receiver, `func (i *Info)`. `Get` returns a value, whose method set lacks `String`, so `fmt` printed the raw struct.], [Use a value receiver for `String`.]),
    ([#ts("l8-devel.txt")], [`from` copies `(devel)` from the toolchain instead of normalising it.], [Keep the `v != "(devel)"` check in `from`.]),
    ([#ts("l8-unexported.txt")], [Code outside the package calls the unexported `from`.], [Call `buildinfo.Get()`. See "Unexported names".]),
  )
]

#step(9, 10, "Lab 9: Release stamping with -X", label: <sec-tc-ldflags>)

The toolchain knows what Git told it. A release pipeline knows more: the tag
it is about to create, or the commit of a source tree that was copied into a
Docker build context without its `.git` directory. This lab lets the
pipeline pass those values to the linker, adds a JSON form for scripts and a
`User-Agent` for HTTP clients, and finishes `stamp`. @fig-tc-precedence
shows the rule the package follows for every field.

#fig(placement: auto, caption: [Where each `Info` field comes from. The first source that has a value wins.])[
  #diagram(
    spacing: (22pt, 12pt),
    dnode((0, 0), [linker `-X` value\ set by the release pipeline], kind: "dark"),
    dnode((1, 0), [toolchain stamp\ module version, `vcs.*` settings], kind: "accent"),
    dnode((2, 0), [documented default\ `devel`, zero time, no revision], kind: "muted"),
    dnode((1, 1), [`buildinfo.Info`\ `-version`, JSON, `User-Agent`, metrics], kind: "good"),
    dedge((0, 0), (1, 0), "-|>", label: [else]),
    dedge((1, 0), (2, 0), "-|>", label: [else]),
    dedge((0, 0), (1, 1), "-|>"),
    dedge((1, 0), (1, 1), "-|>"),
    dedge((2, 0), (1, 1), "-|>"),
  )
] <fig-tc-precedence>

=== Linker overrides

The linker flag `-X importpath.name=value` overwrites the initial value of a
package-level string variable when the binary is linked. Replace the package
documentation and imports at the top of `buildinfo.go`:

#src("workbook/ch01/step4/buildinfo/buildinfo.go", region: "head")

and add the variables after the imports:

#src("workbook/ch01/step4/buildinfo/buildinfo.go", region: "vars")

#goconcept(title: [Package-level variables and the linker])[
  A `var` outside any function is a package-level variable: it exists for
  the whole life of the program, and every function in the package can read
  it (Chapter 0). When its initial value is a constant string, the compiler
  stores that string in the binary as data, and `-X` tells the linker to
  store a different string there instead. That is why the variables must be
  `string`s with a constant initial value or none. A constant has no storage
  to overwrite, and a variable initialized by a function call gets its value
  when the program starts, after the linker is done, so `-X` has nothing to
  replace. The variables are unexported, so only the linker and this package
  can set them.
]

=== Struct tags and JSON

Replace the `Info` type and the `Devel` constant. The fields are the same;
each one gains a struct tag that fixes its JSON name, so other tools can
depend on the shape:

#src("workbook/ch01/step4/buildinfo/buildinfo.go", region: "info")

#goconcept(title: [Struct tags: `omitempty` and `omitzero`])[
  A struct tag is the string in backquotes after a field's type. Packages
  read it with reflection; `encoding/json` reads the `json` key: its first
  part is the field's name in JSON, and options follow after commas (Chapter
  0 introduced tags). `omitempty` leaves a field out when it is `false`, `0`,
  `""` or an empty slice or map, but a struct is never "empty", so a zero
  `time.Time` would still print as `"0001-01-01T00:00:00Z"`. `omitzero`
  leaves a field out when it is the zero value of its type, or when its
  `IsZero()` method returns true, which `time.Time` has. A tag is only a
  string to the compiler, so a typo in one compiles; `go vet` checks the
  syntax, as the troubleshooting table shows.
]

#newingo("1.24", title: [`omitzero`])[
  `encoding/json` gained `omitzero` in Go 1.24. Older toolchains ignore the
  unknown option and print the zero time; Exercise 1.2 asks what that means
  for the oldest `go` line this module can declare.
]

The variables reach `from` through a small struct, so tests can vary them
without touching the package variables. Replace the block from `var current`
through `Get` with:

#src("workbook/ch01/step4/buildinfo/buildinfo.go", region: "get")

Replace `from`. It takes the overrides as a third argument and applies them
last, so they win:

#src("workbook/ch01/step4/buildinfo/buildinfo.go", region: "from")

The time arrives as a string, and pipelines disagree about formats. Add this
after `from`:

#src("workbook/ch01/step4/buildinfo/buildinfo.go", region: "parsetime")

Unix seconds is the `SOURCE_DATE_EPOCH` convention from the
reproducible-builds project. Using the commit time instead of the wall clock
keeps the build reproducible: two builds of the same commit stamp the same
time. `ShortRevision` and `String` stay as they were. At the end of the file,
add the two outputs that Lab 8's `String` didn't cover. The first serves
humans and scripts:

#src("workbook/ch01/step4/buildinfo/buildinfo.go", region: "write")

`Write` returns an error for an unknown format instead of guessing, which
gives `stamp` an error to report. `json.Encoder` writes straight to `w`, and
`SetIndent` makes the output readable in a terminal. The second output is for
servers: a `User-Agent` string in the usual `product/version (comment)` form,
so access logs show which builds of a tool are calling:

#src("workbook/ch01/step4/buildinfo/buildinfo.go", region: "useragent")

In `cmd/stamp/main.go`, the package documentation gains a line; the import
block and `main` are unchanged:

#src("workbook/ch01/step4/cmd/stamp/main.go", region: "head")

Replace `run`, which gains `-json`:

#src("workbook/ch01/step4/cmd/stamp/main.go", region: "run")

=== Tests

In `buildinfo_test.go`, replace the import block:

#src("workbook/ch01/step4/buildinfo/buildinfo_test.go", region: "imports")

The table row gains the overrides, and the helper passes them on. Replace
`fromTest` and `runFromTests`:

#src("workbook/ch01/step4/buildinfo/buildinfo_test.go", region: "from")

`TestFrom` stays as it was: its rows leave `ov` empty. At the end of the
file, add the override cases and the time parser's table:

#src("workbook/ch01/step4/buildinfo/buildinfo_test.go", region: "overrides")

and after them the tests of the new outputs. `TestWrite` checks that the JSON
round-trips into an equal `Info`, and `TestJSONOmitsUnknownFields` is the
test that catches `omitempty` on the time field:

#src("workbook/ch01/step4/buildinfo/buildinfo_test.go", region: "write")

In `cmd/stamp/main_test.go`, replace the import block:

#src("workbook/ch01/step4/cmd/stamp/main_test.go", region: "imports")

and add the JSON test at the end:

#src("workbook/ch01/step4/cmd/stamp/main_test.go", region: "json")

#warning(title: [`-X` fails silently])[
  If the path or variable name in `-X` is misspelled, or the variable is a
  constant, or it is initialised by a function call, the linker ignores the
  flag without a word, and the release ships as `devel`. Unit tests cannot
  catch this, because they never run the linker with your pipeline's flags.
]

The only defence is a test that builds the real binary with the real flags
and checks its output. Add it at the end of `main_test.go`:

#src("workbook/ch01/step4/cmd/stamp/main_test.go", region: "ldflags")

#goconcept(title: [Running commands from tests])[
  `exec.CommandContext(ctx, name, args...)` prepares a command; `Output`
  runs it and returns its standard output, and `CombinedOutput` returns
  standard output and error together, which is what you want to print when
  a build fails. `t.Context()` (Go 1.24) is cancelled when the test ends, so
  a hung command is killed. `t.TempDir()` returns a directory that is
  removed after the test. `testing.Short()` is true under `go test -short`;
  tests that build binaries or touch the network skip themselves then, so a
  quick local run stays quick. A test like this one is slower than a unit
  test, about a second, and it is the only one in this package that proves
  the `-X` paths are right.
]

=== A release build

Commit the code, then build the way a pipeline would. `-buildvcs=false`
stands in for a build context without `.git`: the toolchain records no
version and no commit, and everything comes from the linker.

#checkpoint(step: 9, of: 10, title: [Release stamping with -X])[
  #output("ch01/l9-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch01/l9-test.txt", cmd: "go vet ./... && go test ./...")
  Commit, and a plain build reports what the toolchain recorded, now as
  JSON:
  #session(
    ("git add . && git commit -q -m \"buildinfo: linker overrides, JSON and User-Agent\"", none),
    ("go build -o stamp ./cmd/stamp && ./stamp -version -json", "ch01/l9-build.txt"),
  )
  The release build:
  #session(
    ("export PKG=stamp/buildinfo", none),
    ("go build -trimpath -buildvcs=false -o stamp -ldflags \"-s -w \\\n  -X $PKG.version=v1.4.0 \\\n  -X $PKG.revision=$(git rev-parse HEAD) \\\n  -X $PKG.buildTime=$(git log -1 --format=%ct)\" \\\n  ./cmd/stamp", "ch01/bi-release.txt"),
  )
  It prints nothing on success. The binary now says:
  #session(
    ("./stamp -version", "ch01/bi-release-version.txt"),
    ("./stamp -version -json", "ch01/bi-json.txt"),
  )
  The tool reports `v1.4.0` with the right revision and commit time, all
  from the linker. `go version -m` shows what the toolchain itself recorded:
  no version and no VCS settings, because of `-buildvcs=false`, and no
  `-ldflags`, because `-trimpath` leaves them out:
  #output("ch01/bi-release-vm.txt", cmd: "go version -m ./stamp")
  #troubleshoot(
    ([#ts("l9-typo.txt")], [A misspelled `-X` path or name (here `Version` for `version`). The linker ignores it silently.], [Copy the path from `go list ./buildinfo`; keep the ldflags test passing.]),
    ([#ts("l9-func.txt")], [The variable is initialised by a function call (here `os.Getenv`), so `-X` cannot replace it.], [Declare it without an initializer. See "Package-level variables and the linker".]),
    ([#ts("l9-omitempty.txt")], [`omitempty` on the `time.Time` field: a zero time is not "empty".], [Use `omitzero`.]),
    ([#ts("l9-tag.txt")], [A struct tag without quotes around its value.], [`json:"goVersion"`.]),
    ([#ts("l9-modpath.txt")], [Your module path is not `stamp`, so the test's `pkg` constant names a package that doesn't exist.], [Set `pkg` to your module path plus `/buildinfo`.]),
  )
]

=== Adopting it

These four files are the repository's `pkg/buildinfo` and
`examples/ch01/stamp`, with `stamp/buildinfo` imported as
`github.com/rahulbalajee/platform-go/pkg/buildinfo`; a check in CI keeps them
identical. `sweep` from Chapter 4 still carries its own
`var version = "dev"` and prints `sweep dev`. Moving it to `buildinfo` is a
few lines: call `buildinfo.Get()`, set `Name` to `"sweep"`, call
`info.Write(stdout, format)` for `-version`, and set `info.UserAgent()` on the HTTP prober's
requests so the services it checks can see which version of the checker is
calling (Exercise 1.4 builds the HTTP half). The later projects use the
package the same way: a `version` command with both output formats in the
CLIs of Part II, `-X` flags passed by the release tooling of Chapter 11, and
a `build_info` gauge with the value 1 and the version, revision and Go
version as labels in Chapter 17 (Exercise 1.5), the convention Prometheus
itself follows with `prometheus_build_info`.

#step(10, 10, "Lab 10: Quality gates", label: <sec-tc-gates>)

Version stamps tell you what you shipped. Quality gates decide what is
allowed to ship. This repository runs three, and in this lab you run them on
your own code and on the clone.

=== go vet

`go vet` runs the analyzers that ship with the toolchain: `printf` format
mismatches, copied locks, unreachable code, struct tags (Lab 9's
troubleshooting table), misuse of `sync.WaitGroup` and many more. They have
almost no false positives, so CI runs them all, and `go test` runs a
high-confidence subset automatically before every test run. The set grows
with each release: Go 1.24 added the `tests` analyzer for malformed test and
example declarations, Go 1.25 added `hostport` (addresses built with
`fmt.Sprintf("%s:%d")`, which break on IPv6), and Go 1.27 makes `go test`
run `stdversion`, which flags standard library symbols newer than the
module's `go` line, and teaches `printf` to flag `%w` applied to a `*E` whose
type `E` already implements `error`.

=== golangci-lint

`golangci-lint` runs many analyzers in one process with a shared parse and
type-check. Install the version this repository pins, the way its CI does
(the binary lands in `~/go/bin`):

#code(file: "terminal")[```sh
go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0
```]

Every module in the repository uses the root configuration:

#src(".golangci.yml")

The header comment states the policy: linters that find real bugs in tooling
code, not linters that argue about taste. `default: standard` enables
`errcheck`, `govet`, `ineffassign`, `staticcheck` and `unused`. The additions
each target a failure that has hurt production tools: leaked HTTP bodies
(`bodyclose`), requests without a context (`noctx`), `==` on wrapped errors
(`errorlint`), returning `nil` after an error (`nilerr`), insecure file
permissions and TLS settings (`gosec`), plus `modernize`, which runs the same
analyzers as the Go 1.26 `go fix` modernizers. The exclusions keep test files
free of production-only rules, and `goimports` with `local-prefixes` groups
this repository's imports separately. Copy it into `stamp` and run both
gates:

#session(
  ("cd \"$LAB/stamp\"", none),
  ("cp \"$LAB/platform-go/.golangci.yml\" .", none),
  ("go vet ./...", "ch01/gates-vet.txt"),
  ("golangci-lint run ./...", "ch01/gates-lint.txt"),
)

Silence from `go vet` is success. To see what the configuration catches, run
it on a deliberately broken function that looks like code from any internal
tool. Make a scratch module and save this as `fetch.go` in it:

#session(
  ("mkdir \"$LAB/lintdemo\" && cd \"$LAB/lintdemo\"", none),
  ("go mod init lintdemo", "ch01/l10-lint-init.txt"),
)

#src("examples/ch01/lintdemo/fetch.go.txt", lang: "go")

#session(
  ("cp \"$LAB/platform-go/.golangci.yml\" .", none),
  ("golangci-lint run ./... | tail -7", "ch01/lint-demo.txt"),
)

The full report is wide; here it is as a table, built from the same run's
JSON output:

#let lint = json("/book/output/ch01/lint-demo.json").Issues.sorted(key: i => i.Pos.Line)
#table(
  columns: (auto, 1fr),
  table.header([Flagged line], [Finding]),
  ..lint.map(i => (
    text(size: 8.6pt, raw(i.SourceLines.first().trim())),
    [#strong(raw(i.FromLinter)): #i.Text],
  )).flatten(),
)

Each finding is a production bug. Without a context the request can hang
until the client's timeout, which `http.DefaultClient` doesn't have. The
unclosed body leaks a connection per call. `%v` cuts the error chain, so
callers can't test for `context.DeadlineExceeded`. Comparing with `==`
misses wrapped errors, and the `nilerr` finding is a truncated download
reported as success.

=== govulncheck

Most dependency scanners match module versions against advisories: if your
`go.sum` mentions a vulnerable version, you get an alert. `govulncheck` does
better. The Go vulnerability database records the affected _functions_ for
each advisory, and `govulncheck` builds a call graph of your program to
report only vulnerabilities your code can reach. It is an independent tool,
so it goes in your tools module from Lab 5, next to `stringer`:

#session(
  ("cd \"$LAB/tools\"", none),
  ("go get -tool golang.org/x/vuln/cmd/govulncheck@v1.9.0", "ch01/l10-get.txt"),
  ("go mod tidy", "ch01/l10-tidy.txt"),
  ("go tool | grep -F '('", "ch01/l10-tools.txt"),
)

Your tools module is now byte-for-byte the repository's
`examples/ch01/tools` (apart from the module path), which is what CI runs.
Scan `stamp` with it, then the clone's root module:

#session(
  ("cd \"$LAB/stamp\"", none),
  ("go tool -modfile=\"$LAB/tools/go.mod\" govulncheck ./...", "ch01/l10-vuln.txt"),
  ("cd \"$LAB/platform-go\"", none),
  ("go tool -modfile=\"$LAB/tools/go.mod\" govulncheck ./...", "ch01/vuln-root.txt"),
)

It also scans binaries, using the build information from Lab 7. This is the
Friday question answered from an artifact, with no source checkout:

#output("ch01/vuln-bin.txt", cmd: "go tool -modfile=\"$LAB/tools/go.mod\" govulncheck -mode=binary -show verbose \\\n  \"$LAB/sweep-linux-amd64\"")

The operator is a different story. Here is the same scan of
`projects/watchtower` at commit `b0977b0`, the last one before the report
below was acted on, filtered to the summary lines. A `git worktree` checks
out that commit next to the clone without disturbing it:

#session(
  ("git worktree add -q --detach \"$LAB/before\" b0977b0", none),
  ("go tool -modfile=\"$LAB/tools/go.mod\" govulncheck \\\n  -C \"$LAB/before/projects/watchtower\" ./... | grep -E '^(Vuln|    Found|Your)'", "ch01/vuln-wt.txt"),
  ("git worktree remove --force \"$LAB/before\"", none),
)

Reachable vulnerabilities in `x/net` (HTTP/2 flaws of the Friday
kind), in OpenTelemetry and in gRPC, all arriving through transitive
dependencies. The full report also names a fixed release for each one. This
is the normal state of a large module graph, not a sign of neglect, and it is
why `govulncheck` belongs in CI for every module and on a schedule against
the default branch: advisories arrive whether or not anyone pushes code. The
database also grows, so your run may list advisories published after this
one was captured.

The fix was four `go get` commands (`golang.org/x/net` to v0.60.0,
`google.golang.org/grpc` to v1.83.1, and the two OpenTelemetry modules to
v1.45.0), `go mod tidy`, and a green run of the envtest suite. The same scan
against the upgraded tree:

#output("ch01/vuln-wt-fixed.txt", cmd: "cd projects/watchtower && go tool -modfile=\"$LAB/tools/go.mod\" govulncheck ./...")

The advisories left over sit in packages watchtower imports, or modules it
requires, but in functions its code never calls. `govulncheck` mentions them
and exits 0. That reachability analysis is the difference between a scanner
teams keep in CI and one they mute: a dependency scanner that fails the build
for every vulnerable function anywhere in a 183-module graph gets switched off
within a month.

=== The CI contract

The Makefile is the contract between a developer's machine and CI:

#src("Makefile")

#output("ch01/make-n.txt", cmd: "make -n")

The workflow in `.github/workflows/ci.yml` has one job per kind of module
and one per gate:

#output("ch01/ci-jobs.txt", cmd: "sed -n '/^jobs:/,$p' .github/workflows/ci.yml | grep -E '^  [a-z0-9-]+:$'")

The job for the root module runs the same steps as the Makefile, with the
same pinned linter version:

#output("ch01/ci-go-job.txt", cmd: "sed -n '/^  go:/,/^$/p' .github/workflows/ci.yml")

`go-version-file: go.mod` installs the version the module asks for, so CI and
laptops agree through the mechanism of Lab 1. The linter version is pinned in
the `go` job and in every other job that lints. The first step after
`setup-go` is `go mod tidy -diff`, which fails if `go.mod` or `go.sum` is out
of date without modifying them. The other jobs repeat the pattern. The
`watchtower` job adds a check that generated code is up to date, the CI half
of Lab 5's `go generate` advice. The `examples` job runs the same steps in a
matrix over the nested modules, this chapter's tools module among them. The
`workbook` job builds, lints and race-tests every lab and build step of the
book, checks that every line of them is printed in the book, and checks that
`workbook/ch01/step4` still matches `pkg/buildinfo`. `vuln` runs your tools
module's `govulncheck` against both the root module and `watchtower`, on
every push and on a weekly schedule (the `cron` line at the top of the file),
so a new advisory fails the build even in a week when nobody pushes.
`watchtower-e2e` deploys the operator to a kind cluster, and `book` checks
listing widths and builds this PDF, which fails if a listing's source region
disappears.

#checkpoint(step: 10, of: 10, title: [Quality gates])[
  Your tools module pins both tools:
  #output("ch01/l10-tools.txt", cmd: "go tool | grep -F '('")
  and `stamp` passes all three gates:
  #session(
    ("go vet ./...", "ch01/gates-vet.txt"),
    ("golangci-lint run ./...", "ch01/gates-lint.txt"),
    ("go tool -modfile=\"$LAB/tools/go.mod\" govulncheck ./...", "ch01/l10-vuln.txt"),
  )
  #troubleshoot(
    ([#ts("l10-notool.txt")], [`go tool` looks in the current module's `tool` block, and `stamp` has none.], [`go tool -modfile="$LAB/tools/go.mod" govulncheck`.]),
    ([#ts("l10-printf.txt")], [A format string with more verbs than arguments.], [Pass the argument; vet names the call.]),
    ([#ts("l10-errcheck.txt")], [An error return ignored (here `Write`'s).], [Handle it. See "golangci-lint".]),
    ([#ts("l10-tidy-diff.txt")], [`go.mod` requires a module nothing imports (CI's first gate).], [`go mod tidy` and commit the result.]),
    ([#ts("vuln-wt.txt")], [A vulnerable function is reachable from your code.], [`go get` the fixed version from the report, `go mod tidy`, run the tests.]),
  )
]

== Dependency hygiene at 200 engineers <sec-tc-scale>

Everything so far works for one team. With 200 engineers, 1,000 services and
dozens of shared libraries, three more things matter.

*An internal module proxy.* Run a proxy such as Athens, JFrog Artifactory or
Sonatype Nexus, and point every developer and CI job at it:
`GOPROXY=https://goproxy.corp.example.com` with
`GONOSUMDB=corp.example.com`. The proxy serves public modules (caching them,
so builds keep working when GitHub or a module's author does not) and private
ones (with read access to internal repositories, so developers need no
GitHub tokens for builds). It is also the policy point: it can return 403 for
modules on a deny list or with unacceptable licences, and because of the
comma semantics in Lab 4, a 403 stops the download instead of falling
through to the internet. Keep the public checksum database on for public
modules; the proxy cannot forge them without being caught. And mirror
`golang.org/toolchain`, or toolchain switching breaks for everyone (Lab 1's
troubleshooting table shows how that looks).

*Updates as a flow, not an event.* MVS means nothing upgrades by itself, so
someone has to. Let a bot (Renovate, Dependabot) open grouped pull requests
weekly, bump the `toolchain` line the same way, and make CI with `-race`,
`govulncheck` and `go mod tidy -diff` the judge. Libraries owned by the
platform team should be upgraded in their consumers by the platform team,
across all repositories, with the same bot. A library that 300 services pin
at 40 different versions is how a one-line fix becomes a quarter-long
migration. `go list -m -u all` and `go mod why -m` answer the two questions
in every upgrade review: what is behind, and why is this even here. In Lab
2's universe:

#output("ch01/mvs-why.txt", cmd: "go mod why -m example.com/codec")

*Supply-chain risk.* `go.sum` and the checksum database guarantee that
everyone gets the same bytes. They say nothing about whether the bytes are
benign. Typosquatting is real in the Go ecosystem: in early 2025, researchers
at Socket reported `github.com/boltdb-go/bolt`, a backdoored lookalike of the
popular `github.com/boltdb/bolt` that had been published years earlier. The
author later pointed the repository's tag at clean code, but the module
mirror, which caches versions permanently by design, kept serving the
backdoored original to anyone who mistyped the import path. The defences
are organisational: review new dependencies (a new line in `go.mod` deserves
the same scrutiny as new code), prefer the standard library and a short list
of well-known modules, use the internal proxy to enforce that list, and scan
artifacts as well as source. Chapter 11 adds SBOMs, signatures and provenance
to releases, and Chapter 31 covers supply-chain security as part of a
platform's threat model.

#production(title: [What to measure])[
  Treat the dependency graph as something you operate. Track, per service:
  the Go toolchain version in production (from build info), the age of the
  oldest direct dependency, the number of reachable `govulncheck` findings,
  and the number of modules in the build list. Scrape the first and third
  straight from running binaries and artifact registries: the `build_info`
  metric and `govulncheck -mode=binary` exist for this. A dashboard
  that answers "which services still run go1.26 or `x/net` v0.59.0" turns
  the Friday question into a query.
]

#interview(title: [“How would you manage Go dependencies across a large organisation?”])[
  Start with the mechanics: MVS makes builds reproducible without lock files,
  `go.sum` plus the checksum database make them tamper-evident, and the
  toolchain line pins the compiler. Then the organisation: an internal
  `GOPROXY` for availability, private modules and policy (403 for denied
  modules, comma semantics so denials are final); `GOPRIVATE` or
  `GONOSUMDB` only for internal paths; automated grouped updates with CI as
  the gate; `govulncheck` in CI and against deployed binaries; stamped
  builds with `-trimpath` so artifacts can be traced to commits; and review
  of every new dependency. Close with a trade-off: vendoring buys
  self-containment at the cost of huge diffs, and most teams get the same
  guarantees from a proxy.
]

#takeaways(
  [The `go` line is a minimum requirement; the `toolchain` line picks the compiler. With `GOTOOLCHAIN=auto` the `go` command downloads and runs the version a module asks for, verified through the checksum database. Pin the latest patch release in applications.],
  [Minimal version selection uses the highest _required_ version of each module, never the newest available. Builds don't change until someone runs `go get`, and no lock file is needed.],
  [`retract` hides a bad version without breaking builds; `exclude` drops requirements and can silently downgrade; `replace` only works in the main module.],
  [`go.sum` and `sum.golang.org` guarantee everyone gets the same bytes. `GOPRIVATE` keeps private paths away from public services; the comma and pipe in `GOPROXY` decide whether a proxy can veto a download.],
  [Pin tools with the `tool` directive, but remember they join the module graph: keep independent tools in a separate module and run them with `go tool -modfile`.],
  [Workspaces are for local editing. They merge the build lists of their modules, so CI should run with `GOWORK=off` and `go.work` should not be committed.],
  [Ship with `CGO_ENABLED=0 -trimpath -ldflags="-s -w"` from a clean checkout, with build outputs ignored by Git. The binary then carries its toolchain, dependencies and commit, and `go version -m` and `govulncheck -mode=binary` can read them.],
  [`buildinfo` merges toolchain stamping with linker overrides. Test `-X` flags by building the real binary, because typos fail silently.],
)

#exercise-set(1,
  (
    tier: "warm-up",
    title: [A new phase],
    body: [
      Operators want to stop a rollout without rolling it back. In your
      tools module, add `PhaseAborted`, written `aborted`, as the last phase,
      so the numeric values of the others don't change. `ParsePhase`, JSON
      and `Phases()` must handle it, and the value after it must still be
      rejected when marshalled. Then explain why the compile-time freshness
      check did not catch a stale `phase_string.go` this time.
    ],
    hint: [Count the places in `phase.go` that name the last phase. One test you already have will need a change too.],
    tests: "workbook/ch01/exercises/ex1",
  ),
  (
    tier: "warm-up",
    title: [How old a Go can build stamp?],
    body: [
      A colleague wants to build `stamp` with the Go their distribution
      ships. In a copy of your module, lower the `go` line with
      `go mod edit -go=1.23.0` and run `go vet ./...` and `go test ./...`;
      then try `-go=1.20`. What stops each one, and what is the oldest `go`
      line the module can honestly declare? One of the reasons is invisible
      to every analyzer; which, and which test would catch it under an old
      toolchain?
    ],
    hint: [Look at what `go-cmp` requires (Lab 2's `go mod graph | grep ' go@'`), and at Lab 9's `newingo` box.],
  ),
  (
    tier: "warm-up",
    title: [Refuse to ship a dirty build],
    body: [
      Add `func (i Info) Releasable() error` to `buildinfo`. It returns `nil`
      for a clean build of a tagged commit (a pre-release tag such as
      `v1.5.0-rc.1` counts), and otherwise every reason it is not, joined:
      the exported sentinel errors `ErrNoVersion` (`devel` or empty),
      `ErrPseudoVersion` (any pseudo-version form), `ErrModified` (modified
      flag or `+dirty`) and `ErrNoRevision`, so callers can test each with
      `errors.Is`.
    ],
    hint: [`errors.Join` returns `nil` when given nothing. Lab 2's Go concept box lists the three pseudo-version forms; what do they all end with?],
    tests: "workbook/ch01/exercises/ex3",
  ),
  (
    tier: "core",
    title: [User-Agent on every request],
    body: [
      Add `func (i Info) Transport(base http.RoundTripper) http.RoundTripper`
      to `buildinfo`: a transport that sends requests
      through `base` (or `http.DefaultTransport` if `base` is `nil`) with
      `User-Agent` set to `i.UserAgent()`, unless the caller set one. A
      `RoundTripper` must not modify the request it is given, and the
      acceptance test checks that.
    ],
    hint: [`http.Request.Clone`. A function type with a `RoundTrip` method makes a handy fake.],
    tests: "workbook/ch01/exercises/ex4",
  ),
  (
    tier: "core",
    title: [A build_info metric],
    body: [
      Add `func (i Info) WriteMetric(w io.Writer) error`, which writes the
      Prometheus text format for a gauge named after the program,
      `<name>_build_info`, with the value 1 and the labels `goversion`,
      `platform`, `revision` and `version` in that order, plus its `# HELP`
      and `# TYPE` lines. Metric names may contain only letters, digits,
      `_` and `:`, and must not start with a digit; label values must escape
      backslashes, double quotes and newlines. A program without a name
      exports plain `build_info`.
    ],
    hint: [`strings.NewReplacer` does the escaping in one pass. The test's expected output is the specification.],
    tests: "workbook/ch01/exercises/ex5",
  ),
  (
    tier: "core",
    title: [An escape hatch for the vulnerability gate],
    body: [
      The `vuln` job fails on any reachable vulnerability, including one with
      no fixed version yet, which blocks every merge until upstream ships a
      fix. Design an allowlist: a file of advisory IDs, each with an owner, a
      reason and an expiry date, applied to `govulncheck -format json` so
      allowed findings pass until they expire and then fail the build again.
      Decide the file format, who may approve entries, what the weekly run
      does about entries that are about to expire, and what stops the list
      from becoming a place where findings go to be forgotten.
    ],
    hint: [The JSON output is a stream of messages; only `finding` messages whose trace reaches a function in your code are what the text output calls "affected".],
  ),
  (
    tier: "stretch",
    title: [A build-info inventory],
    body: [
      Write `cmd/inventory` in the `stamp` module:
      `inventory [-module path [-older version]] dir...` walks the
      directories, reads every regular file with `debug/buildinfo.ReadFile`,
      skips files that are not Go binaries, and prints a table sorted by file
      path: `BINARY`, `VERSION` (the main module's), `GO`, `PLATFORM`
      (`GOOS/GOARCH` from the settings) and `MODIFIED` (`vcs.modified`, or
      `-`), plus a `MODULE` column with the version of `-module` (or `-`)
      when that flag is set. With `-older`, list only binaries whose version
      of `-module` is lower. Usage errors exit 2. Use it to answer "which
      binaries contain `golang.org/x/net` older than v0.60.0".
    ],
    hint: [`golang.org/x/mod/semver` compares versions correctly; string comparison does not (`v0.9.0` > `v0.10.0`). The acceptance test builds its own fleet, including a test binary that links `go-cmp`.],
    tests: "workbook/ch01/exercises/ex7",
  ),
)
