#import "../template/book.typ": *
#import "02-lib.typ": ts, needspace

#chapter(2, "Designing Go APIs That Last", label: <ch-api-design>,
  abstract: [
    A platform team's Go SDK gets imported by dozens of teams, vendored into
    CLIs, and compiled into services nobody has touched in a year. Every
    exported name in it is a promise you will keep for years. In this
    chapter you build that SDK for the platform's deployment API from an
    empty directory, one working step at a time, together with the fake
    server its users will test against. Along the way you meet Go's
    interfaces from the ground up, and you finish by changing the API
    without breaking the people who depend on it.
  ],
  learn: (
    [Why breaking changes are so expensive under Go modules, and what the Go 1 promise and `/v2` import paths mean for your own packages],
    [What an interface is, how a type satisfies one, and why Go interfaces are small and owned by the code that uses them],
    [Functional options versus config structs, validation in constructors, and zero values that work],
    [Context as API surface, request IDs, idempotency keys, and retry classification],
    [Paginated APIs as `iter.Seq2` iterators, and streams as `io.Reader`],
    [Generics in SDK code, Go 1.27 generic methods, and their limits],
    [Doc comments, runnable examples, deprecation, and catching breaking changes with `apidiff`],
  ),
  build: [
    *`platformapi`*, the Go SDK for the platform's environments, services and
    deployments API, in eight steps: functional options, context-first
    methods, typed errors, iterators, typed long-running operations, and
    retries with idempotency keys.

    #v(4pt)
    *`platformapifake`*, an in-memory platform for tests, a consumer package
    that defines its own interface, and a tour program. The last step is the
    production SDK in the book's repository; the `ship` deployment CLI in
    Part V is built on it.
  ],
)

== The SDK fifty teams import <sec-api-cost>

The platform team runs an internal HTTP API for environments, services and
deployments. For its first year, every team that wanted to deploy wrote its
own client: a Python script in one repository, `curl` in a Makefile, four Go
wrappers with four different ideas about retries. Then one of those wrappers
retried a `POST /v1/deployments` after a client-side timeout. The first
request had already reached the server, so checkout got two rollouts of the
same version racing each other through staging. The postmortem's action item
was one line: _the platform team owns the client_.

So now there is an SDK, and the cost structure of every change to it is
lopsided. Renaming a field takes its author ten minutes. For each consuming
module it costs an upgrade pull request, a review, a CI run and a release.
Call it half a day of an engineer's time. With 50 consuming modules, one
rename costs about 25 engineer-days, spread across teams who did not ask for
it and will not schedule it this sprint.

Go modules add a twist that surprises people coming from other ecosystems.
The `go` command uses _minimal version selection_: for each module in the
build, it picks the highest version that any module in the build requires.
Suppose the `ship` CLI requires `platformapi` v1.3.0 and also imports an
internal library that requires v1.8.0. Then `ship` builds with v1.8.0,
whether or not its authors ever tested against it. If v1.8.0 removed a
function `ship` calls, `ship` stops compiling on the day someone bumps the
library, and the `ship` team changed nothing. In Go, a new minor version
must be a superset of the old one, because consumers don't get to choose.

The Go project holds itself to the same rule. The Go 1 compatibility promise
of 2012 says that programs written against Go 1 keep compiling and running.
The _import compatibility rule_ extends it to every module: if an old package
and a new package have the same import path, the new one must be backwards
compatible with the old one. A breaking change therefore needs a new import
path, which for modules means a major version suffix such as `/v2`. The
standard library follows its own advice: `math/rand/v2` arrived in Go 1.22
and `encoding/json/v2` in Go 1.27, both alongside their v1 packages, which
keep working. Behaviour changes in the toolchain ship with a `GODEBUG`
setting that restores the old behaviour, and since Go 1.21 the default
follows the `go` line in your `go.mod`.

An internal SDK can adopt the same discipline cheaply, as long as it is
designed for it from the first commit. That means a small surface, types
that can grow, behaviour pinned down by tests, and a mechanical check that
catches breaking changes before they are tagged. The rest of this chapter
builds such an SDK. While you build it, its version is v0: until the first
`v1.0.0` tag, Go's tooling treats every release as unstable, and this is
the only time a signature can change for free. Step 4 uses that freedom
once, on purpose.

== What we're building <sec-api-building>

`platformapi` is a Go package that talks to the platform's HTTP API. You
create one `Client` per process and call methods on it:
`GetEnvironment`, `ListDeployments`, `CreateDeployment`, `Wait`. Nobody
outside the platform team sees the HTTP underneath. In the same module you
build `platformapifake`, an in-memory version of the platform that every
test in this chapter runs against, and that the SDK's users will run their
own tests against.

Here is the finished SDK at work, in step 8. A small tour program starts a
deployment against the fake, follows the rollout one snapshot at a time,
and streams the deployment's log:

#output("ch02/s8-tour-deploy.txt", cmd: "go run ./examples/tour deploy")

@fig-api-layers shows the package's layers and the order in which a call
passes through them. Each layer has one job, and only the top one is
public.

