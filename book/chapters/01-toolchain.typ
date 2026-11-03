#import "../template/book.typ": *

#chapter(1, "The Platform Engineer's Go: Toolchain, Modules, and the Monorepo", label: <ch-toolchain>,
  abstract: [
    Every platform team eventually gets the same question on a bad day: which
    of the binaries we run were built with the vulnerable library, by which
    compiler, from which commit? Go can answer it from the binaries
    themselves, but only if the toolchain is pinned, the module graph is
    understood, and the build is set up to record what went in. This chapter
    covers the machinery under `go build` that most teams never look at,
    using this book's own repository as the case study.
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
    *`pkg/buildinfo`*, the package every tool in this book uses for
    `--version`, `User-Agent` and build metadata, plus `stamp`, a command
    that shows exactly what the toolchain embeds in a binary.

    #v(4pt)
    *`mkproxy`*, which serves a private module universe from a txtar file, so
    module behaviour can be demonstrated and tested offline.
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

Before the mechanics, it is worth being precise about why Go is the default
language for this kind of software, because the reasons are the same
properties this chapter teaches you to protect.

*Static binaries.* With cgo disabled, the Go linker produces a single
executable that depends on nothing but the kernel. This is the release build
of `sweep` from Chapter 4 for Linux, examined by `file`:

#output("ch01/build-file.txt", cmd: "file -b \"$DEMO/sweep-linux-amd64\" | tr , \"\\n\" | grep -v BuildID")

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
  ("time GOCACHE=\"$DEMO/gocache\" go build -o /dev/null ./cmd/sweep", "ch01/build-cold.txt"),
  ("time GOCACHE=\"$DEMO/gocache\" go build -o /dev/null ./cmd/sweep", "ch01/build-warm.txt"),
)

A cold build, standard library included, takes seconds of wall time; a warm
one takes well under a second. CI pipelines that run `go vet`, a linter and
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

== The go command chooses its own toolchain <sec-tc-toolchain>

Open the root `go.mod` of this repository:

#src("go.mod")

Two lines at the top describe the module's dependency on Go itself. The `go`
line is the _minimum_ Go version required to use the module. Since Go 1.21 it
is a hard requirement: a toolchain older than the `go` line refuses to build
the module rather than producing confusing compile errors. It also sets the
language version, so features like range-over-func iterators are only
available when the `go` line allows them. The `toolchain` line is a
_preference_: the toolchain the module's developers want used when they work
in it. Libraries that are consumed by others keep a conservative `go` line
and can still ask for a newer toolchain for their own development.

The machine this book was written on has Go 1.26.4 installed system-wide.
The repository needs 1.27. Watch what happens:

#session(
  ("go version", "ch01/tc-version.txt"),
  ("GOTOOLCHAIN=local go version", "ch01/tc-local.txt"),
  ("go env GOTOOLCHAIN GOVERSION GOROOT", "ch01/tc-env.txt"),
)

The `go` binary on `PATH` is 1.26.4, but inside the repository it reports
1.27.3. Since Go 1.21 the distribution is a `go` command plus a bundled
toolchain, and the command is allowed to run a _different_ toolchain when the
module asks for one. It read the `toolchain` line, found go1.27.3 in the
module cache, and re-executed itself as that version. `GOROOT` shows where
that toolchain lives: it was downloaded as an ordinary module,
`golang.org/toolchain`, at version `v0.0.1-go1.27.3.darwin-arm64`.

#newingo("1.24", title: [Tracing toolchain selection])[
  `GODEBUG=toolchaintrace=1` makes the `go` command explain its choice. The
  output is long, so the capture folds it:
  #output("ch01/tc-trace.txt", cmd: "GODEBUG=toolchaintrace=1 go version 2>&1 | fold -s -w 88")
  This is the first thing to run when a CI job and a laptop disagree about
  which compiler built something.
]

=== The GOTOOLCHAIN setting

`GOTOOLCHAIN` controls the switching. Like every `go` environment setting it
is read from the process environment first, then from the user's `go env -w`
file, then from `$GOROOT/go.env` inside the installed distribution, which
sets `auto` in official releases. Linux distributions that repackage Go
sometimes change that default, which is one reason two machines with "the
same Go" can behave differently.

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
places:

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
  installed Go gets a download failure that looks like a network problem.
  Either mirror `golang.org/toolchain` (each version is about 70 MB per
  platform) or install toolchains by other means and set
  `GOTOOLCHAIN=path`, so the failure message names the missing binary.
]

=== Managing the lines with go get

Edit the `go` and `toolchain` lines with `go get`, not by hand. The `go`
command treats them as dependencies and keeps them consistent. Here is a new
module created with the system Go:

#session(
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
rule the next section applies to modules, applied to the compiler. It is why
applications and tools should carry a `toolchain` line naming the current
patch release, and why bumping it belongs in the same automated update flow
as any other dependency. Since Go 1.25 the `go` command no longer adds a
`toolchain` line on its own when it raises the `go` line, so the line only
changes when someone decides it should.

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
  1.27.0". Mention `GODEBUG=toolchaintrace=1` for debugging, that `go get
  go@1.N` is how you change the requirement, and that the `go` line alone
  selects the `.0` release, which is why applications pin a patch release
  with the `toolchain` line.
]

== Modules and minimal version selection <sec-tc-modules>

A module is a tree of packages versioned together, rooted at a `go.mod` file.
Its path (`github.com/rahulbalajee/platform-go`) is both its name and the
prefix of every import path inside it. Versions are semantic version tags on
the repository (`v1.4.0`), or _pseudo-versions_ such as
`v0.0.0-20261103081532-b0977b0a7e31` for untagged commits: a base version, the
commit time in UTC, and a 12-character commit hash prefix. They appear in
the build information of every binary built from an untagged commit, as
@sec-tc-build and @sec-tc-buildinfo show.

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
the `/v2` path, which some projects avoid by staying on v0 forever (v0 makes
no compatibility promise) or by tagging `+incompatible` versions from before
modules existed.

=== Reading the build list

The module graph is a list of edges: "this module version requires at least
that module version". Here it is for this repository's root module:

#output("ch01/mod-graph.txt", cmd: "go mod graph")

The `go` and `toolchain` requirements appear as nodes in the graph, alongside
the modules. Every `go.mod` contributes edges, including those of modules you
never import directly, such as `goleak`'s dependency on `testify`.

The algorithm that turns this graph into the set of versions used for a build
is *minimal version selection* (MVS), designed by Russ Cox for Go modules.
It is short: start at the main module, walk every reachable requirement, and
for each module keep the _highest_ version anyone requires. That list is the
build list. Look at `golang.org/x/sys`:

#session(
  ("go mod graph | grep golang.org/x/sys@", "ch01/mod-sys-graph.txt"),
  ("go list -m golang.org/x/sys", "ch01/mod-sys-list.txt"),
)

`go-internal` requires `x/sys` v0.26.0 or later.
The root module asks for v0.49.0. MVS selects v0.49.0, the maximum of the
minimums. It does not look at what exists on the proxy: if `x/sys` v0.50.0
was released this morning, nothing changes until someone asks for it.

The same rule at a larger scale, in the `watchtower` operator's module:

#session(
  ("go mod graph | awk '$2 ~ /^golang.org\\/x\\/net@/ {print $2}' | sort -V | uniq -c", "ch01/mod-xnet.txt"),
  ("go list -m golang.org/x/net", "ch01/mod-xnet-list.txt"),
)

Seventeen requirements on `golang.org/x/net` at seven different minimum
versions, from gRPC, OpenTelemetry, the Kubernetes libraries and the
Prometheus client. The build uses one version, v0.59.0, the highest anyone
asked for. Every library in the build gets a version at least as new as the
one it declared, and never a version that nobody asked for.

=== A module universe you can run

Real dependency graphs are too large to experiment on, and public modules
cannot be edited to show what a retraction looks like. The repository
therefore ships `mkproxy`, a small program that turns a txtar archive into a
directory laid out in the `GOPROXY` protocol, and a universe of modules
written for this chapter: a service, `example.com/app`, uses a logging library
and a metrics library, and both depend on `example.com/codec` at different
minimum versions. @fig-tc-mvs shows the shape.

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

The demo serves the universe from a directory, so it runs offline and never
touches a real proxy:

#session(
  ("go run ./examples/ch01/mkproxy -o \"$DEMO/mvs\" examples/ch01/mkproxy/universe.txtar", none),
  ("cd \"$DEMO/mvs/app\"", none),
  ("export GOPROXY=\"file://$DEMO/mvs/proxy\" GONOSUMDB=example.com", none),
  ("go mod tidy", "ch01/mvs-tidy.txt"),
  ("go list -m all", "ch01/mvs-list.txt"),
  ("go run .", "ch01/mvs-run.txt"),
)

The `log` library asked for `codec` v1.3.0 and runs with v1.4.0, because
`metrics` needs v1.4.0 and there is only one `codec` v1 in a build. That is
the contract MVS relies on: a library declares the oldest version it works
with and must keep working with newer v1 releases. `codec/v2` sits alongside
as a separate module. (`GONOSUMDB=example.com` tells the `go` command these
modules are not in the public checksum database; @sec-tc-trust explains why
that matters.)

The proxy directory itself is worth a look, because it _is_ the protocol: a
proxy is anything that can serve these files over HTTPS, or from disk.

#output("ch01/mvs-proxy.txt", cmd: "ls -C \"$DEMO/mvs/proxy/example.com/codec/@v\"")

`list` names the versions, `.info` gives a version's canonical name and
time, `.mod` is its `go.mod`, and `.zip` holds the source under a
`module@version/` prefix. The `go` command fetches `.mod` files for every
version it needs to consider while building the graph, and `.zip` files only
for versions it selects. `mkproxy` is under 200 lines of standard library code
(`archive/zip`, `encoding/json`) that writes these files; a test in the same
package runs `go list -m all` against the generated proxy, so the universe in
this chapter cannot drift from what the toolchain really does.

=== Upgrades are explicit

Because nothing changes until someone asks, upgrading is a deliberate act.
`go list -m -u` shows what is available, and `go get` moves requirements:

#session(
  ("go list -m -u all", "ch01/mvs-u.txt"),
  ("go get example.com/metrics@v1.3.0", "ch01/mvs-get.txt"),
  ("go run .", "ch01/mvs-run2.txt"),
)

Upgrading `metrics` raised its own requirement on `codec` to v1.5.0, and MVS
followed: `go get` recorded both changes in `go.mod`. That version turned out
to be bad, which is the next section's subject.

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

== Changing the graph: retract, exclude, replace <sec-tc-directives>

Three directives modify version selection. They behave differently enough
that each one is worth seeing in action.

=== retract: the author withdraws a version

`codec` v1.5.0 shipped a bug that silently drops zero-valued fields when
encoding. The maintainers cannot delete the tag: the module proxy has cached
it, and deleting it would break every build that already selected it.
Instead they publish v1.5.1 with a `retract` directive in its `go.mod`:

#output("ch01/mvs-retract-mod.txt", cmd: "cat \"$DEMO/mvs/proxy/example.com/codec/@v/v1.5.1.mod\"")

Retractions are read from the latest version of the module, and they change
what tools _recommend_, not what builds use. The `go get` above already
printed a warning with the rationale from the comment. Afterwards:

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
surprise people, so here is what it does when we exclude the version
MVS selected:

#session(
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
version (a fork) or with a directory on disk:

#session(
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
two modules at once on your machine, a workspace (@sec-tc-workspaces) is the
better tool, because it never touches `go.mod`.

#table(
  columns: (auto, auto, 1fr),
  table.header([Directive], [Written by], [Effect]),
  [`retract`], [module author], [Hides versions from `@latest`, `-versions` and upgrades; warns users who have them. Builds keep working.],
  [`exclude`], [main module], [Removes a version from the graph. Requirements on it are dropped, which can lower the selected version.],
  [`replace`], [main module or `go.work`], [Swaps a module's contents for another version or a directory. Ignored when your module is a dependency.],
  [`ignore`], [main module (Go 1.25)], [Not about versions: hides directories such as `node_modules` from `./...` patterns while keeping them in module zips.],
)

== Trust: go.sum, the checksum database and proxies <sec-tc-trust>

MVS decides _which_ versions to use. A second mechanism makes sure every
machine gets the _same bytes_ for those versions.

=== go.sum

`go.sum` holds a cryptographic hash of every module version the build has
needed, usually two lines per version:

#output("ch01/trust-sum.txt", cmd: "grep golang.org/x/sync go.sum")

The `h1:` hash covers the module's zip file; the `/go.mod` line covers only
its `go.mod`, which is all the `go` command needs for versions that take part
in graph construction but are not selected. When the `go` command downloads a
module into the cache it recomputes the hash and refuses to use the module if
it differs. `go mod verify` re-checks everything already in the module cache:

#output("ch01/trust-verify.txt", cmd: "go mod verify")

=== The checksum database

`go.sum` protects you from a module changing _after_ you first fetched it.
It cannot help the first time: whoever adds a dependency trusts whatever the
proxy or the origin server returned at that moment. The checksum database at
`sum.golang.org` closes that gap. It is a transparency log, an append-only
Merkle tree of `go.sum` lines for every public module version anyone has
fetched, signed by Google and auditable by anyone. Here is its record for
`x/sync` v0.24.0:

#output("ch01/trust-sumdb.txt", cmd: "curl -s https://sum.golang.org/lookup/golang.org/x/sync@v0.24.0 | cut -c1-80")

The first line is the record's position in the log, then the two `go.sum`
lines, then a signed tree head (the log size and root hash). Before writing a
new line to `go.sum`, the `go` command checks it against this log and
verifies the log's consistency with what it has seen before. A proxy that
serves different bytes to you than to everyone else gets caught, which is why
the public proxy does not need to be trusted. If an author moves a tag to
different code, the checksum database still holds the original hash, and
every fresh download of the new bytes fails verification.

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

`GOPROXY` defaults to `https://proxy.golang.org,direct`: try Google's
module mirror, and if it answers 404 or 410, clone from the origin. The
separator matters. After a comma the `go` command only tries the next entry
on "not found"; any other error, such as a 403 or a timeout, is final. After a
pipe (`|`) it moves on after any error. The comma is what lets a company proxy
act as a gatekeeper: a 403 for a blocked module stops the download instead of
falling through to the internet. `off` disables downloads entirely, which is
useful in hermetic build steps that should only use a pre-populated cache.

=== Private modules on GitHub

Private code needs three things: the `go` command must not ask public
services about it, it needs credentials, and it must know which repository
to clone. `GOPRIVATE` handles the first. It is a list of path globs, and it
is the default for both `GONOPROXY` (fetch directly) and `GONOSUMDB` (don't
consult the checksum database, which would leak the module path and fail
anyway):

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
1.24 added `GOAUTH`, which generalises the
`.netrc` lookup: the default is `netrc`, `git <dir>` asks a `git` credential
helper, and a custom command can return arbitrary HTTP headers (for example
a short-lived bearer token for a private proxy) scoped to URL prefixes,
something `.netrc` cannot do.

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
space-separated. `GOFLAGS=-mod=readonly` (the default since Go 1.16) makes
any command that would need to change `go.mod` fail instead, which is exactly
what CI wants. `-modcacherw` leaves the module cache writable so scratch
directories can be deleted, as the capture script for this chapter does.
Setting `-trimpath` here is tempting but hides it from anyone reading the
build command; put release flags in the Makefile or the release tool.

=== Vendoring

`go mod vendor` copies every package the build needs into `vendor/`, and the
`go` command uses it automatically when it exists (for `go` lines of 1.14 and
later). It answers real requirements: air-gapped builds, auditors who want
every line of shipped source in the repository, build systems such as Bazel
that dislike network access. Its costs scale with the dependency graph:

#output("ch01/vendor.txt", cmd: "go mod vendor && du -sh vendor && find vendor -name \"*.go\" | wc -l")

That is `watchtower`: 69 MB and over five thousand Go files, and every
dependency bump becomes a diff of thousands of lines that nobody reviews. With
the checksum database and an internal proxy (@sec-tc-scale) giving
availability and integrity, most teams do not need to vendor. If you do, keep
`go.sum` and run `go mod vendor` in CI followed by `git diff --exit-code` so
nobody edits vendored code by hand.

== Pinning developer tools with the tool directive <sec-tc-tools>

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

#output("ch01/tools-get.txt", cmd: "go get -tool golang.org/x/tools/cmd/stringer@v0.52.0")

The `tool` line names the package; the `require` lines, marked
`// indirect` because no package imports them, pin the versions, and `go.sum`
pins the bytes. This chapter keeps its tools in a nested module,
`examples/ch01/tools`, for a reason explained below. Its `go.mod` has two
`tool` lines, for `stringer` and `govulncheck`. The module's one package models the phases of a progressive rollout, the kind
of enum that ends up in logs, JSON and metrics labels and is tedious to keep
in sync by hand:

#src("examples/ch01/tools/rollout/phase.go", region: "phase")

`go generate` runs the directive with the module's pinned `stringer`:

#session(
  ("go tool | grep -F '('", "ch01/tools-list.txt"),
  ("go generate -x ./...", "ch01/tools-generate.txt"),
  ("go test -count=1 ./...", "ch01/tools-test.txt"),
)

The generated `phase_string.go` is committed, so building the package never
needs the generator. Its `String` method slices one constant string,
`"pendingcanaryprogressing..."`, using an array of offsets, which costs no
allocation and no map lookup. Above it sits a function with a blank name:

#output("ch01/tools-phase-string.txt", cmd: "sed -n '/^func _/,/^}/p' rollout/phase_string.go", size: 6.6pt)

It is a compile-time freshness check. If someone inserts a phase without
regenerating, the constant values shift, one of the array indexes goes out of
range, and the build fails with "invalid array index" instead of logging the
wrong phase name. Pair it with a CI step that runs
`go generate ./...` and then `git diff --exit-code`, so a stale generated
file cannot be merged.

=== Tools share your module graph

A `tool` line is a real dependency. Its module's requirements take part in
MVS together with your code's requirements. Here is what happens when someone
adds `govulncheck` as a tool of the `watchtower` operator:

#output("ch01/tools-wt-get.txt", cmd: "go get -tool golang.org/x/vuln/cmd/govulncheck@v1.9.0")

Adding a vulnerability scanner upgraded the operator's _runtime_ HTTP/2
stack, `golang.org/x/net`, from v0.59.0 to v0.61.0, along with `x/sys` and
`x/text`. In this case the upgrade happens to be welcome (@sec-tc-gates shows
why), but a pull request titled "add govulncheck" should not change what runs
in production. The more tools a module pins, the more of these interactions
there are.

The fix is to keep tools in their own module, as this chapter does, and run
them from anywhere with `-modfile`:

#output("ch01/tools-modfile.txt", cmd: "go tool -modfile=examples/ch01/tools/go.mod govulncheck -version")

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

== Workspaces for multi-module work <sec-tc-workspaces>

This repository contains several modules. Suppose you are changing
`pkg/retry` in the root module and want the `watchtower` operator to use the
change before it is released. Without workspaces you would add a `replace`
directive to `watchtower/go.mod`, and then have to remember to remove it. A
workspace does the same thing from a file that is not part of either module.

The demo runs in a scratch clone, because a `go.work` file affects every
`go` command run beneath its directory:

#session(
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

== Repository layout: one repo, several modules <sec-tc-layout>

Go imposes very little layout. The compiler enforces exactly two rules: a
directory is a package, and a package under a directory named `internal` can
only be imported by code rooted at `internal`'s parent. Everything else is
convention. This repository follows the conventions most large Go codebases
have settled on:

#table(
  columns: (auto, 1fr),
  table.header([Directory], [What lives there]),
  [`cmd/<name>/`], [One directory per binary. `main` packages stay tiny: flag parsing, wiring, and a call into a `run` function that tests can call directly (Chapter 4's `sweep`).],
  [`internal/`], [Code private to this module: `internal/sweep` is `sweep`'s engine. The compiler stops other modules from importing it, so it can change freely.],
  [`pkg/<name>/`], [Libraries meant to be imported by other modules: `conc`, `retry`, `lifecycle`, and this chapter's `buildinfo`. The `pkg/` prefix is a convention, not a rule; it tells readers "public API, keep it stable".],
  [`examples/chNN/`], [Focused programs for one chapter. Heavy dependencies go in nested modules here.],
  [`projects/<name>/`], [The large projects, each its own module: `watchtower` today, `forge`, `ship`, `sentinel` and `oncall` later.],
  [`book/`], [This book. No Go code, so it costs the `go` command nothing.],
)

=== Why watchtower is its own module

A single module for the whole repository is simpler: one `go.mod`, one
version, atomic changes. The operator gets its own module anyway, for three
reasons that apply to any large project in a shared repository.

*Dependency weight.* Count the build lists:

#session(
  ("go list -m all | wc -l", "ch01/mod-count-root.txt"),
  ("cd projects/watchtower && go list -m all | wc -l", "ch01/mod-count-wt.txt"),
)

The operator needs 179 modules, most of them Kubernetes and its transitive
dependencies. In one module, a developer working on `sweep` would download
them, every `go.mod` change would involve them, and MVS would apply
Kubernetes' requirements to the CLI's build. Worse, Kubernetes libraries move
in lockstep (`k8s.io/api`, `apimachinery` and `client-go` at matching minor
versions), so a CLI dependency that drags `x/net` forward can force an
operator upgrade nobody planned.

*Release cadence.* Each module is versioned separately. Tags for a nested
module carry its directory as a prefix, so a `watchtower` release would be
tagged `projects/watchtower/v0.3.0` and a root module release `v0.5.0`, and
neither forces a release of the other.

*CI isolation.* The operator's jobs need `envtest` binaries and a kind
cluster; the root module's job needs neither. Separate modules give separate,
cacheable jobs, which is exactly how `.github/workflows/ci.yml` is split.

Multi-module repositories have costs. A change that spans modules needs a
workspace locally and two steps upstream: release the library, then bump the
consumer. Every tool must loop over modules (`go test ./...` at the root does
_not_ descend into nested modules). The Kubernetes project lives with this at
the largest scale: its main repository holds the libraries under `staging/`,
and a publishing bot exports them as the separate `k8s.io/api`,
`k8s.io/client-go` and other repositories that the rest of the world imports.

=== internal is about import paths

The `internal` rule is defined on import paths, not module boundaries, and
that has a consequence for nested modules. This program imports
`internal/sweep` from the root module:

#src("examples/ch01/internaldemo/main.go.txt", lang: "go")

Copied into `projects/watchtower` in the workspace, it builds, because the
operator's import path starts with `github.com/rahulbalajee/platform-go/`, the
parent of `internal`:

#session(
  ("go build -o /dev/null ./hack/internaldemo && echo ok", "ch01/internal-ws.txt"),
)

Copied into an unrelated module, `example.com/ext`, in a workspace with the
same clone, the compiler refuses:

#terminal(size: 6.2pt, "$ go build -o /dev/null .\n" + read("/book/output/ch01/internal-ext.txt").trim(at: end))

(With `GOWORK=off`, the operator's copy fails too, but earlier: `watchtower`
does not require the root module at all.) So a nested module whose path sits
under the repository's path _may_ import the root module's internal packages.
Doing so couples their release cycles, because the root module's internals
can change in any commit. If two modules need to share code, put it in
`pkg/` and version it.

== Building binaries you can ship <sec-tc-build>

A release build answers the Friday question in advance. Here is the one this
repository uses for Linux, run from a clean clone:

#session(
  ("CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \\\n  -ldflags=\"-s -w\" -o \"$DEMO/sweep-linux-amd64\" ./cmd/sweep", "ch01/build-release.txt"),
  ("go version -m \"$DEMO/sweep-linux-amd64\"", "ch01/build-vm.txt"),
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
the `go` command omits `-ldflags` and the `CGO_*` flags from the build
settings, because they might contain paths (the `-ldflags="-s -w"` above is
missing from the output for that reason).

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
about 14 KB and its speed is set by the network. The FMA change also means
floating-point results can differ in the last bits between `v1` and `v3`
builds, which matters if a test compares floats exactly. For CPU-heavy components
(compression in a log shipper, the time-series engine in Chapter 26) measure
before and after. If your fleet is uniform and modern, raising the level is
cheap; if anyone runs your CLI on an old CI runner, keep the default.

=== Reproducible builds

A build is reproducible if the same source and toolchain produce the same
bytes regardless of who builds it, where, or when. That property lets a
third party verify that a published binary came from the published source,
and lets you rebuild an old release and get exactly what you shipped. Here
is the same commit cloned into two directories and built in each:

#session(
  ("cd \"$DEMO/a\" && GOOS=linux go build -o ../a.bin ./cmd/sweep", none),
  ("cd \"$DEMO/b\" && GOOS=linux go build -o ../b.bin ./cmd/sweep", none),
  ("shasum -a 256 ../a.bin ../b.bin", "ch01/repro-plain-sum.txt"),
  ("cd \"$DEMO/a\" && GOOS=linux go build -trimpath -o ../a.bin ./cmd/sweep", none),
  ("cd \"$DEMO/b\" && GOOS=linux go build -trimpath -o ../b.bin ./cmd/sweep", none),
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
`vcs.modified` setting and the stamped version. Cgo brings in the C
toolchain and its own nondeterminism, which is one more reason to disable
it. Chapter 11 builds on this with GoReleaser, SBOMs, signatures and SLSA
provenance.

== pkg/buildinfo: one version flag for every tool <sec-tc-buildinfo>

Every tool in this book needs to say what it is: a `--version` flag for
humans, a JSON form for scripts and support bundles, a `User-Agent` for the
APIs it calls, and labels for a `build_info` metric. The information comes
from two places, and the interesting design work is deciding between them.

The toolchain stamps the binary automatically. Since Go 1.24, `go build`
inside a Git checkout sets the main module's version from version control: a
tag if the commit has one, otherwise a pseudo-version, with a `+dirty` suffix
for uncommitted changes. It also records the commit, its time, and whether
the tree was modified. The release pipeline knows other things: the tag it is
about to create, or the commit of a source tree that was copied into a
Docker build context without its `.git` directory. It passes them to the
linker with `-X`, which overwrites the initial value of a package-level string
variable at link time:

#src("pkg/buildinfo/buildinfo.go", region: "vars")

The result type is plain data with stable JSON names, so other tools can
depend on its shape:

#src("pkg/buildinfo/buildinfo.go", region: "info")

`omitzero` (Go 1.24) leaves out the zero `time.Time` that `omitempty` would
have printed as `0001-01-01T00:00:00Z`. The merge is a pure function, so tests
can feed it every kind of build:

#src("pkg/buildinfo/buildinfo.go", region: "from")

The precedence is the same for every field: a linker value wins, then the
toolchain's value, then a documented default. `(devel)` is what the toolchain
reports when it has no version, and `buildinfo` normalises it to `devel`. The
human form avoids repeating what a pseudo-version already says:

#src("pkg/buildinfo/buildinfo.go", region: "format")

=== Three builds of the same command

The smallest real user of the package is the `stamp` command in
`examples/ch01`. With `-version` it prints `buildinfo.Get()` in text or JSON
form. With no flags it loops over the `Settings` that `debug.ReadBuildInfo`
returns and prints the raw material. First, a plain `go build` in the
working tree this chapter was written in, which has uncommitted changes:

#session(
  ("go build -o \"$DEMO/stamp\" ./examples/ch01/stamp", none),
  ("\"$DEMO/stamp\" -version", "ch01/bi-version.txt"),
)