#fig(placement: auto, caption: [One call through `platformapi`. Consumers see methods, `Operation[T]`, iterators and `*APIError`. Everything below the first row is unexported and free to change. The numbers in parentheses are the build steps that add each layer.])[
  #diagram(
    spacing: (26pt, 10pt),
    dnode((0, 0), [consumers: `ship`, bots, portal plugins], kind: "muted"),
    dnode((0, 1), [methods · `GetDeployment` · `ListDeployments` · `Wait` #h(3pt) (1, 4, 5, 6)], kind: "dark"),
    dnode((0, 2), [generic helpers · `call[T]` · `list[T]` #h(3pt) (4, 5)], kind: "accent"),
    dnode((0, 3), [`do` · request ID · idempotency key · `retry.Policy` #h(3pt) (4, 7)], kind: "accent"),
    dnode((0, 4), [`attempt` · `Limiter` · classify the status #h(3pt) (2, 7)], kind: "accent"),
    dnode((0, 5), [`send` · `TokenSource` · refresh on 401 #h(3pt) (2, 7)], kind: "accent"),
    dnode((0, 6), [`*http.Client` · your `RoundTripper` #h(3pt) (1, 2)], kind: "default"),
    dnode((1, 6), [platform API\ or `platformapifake`], kind: "good"),
    dnode((1, 1), [`Operation[T]` · `iter.Seq2`\ `*APIError` · sentinels], kind: "muted"),
    dedge((0, 0), (0, 1), "-|>"),
    dedge((0, 1), (0, 2), "-|>"),
    dedge((0, 2), (0, 3), "-|>"),
    dedge((0, 3), (0, 4), "-|>", label: [per attempt], label-side: left),
    dedge((0, 4), (0, 5), "-|>"),
    dedge((0, 5), (0, 6), "-|>"),
    dedge((0, 6), (1, 6), "-|>", label: [HTTPS]),
    dedge((0, 1), (1, 1), "--", label: [returns]),
  )
] <fig-api-layers>

=== The plan

You build `platformapi` in eight steps, then use it in a lab about changing
an API safely. Each step ends with a module that compiles, passes its tests
under the race detector, and shows you something new.

#table(
  columns: (auto, 1.25fr, 1fr),
  table.header([Step], [What it adds], [Go you meet there]),
  [1 #h(3pt) Types and a first call], [Resource types, a `Client` with three `Get` methods, the fake server, the first tests], [struct tags, interfaces from scratch, `http.Handler`, method sets, `context`, `httptest`],
  [2 #h(3pt) Options], [Validated functional options, a User-Agent, bearer tokens, a rate-limit hook, logging], [closures, function types with methods, struct embedding, variadic parameters, `errors.Join`],
  [3 #h(3pt) Typed errors], [`*APIError`, `ErrNotFound`, `ErrConflict`, safe paths], [error types, `Is` methods, `errors.Is` and `errors.AsType`],
  [4 #h(3pt) Every call identified], [Call options, request IDs, idempotency keys, creating and cancelling deployments], [generics, Go 1.27 generic methods, the `uuid` package],
  [5 #h(3pt) Pages and streams], [Paginated lists as iterators, `Collect`, deployment logs], [range over func, `iter.Seq2`, `io.Reader` composition],
  [6 #h(3pt) Long-running operations], [`Poll`, `Wait`, `*OperationError`, a consumer with its own interface], [consumer-defined interfaces, embedding as an adapter, typed nils, `testing/synctest`],
  [7 #h(3pt) Retries], [A retry policy, classification, `Retry-After`, a limit on every attempt, token refresh], [type assertions, optional interfaces],
  [8 #h(3pt) Documentation], [Package docs, runnable examples, a tour program], [doc comments, testable examples, `go doc`],
  [Lab #h(3pt) Evolving the API], [Two versions of an API compared by `apidiff`], [compatibility rules, deprecation, `/v2`],
)

After the lab, two sections cover what doesn't fit inside a step: the
design patterns that interfaces give you in tools like this one
(@sec-api-patterns), and what changes when the SDK runs in hundreds of
processes (@sec-api-scale).

=== How to work through the steps

Every step lists the files to create or the declarations to replace, in
full. Type them, run the checkpoint commands at the end of the step, and
compare your output with the book's. Timings and generated IDs will differ
from run to run; everything else should match. If it doesn't, the
troubleshooting table under each checkpoint lists failures we produced on
purpose by breaking a copy of that step, with the exact message each one
prints.

If you get stuck, the repository has every step as a complete module under
`workbook/ch02/step1` to `step9`, and each one passes `go vet`, `go test -race` and `golangci-lint`. Diff your directory against the step you are on.
The last step is not a toy: the repository's `pkg/platformapi` is the same
code with a longer import path, and a check in CI keeps them identical.

You need Go 1.27 and the `golangci-lint` setup from Chapter 1. Nothing in
this chapter needs network access except one `go get` in step 2 and one
`go install` in the lab.

#include "02a-api.typ"
#include "02b-api.typ"
#include "02c-api.typ"