#output("ch01/bi-json.txt", cmd: "\"$DEMO/stamp\" -version -json")

#output("ch01/bi-settings.txt", cmd: "\"$DEMO/stamp\"", size: 6.6pt)

The version is a pseudo-version derived from the last commit, with `+dirty`
because the tree was modified, and `vcs.modified` agrees. A binary like this
should never reach production, and a release pipeline can refuse to publish
anything whose version ends in `+dirty`.

Second, `go run`:

#output("ch01/bi-run.txt", cmd: "go run ./examples/ch01/stamp -version")

No version and no commit. In the `go` command's source, only
`go build`, `go install` and `go list` load version control information by
default; `go run` and `go test` skip it to stay fast (`-buildvcs=true` forces
it). That is why `buildinfo` must cope with missing data, and why its test
for the real test binary only checks the toolchain-derived fields.

Third, a release-style build that takes everything from the pipeline:

#session(
  ("export PKG=github.com/rahulbalajee/platform-go/pkg/buildinfo", none),
  ("go build -trimpath -buildvcs=false -o \"$DEMO/stamp\" -ldflags \"-s -w \\\n  -X $PKG.version=v1.4.0 \\\n  -X $PKG.revision=$(git rev-parse HEAD) \\\n  -X $PKG.buildTime=$(git log -1 --format=%ct)\" \\\n  ./examples/ch01/stamp", "ch01/bi-release.txt"),
  ("\"$DEMO/stamp\" -version", "ch01/bi-release-version.txt"),
)

#output("ch01/bi-release-vm.txt", cmd: "go version -m \"$DEMO/stamp\"")

`-buildvcs=false` stands in for a build context without `.git`: the toolchain
recorded no version and no commit, yet the tool reports `v1.4.0` with the
right revision and commit time, all from the linker. The build time is passed
as Unix seconds, the `SOURCE_DATE_EPOCH` convention from reproducible-builds
work; using the commit time instead of the wall clock keeps the build
reproducible.

#warning(title: [`-X` fails silently])[
  If the path or variable name in `-X` is misspelled, or the variable is a
  constant, or it is initialised by a function call, the linker ignores the
  flag without a word, and the release ships as `devel`.
]

=== Tests

Two kinds of test protect the package. The first is the only defence
against the silent `-X` failure: build the real binary with the real flags
and check its output.

#src("examples/ch01/stamp/main_test.go", region: "ldflags")

The unit tests describe each kind of build in the text format that
`go version -m` prints, and `debug.ParseBuildInfo` turns that text back into
a `*debug.BuildInfo`. A table-driven `TestFrom` feeds `from` the three builds
below, plus linker overrides with no VCS data, a malformed linker time and a
binary with no build information at all, and compares whole `Info` values
with `go-cmp`. One detail found while writing it: `ParseBuildInfo` skips the
`go` line, so the `parse` helper restores `GoVersion` from the fixture.

#src("pkg/buildinfo/buildinfo_test.go", region: "fixtures")

#output("ch01/bi-test.txt", cmd: "go test -race -count=1 ./pkg/buildinfo/... ./examples/ch01/...")

=== Adopting it

`sweep` from Chapter 4 still carries its own `var version = "dev"` and prints
`sweep dev`. Moving it to `buildinfo` is a few lines: call `buildinfo.Get()`,
set `Name` to `"sweep"`, call `info.Write(stdout, format)` for `-version`,
and set `info.UserAgent()` on the HTTP prober's requests so the services it
checks can see which version of the checker is calling (Exercise 4). The
later projects use the package the same way: a `version` command with both
output formats in the CLIs of Part II, `-X` flags passed by the release
tooling of Chapter 11, and a `build_info` gauge with the value 1 and the
version, revision and Go version as labels in Chapter 17, the convention
Prometheus itself follows with `prometheus_build_info`.

== Quality gates <sec-tc-gates>

Version stamps tell you what you shipped. Quality gates decide what is
allowed to ship. This repository runs three.

=== go vet

`go vet` runs the analyzers that ship with the toolchain: `printf` format
mismatches, copied locks, unreachable code, struct tags, misuse of
`sync.WaitGroup` and many more. They have almost no false positives, so CI
runs them all, and `go test` runs a high-confidence subset automatically
before every test run. The set grows with each release: Go 1.24 added the
`tests` analyzer for malformed test and example declarations, Go 1.25 added
`hostport` (addresses built with `fmt.Sprintf("%s:%d")`, which break on
IPv6), and Go 1.27 makes `go test` run `stdversion`, which flags standard
library symbols newer than the module's `go` line, and teaches `printf` to
flag `%w` applied to a `*E` whose type `E` already implements `error`.

=== golangci-lint

`golangci-lint` runs many analyzers in one process with a shared parse and
type-check. Every module in the repository uses the root configuration:

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
this repository's imports separately.

To see what the configuration catches, the capture script runs it on a
deliberately broken function that looks like code from any internal tool:

#src("examples/ch01/lintdemo/fetch.go.txt", lang: "go")

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
reported as success. This chapter's own code passes the same gates:

#session(
  ("go vet ./pkg/buildinfo/... ./examples/ch01/...", "ch01/gates-vet.txt"),
  ("golangci-lint run ./pkg/buildinfo/... ./examples/ch01/...", "ch01/gates-lint.txt"),
)

=== govulncheck

Most dependency scanners match module versions against advisories: if your
`go.sum` mentions a vulnerable version, you get an alert. `govulncheck` does
better. The Go vulnerability database records the affected _functions_ for
each advisory, and `govulncheck` builds a call graph of your program to
report only vulnerabilities your code can reach. Run against a clean
clone of the root module with the pinned tool:

#output("ch01/vuln-root.txt", cmd: "go tool govulncheck -C \"$DEMO/platform-go\" ./...")

It also scans binaries, using the build information from @sec-tc-build. This
is the Friday question answered from an artifact, with no source checkout:

#output("ch01/vuln-bin.txt", cmd: "go tool govulncheck -mode=binary -show verbose \"$DEMO/sweep-linux-amd64\"")

The operator is a different story. Here is the same scan of
`projects/watchtower`, filtered to the summary lines, at the time this
chapter's output was captured:

#output("ch01/vuln-wt.txt", cmd: "go tool govulncheck -C \"$BEFORE/projects/watchtower\" ./... | grep -E '^(Vuln|    F|Your)'", size: 6.6pt)

Reachable vulnerabilities in `x/net` (HTTP/2 flaws of exactly the Friday
kind), in OpenTelemetry and in gRPC, all arriving through transitive
dependencies, and all fixed in newer releases. This is the normal state of a
179-module graph, not a sign of neglect, and it is why `govulncheck` belongs
in CI for every module and on a schedule against the default branch:
advisories arrive whether or not anyone pushes code.

`$BEFORE` in that command is a `git worktree` of commit `b0977b0`, because
the report was acted on. The fix was four `go get` commands (`golang.org/x/net`
to v0.60.0, `google.golang.org/grpc` to v1.83.1, and the two OpenTelemetry
modules to v1.45.0), `go mod tidy`, and a green run of the envtest suite. The
same scan against the upgraded tree:

#output("ch01/vuln-wt-fixed.txt", cmd: "go tool govulncheck -C ../../../projects/watchtower ./...")

The four advisories left over sit in packages watchtower imports, or modules
it requires, but in functions its code never calls. `govulncheck` mentions
them and exits 0. That reachability analysis is the difference between a
scanner teams keep in CI and one they mute: a dependency scanner that fails
the build for every vulnerable function anywhere in a 179-module graph gets
switched off within a month. The repository's CI runs this scan for both
modules on every push and weekly on a schedule.

=== The CI contract

The Makefile is the contract between a developer's machine and CI:

#src("Makefile")

#output("ch01/make-n.txt", cmd: "make -n")

The CI job for the root module runs the same steps with the same pinned
linter version:

#output("ch01/ci-go-job.txt", cmd: "sed -n '/^  go:/,/^$/p' .github/workflows/ci.yml")

`go-version-file: go.mod` installs the version the module asks for, so CI and
laptops agree through the mechanism of @sec-tc-toolchain. The linter version
is pinned in both places. The other jobs repeat the pattern for
`watchtower` (plus a check that generated code is up to date, the CI half of
the `go generate` advice above) and for the book itself, whose build fails if
a listing's source region disappears. Two gates are missing from this
workflow, and adding them is Exercise 3: `govulncheck` on every module, and
`go mod tidy -diff`, which fails if `go.mod` or `go.sum` is out of date
without modifying them.

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
comma semantics in @sec-tc-trust, a 403 stops the download instead of falling
through to the internet. Keep the public checksum database on for public
modules; the proxy cannot forge them without being caught. And mirror
`golang.org/toolchain`, or toolchain switching breaks for everyone.

*Updates as a flow, not an event.* MVS means nothing upgrades by itself, so
someone has to. Let a bot (Renovate, Dependabot) open grouped pull requests
weekly, bump the `toolchain` line the same way, and make CI with `-race`,
`govulncheck` and `go mod tidy -diff` the judge. Libraries owned by the
platform team should be upgraded in their consumers by the platform team,
across all repositories, with the same bot. A library that 300 services pin
at 40 different versions is how a one-line fix becomes a quarter-long
migration. `go list -m -u all` and `go mod why -m` answer the two questions
in every upgrade review: what is behind, and why is this even here.

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
  metric and `govulncheck -mode=binary` exist for exactly this. A dashboard
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
  [Ship with `CGO_ENABLED=0 -trimpath -ldflags="-s -w"` from a clean checkout. The binary then carries its toolchain, dependencies and commit, and `go version -m` and `govulncheck -mode=binary` can read them.],
  [`pkg/buildinfo` merges toolchain stamping with linker overrides. Test `-X` flags by building the real binary, because typos fail silently.],
)

#exercises(
  [*A toolchain matrix.* Add a CI job that runs the root module's tests with `GOTOOLCHAIN=go1.26.10` and expect it to fail. Then make it pass by lowering the `go` line of a copy of `pkg/buildinfo` to the oldest version it supports. Which language or library features stop you, and how does `go vet`'s `stdversion` analyzer help find them?],
  [*Extend the universe.* Add `example.com/log` v1.3.0 to `universe.txtar`, requiring `codec` v1.6.0, which does not exist. What do `go get example.com/log@v1.3.0` and `go mod tidy` report? Then add a module whose `go.mod` declares `go 1.28` and observe how toolchain switching interacts with the file proxy (hint: the toolchain module is not in it).],
  [*Close the CI gaps.* Add `govulncheck` (using the pinned tool module) and `go mod tidy -diff` to `.github/workflows/ci.yml` for both modules, plus a scheduled nightly run on the default branch. Decide what should happen when a vulnerability has no fixed version yet.],
  [*Adopt buildinfo in sweep.* Replace `sweep`'s `version` variable with `pkg/buildinfo`, add `-version -o json`, and send `User-Agent: sweep/<version>` on HTTP checks. Write a test that proves the header is sent, using the fake server from Chapter 4.],
  [*A build_info inventory.* Write a command that walks a directory of binaries (or the layers of a container image), runs `debug.ReadBuildInfo`'s file equivalent (`debug/buildinfo.ReadFile`) on each, and prints a table of binary, main module version, Go version, `vcs.modified`, and the version of a given dependency. Use it to answer "which binaries contain `golang.org/x/net` older than v0.60.0".],
  [*Reproducibility in CI.* Add a job that builds `sweep` twice, in two different directories and on two runner images, and fails if the SHA-256 hashes differ. Then break it deliberately three ways (drop `-trimpath`, build from a dirty tree, enable cgo) and explain each failure.],
)
