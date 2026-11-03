#import "../template/book.typ": *

// Chapter 20's short name for the template's quote-output: a troubleshooting
// row quotes the first lines of a real failure that
// book/scripts/capture-ch20.sh produced by breaking a copy of a build step.
#let ts(name) = quote-output("ch20/ts/" + name)
#let wb = "workbook/ch20/"

#chapter(20, "Building Operators with controller-runtime", label: <ch-operators>,
  abstract: [
    An operator is the way your team runs something, written down as a
    control loop the Kubernetes API server can drive. This chapter builds
    `watchtower`, a monitoring operator, from `kubebuilder init` to a run on a
    real cluster. You declare a `HealthCheck`, and the operator probes it,
    reports health as conditions and Prometheus metrics, records Events when
    health changes, and keeps an alert rule in sync with whichever monitoring
    stack the cluster runs: the Prometheus Operator, Datadog, or nothing at
    all.
  ],
  learn: (
    [When an operator is the right tool, and when it isn't],
    [How controller-runtime's cache, workqueue, and reconcilers fit together],
    [CRD design: spec and status, conditions, CEL validation, defaults, printer columns],
    [Reconcilers that are level-triggered, idempotent, and nearly free in steady state],
    [Owner references, server-side apply, finalizers, and external resources],
    [Watches, predicates, and field indexes],
    [Testing with envtest and on a real kind cluster],
  ),
  build: [
    *`watchtower`*, in eight verified steps: a `HealthCheck` CRD and
    controller with health conditions, metrics and Events, plus
    stack-agnostic alerting. It writes `PrometheusRule` objects that repair
    themselves if edited, or Datadog monitors protected by a finalizer.

    #v(4pt)
    An envtest suite that grows with every step, and an end-to-end script
    that deploys the operator to kind and caught a real bug.
  ],
)

== What an operator is, and what it isn't <sec-op-what>

Kubernetes is built from controllers. The Deployment controller watches
Deployments and ReplicaSets and keeps the two in agreement. The ReplicaSet
controller does the same for Pods. Each one runs the same loop: observe the
current state, compare it with the desired state recorded in the API, act to
reduce the difference, and repeat. An _operator_ is that pattern applied to
your own domain. You add a resource type to the API with a
CustomResourceDefinition (CRD) and write a controller that makes reality
match it.

That definition contains the test for when to write one. An operator is the
right tool when three things are true:

+ The knowledge has to run _continuously_, not once. Rotating certificates,
  failing over a database, reconciling DNS records with Ingresses, or
  re-probing an endpoint every 30 seconds are all ongoing jobs. Rendering
  YAML once is not.
+ The desired state is naturally _declarative_. Users can say what they
  want, a health check with these properties, without saying how to get
  there.
+ Kubernetes is the system of record your users already use. Putting the
  thing in the API gives them `kubectl`, RBAC, GitOps, audit logs, and
  `kubectl wait` for free.

When those conditions don't hold, a CLI (Part II), a Job, a Helm chart, or a
service with its own API is simpler and easier to operate. A controller is a
long-running distributed system with leader election, caches and backoff, and
it should earn that complexity.

#note(title: [Why build a health checker?])[
  If all you need is synthetic HTTP checks scraped by Prometheus, the
  Prometheus blackbox exporter together with the Prometheus Operator's `Probe`
  resource already does it. `watchtower` is worth building for two reasons.
  It exercises every pattern a production operator needs: status design,
  owned resources, external resources, finalizers, cross-resource watches,
  metrics and Events. And its stack-agnostic alerting is a real gap: platform
  teams often run Prometheus in some clusters and Datadog in others, and want
  one resource that works in both. That is also why the custom kind is called
  `HealthCheck` and not `Probe`. Two kinds named `Probe` in one cluster make
  `kubectl get probes` ambiguous.
]

== What we're building <sec-op-building>

Here is the finished operator from step 8, deployed to a kind cluster with
four checks in a demo namespace: a Service in the cluster, `go.dev` on the
internet, an endpoint that always answers 503, and a check whose Service
doesn't exist yet.

#output("ch20/e2e/get-hc.txt", cmd: "kubectl get healthchecks -n shop")

The columns come from the CRD, not from a plugin. `payments-api` crossed its
failure threshold of 3 and is `False`; its alert rule lives in a
`PrometheusRule` that the operator owns. `inventory` is `Unknown` with the
reason `TargetUnresolved`, and turns healthy within seconds of someone
creating its Service. @fig-op-arch shows the parts and the step that adds
each one.

#fig(caption: [The finished `watchtower`. The numbers are the build steps that add each part. Everything the reconciler reads comes from the manager's cache.])[
  #diagram(
    spacing: (26pt, 16pt),
    dnode((0, 0), [`HealthCheck` CRD\ markers · CEL #h(2pt) *2*], kind: "accent"),
    dnode((1, 0), [manager · cache\ workqueue #h(2pt) *1*], kind: "dark"),
    dnode((2, 0), [`Service` watch\ field index #h(2pt) *5*], kind: "default"),
    dnode((1, 1), [`Reconcile` #h(2pt) *3*\ cadence gate #h(2pt) *8*], kind: "dark"),
    dnode((0, 2), [`probe.HTTP` #h(2pt) *3*], kind: "default"),
    dnode((1, 2), [conditions #h(2pt) *3*\ metrics · Events #h(2pt) *4*], kind: "good"),
    dnode((2, 2), [`alerting.Backend` #h(2pt) *6*], kind: "accent"),
    dnode((2, 3), [`PrometheusRule`\ owned · SSA #h(2pt) *6*], kind: "default"),
    dnode((1, 3), [Datadog monitor\ finalizer · UID #h(2pt) *7*], kind: "warn"),
    dedge((0, 0), (1, 0), "-|>"),
    dedge((2, 0), (1, 0), "-|>"),
    dedge((1, 0), (1, 1), "-|>", label: [keys]),
    dedge((1, 1), (0, 2), "-|>"),
    dedge((1, 1), (1, 2), "-|>"),
    dedge((1, 1), (2, 2), "-|>"),
    dedge((2, 2), (2, 3), "-|>"),
    dedge((2, 2), (1, 3), "-|>"),
  )
] <fig-op-arch>

=== The plan

You build `watchtower` in eight steps. Each ends with a module that
compiles, passes `go vet`, the linter and its tests, and does something you
can check.

#table(
  columns: (auto, 1.25fr, 1fr),
  table.header([Step], [What it adds], [Go you meet there]),
  [1 #h(3pt) Scaffold and run], [`kubebuilder init`, the manager in `main.go`, a reconciler that logs, an envtest suite, a run against kind], [struct embedding, struct tags and marker comments, `TestMain`],
  [2 #h(3pt) The API], [Spec and status, CEL validation, defaults, printer columns, tests against a real API server], [pointer fields for optional values, `omitzero`, promoted fields in literals],
  [3 #h(3pt) Probe and report], [The prober, the reconcile loop, the health state machine, status writes], [interfaces and function adapters, `sync/atomic`, `httptest`],
  [4 #h(3pt) Metrics and Events], [Prometheus metrics, Events on transitions, RBAC for both], [`init` and package-level state],
  [5 #h(3pt) Watching Services], [A secondary watch, a field index, a predicate], [closures as callbacks, method values],
  [6 #h(3pt) PrometheusRules], [The alerting interface, owned rules with server-side apply, self-healing], [interfaces as plug-in points, type assertions, `any`],
  [7 #h(3pt) Datadog and finalizers], [An external backend, finalizers, idempotency with the object UID, a fake API], [HTTP clients, `encoding/json`, `httptest` fakes],
  [8 #h(3pt) Cadence and kind], [The cadence gate, container images, the end-to-end run], [`sync.Map`, shell test harnesses],
)

After the build, a deep dive covers capacity planning and the failure modes
to know before running an operator in production (@sec-op-capacity).

=== How to work through the steps

You need Go 1.27, kubebuilder 4.16, Docker, kind and kubectl. Chapter 1
installs the Go tools and `golangci-lint`; kubebuilder is a single binary
from its GitHub releases. Every step lists the files to create or the
declarations to replace, in full. Type them, run the checkpoint commands,
and compare your output with the book's. Timings, ages and object UIDs will
differ; everything else should match. Under every checkpoint, a
troubleshooting table lists failures we produced on purpose by breaking a
copy of that step, with the exact message each one prints.

The repository has every step as a complete module under
`workbook/ch20/step1` to `step8`, each passing `go vet`, `go test -race`,
`golangci-lint` and its envtest suite. Diff your directory against the step
you are on. The last step is not a toy: `projects/watchtower` holds the same
files with a longer module path, and a check in CI keeps them identical.

#step(1, 8, "Scaffold and run", label: <sec-op-step-scaffold>)

kubebuilder generates the project skeleton: a Makefile wired to
`controller-gen` and `setup-envtest`, kustomize manifests, a hardened
`main.go`, and a controller with an empty `Reconcile`. Start from an empty
directory with a module of your own, so kubebuilder picks up the short
module path:

#session(
  ("mkdir watchtower && cd watchtower", none),
  ("go mod init watchtower", "ch20/s1-modinit.txt"),
  ("kubebuilder init --domain platformgo.dev --license none", "ch20/s1-init.txt"),
)

`--domain` becomes the suffix of the API group, and `--license none` skips
the Apache header kubebuilder would otherwise stamp on every file (the
warning below is about that missing header file, and is harmless). Then
create the API and its controller:

#output("ch20/s1-api.txt", cmd: "kubebuilder create api --group watchtower --version v1alpha1 \\\n  --kind HealthCheck --resource --controller", size: 6.2pt)

That gives the group `watchtower.platformgo.dev`, version `v1alpha1` and
kind `HealthCheck`. kubebuilder has already run `go mod tidy` and
`make generate`. Here is everything it wrote:

#output("ch20/s1-scaffold.txt", cmd: "find . -type f -not -path './bin/*' | sort")

#table(
  columns: (auto, 1fr),
  table.header([Path], [What it is]),
  [`api/v1alpha1/`], [Go types for the API. Comments starting with `+kubebuilder:` are _markers_ that `controller-gen` turns into the CRD schema, validation, defaults and printer columns.],
  [`internal/controller/`], [The reconciler. Its `+kubebuilder:rbac` markers generate the ClusterRole.],
  [`cmd/main.go`], [Builds the manager: metrics served with authentication and authorization, health probes, leader election, HTTP/2 off by default.],
  [`config/`], [Kustomize bases: `crd/`, `rbac/`, `manager/`, `default/` (the deployable bundle), `prometheus/` (a ServiceMonitor), `network-policy/`, `samples/`.],
  [`Makefile`], [`make manifests generate` runs controller-gen; `make test` downloads envtest binaries and runs tests; `make install` and `make deploy` apply kustomize bundles.],
  [`zz_generated.deepcopy.go`], [Generated `DeepCopy` methods. Never edit; regenerate.],
  [`test/`, `.github/`, `.devcontainer/`], [A Ginkgo end-to-end suite, CI workflows and a dev container. We replace the first and drop the others.],
)

The Makefile installs pinned tool versions into `./bin` with `go install`.
Go 1.24's `tool` directive in `go.mod` is an alternative for Go-based tools.
Either way, tool versions are part of the build, not of whoever's laptop runs
it. Recent kubebuilder versions also generate an `AGENTS.md` that describes
the project's conventions for AI coding assistants; it is a good summary of
the scaffold's rules for humans too.

Two changes before writing code. Pin the module to the Go release this book
uses, and remove the parts this chapter replaces. The generated tests use
Ginkgo and Gomega; ours use the standard `testing` package, which does the
same job with one less dialect to learn:

#session(
  ("go get go@1.27.0", "ch20/s1-goget.txt"),
  ("rm -r .devcontainer .github test internal/controller/*_test.go", none),
)

Run `go mod tidy` once you have written this step's files; it drops the
Ginkgo dependencies.

=== The machinery under controller-runtime

Chapter 19 builds a controller from raw client-go: informers, listers, a
workqueue and a worker loop. controller-runtime, the library under
kubebuilder and Operator SDK, packages those parts so you only write the
reconcile function. You still need to know what is underneath, because every
performance problem and most correctness bugs in operators come from it.

#fig(caption: [Inside a controller-runtime manager. Reads come from an eventually consistent cache; writes go to the API server; the workqueue deduplicates and rate-limits keys.])[
  #diagram(
    spacing: (30pt, 22pt),
    dnode((0, 0), [kube-apiserver], kind: "dark"),
    dnode((1, 0), [informers\ list + watch per kind], kind: "accent"),
    dnode((2, 0), [event handlers + predicates\ map events → `namespace/name`], kind: "default"),
    dnode((1, 1), [cache + indexes\ shared by all controllers], kind: "accent"),
    dnode((2, 1), [workqueue\ dedup · rate-limit · delay], kind: "default"),
    dnode((0, 2), [create · update\ patch · apply], kind: "warn"),
    dnode((2, 2), [N workers\ `Reconcile(ctx, req)`], kind: "dark"),
    dedge((0, 0), (1, 0), "-|>", label: text(size: 6.5pt)[watch]),
    dedge((1, 0), (2, 0), "-|>"),
    dedge((1, 0), (1, 1), "-|>"),
    dedge((2, 0), (2, 1), "-|>"),
    dedge((2, 1), (2, 2), "-|>"),
    dedge((2, 2), (1, 1), "--|>", label: text(size: 6.5pt)[reads: get · list], label-side: right),
    dedge((2, 2), (0, 2), "-|>", label: text(size: 6.5pt)[writes], label-side: left),
    dedge((0, 2), (0, 0), "-|>"),
  )
] <fig-cr-machinery>

Five properties of this design shape everything else in the chapter.

*Level-triggered, not edge-triggered.* The workqueue holds _keys_
(`namespace/name`), not events. If a HealthCheck changes five times before a
worker picks it up, the reconciler runs once and sees the latest state. Your
reconciler must therefore never depend on knowing _what changed_. It looks at
the whole object and the world, and decides what should be true.

*Deduplication and single-flight per key.* A key is in the queue at most once,
and the same key is never processed by two workers at the same time. You don't
need locks around per-object work. Different objects do reconcile in
parallel, up to `MaxConcurrentReconciles`.

*Reads are cached and eventually consistent.* `client.Get` and `client.List`
from the manager's client read the informer cache, not the API server. That
makes them fast and free, but it also means you can write an object and
immediately read an older version of it. Code must tolerate that, and the
optimistic-concurrency conflicts that follow from it.

*Errors and requeues are rate-limited.* Returning an error re-adds the key with
exponential backoff (the default per-item limiter starts at 5 ms and caps at
about 16 minutes), combined with an overall token bucket. Returning
`ctrl.Result{RequeueAfter: d}` schedules the key again after `d`. That is how
periodic work, like probing every 30 seconds, is expressed.

*At-least-once, maybe more.* Watches reconnect, the operator restarts, leaders
change, and every object is periodically reconciled again when caches resync.
A reconciler must be _idempotent_: running it twice in a row must have the
same effect as running it once.

#interview(title: [“What does level-triggered mean, and why does Kubernetes use it?”])[
  Edge-triggered systems react to events ("replica count changed from 3 to
  5"); level-triggered systems react to state ("there should be 5 replicas and
  there are 3"). Kubernetes controllers are level-triggered: the queue
  coalesces events into keys, and the reconciler recomputes the desired state
  from scratch every time. The payoff is robustness. Missed events, restarts,
  and out-of-order delivery can't corrupt the result, because nothing depends
  on having seen every event. The price is that reconcilers must be
  idempotent and must read the current state rather than trust a diff. A good
  follow-up point is that the informer cache makes "read everything every
  time" cheap enough to be practical.
]

=== `main.go`: the manager

The scaffold's `main.go` is sound but long, with comment blocks wider than
this page. Replace it with this version, which keeps every behaviour and
default and adds one option. First the imports and the _scheme_, the
registry that maps Go types to API kinds so clients can encode and decode
them:

#src("workbook/ch20/step1/cmd/main.go", region: "imports")
#src("workbook/ch20/step1/cmd/main.go", region: "scheme")

The flags are the scaffold's. Metrics are off unless you pass an address,
because serving them needs TLS and authorization, and HTTP/2 is off because
of the 2023 HTTP/2 "rapid reset" CVEs:

#src("workbook/ch20/step1/cmd/main.go", region: "flags")

The manager owns the shared cache, the clients, the metrics server, the
health endpoints and leader election:

#src("workbook/ch20/step1/cmd/main.go", region: "manager")

The metrics server authenticates every scrape with a TokenReview and
authorizes it with a SubjectAccessReview, so only identities granted `get`
on the `/metrics` URL can read it (step 8 sets one up).
`LeaderElectionReleaseOnCancel` is the one addition: when the manager stops,
it gives up the Lease at once, so a rolling update hands over in seconds
instead of waiting out the lease. It is safe only because `main` exits as
soon as the manager returns. Finally, the controller is registered and the
manager started:

#src("workbook/ch20/step1/cmd/main.go", region: "wiring")
#src("workbook/ch20/step1/cmd/main.go", region: "start")

`ctrl.SetupSignalHandler` returns a context cancelled on SIGTERM or
#kbd("Ctrl-C"), the two-stage shutdown from Chapter 4: the first signal
cancels the context and the manager drains its workers; a second one exits
immediately.

=== The kind, and a reconciler that logs

Open `api/v1alpha1/healthcheck_types.go`. The scaffold's spec has one
example field, `Foo`. Keep it for now (step 2 replaces it) and make the
file match this. The imports:

#src("workbook/ch20/step1/api/v1alpha1/healthcheck_types.go", region: "imports")

The spec and status, still the scaffold's:

#src("workbook/ch20/step1/api/v1alpha1/healthcheck_types.go", region: "spec")

The kind, and its list (Kubernetes types always come in such pairs):

#src("workbook/ch20/step1/api/v1alpha1/healthcheck_types.go", region: "kind")
#src("workbook/ch20/step1/api/v1alpha1/healthcheck_types.go", region: "list")

#goconcept(title: [Struct embedding])[
  A field with a type but no name, like `metav1.TypeMeta` in `HealthCheck`,
  is _embedded_. Its fields and methods are _promoted_: `hc.Name` means
  `hc.ObjectMeta.Name`, and `hc.GetNamespace()` is `ObjectMeta`'s method.
  That is how every Kubernetes object gets `apiVersion`, `kind` and
  `metadata` without writing them out, and how `*HealthCheck` satisfies
  `client.Object`: the methods it needs come from the embedded `ObjectMeta`.
  Embedding is composition, not inheritance. A `HealthCheck` is not an
  `ObjectMeta` and can't be passed where one is expected; you write
  `hc.ObjectMeta` for that. Java and Python programmers often reach for
  embedding to model "is-a"; in Go it means "has-a, with shortcuts".
]

#goconcept(title: [Struct tags and marker comments])[
  The backquoted string after a field is a _struct tag_: metadata that
  packages read at run time through `reflect`. `json:"spec"` tells
  `encoding/json` the field's name on the wire; `json:",inline"` (an
  apimachinery convention) flattens `TypeMeta` so `apiVersion` and `kind`
  sit at the top level. Tags are just strings: a typo such as a missing
  quote compiles, and only `go vet` notices. The comments starting with
  `// +kubebuilder:` are not Go at all. They are _markers_ that
  `controller-gen` reads from the source when you run `make manifests` and
  `make generate`: `object:root=true` asks for a `DeepCopyObject` method,
  `subresource:status` gives status its own endpoint. Change a marker and
  forget to regenerate, and the CRD silently keeps the old rule.
]

The controller is where controller-runtime calls you. For now, `Reconcile`
only logs, which is enough to see the whole loop run. Replace
`internal/controller/healthcheck_controller.go` with:

#src("workbook/ch20/step1/internal/controller/healthcheck_controller.go", region: "imports")
#src("workbook/ch20/step1/internal/controller/healthcheck_controller.go", region: "reconciler")
#src("workbook/ch20/step1/internal/controller/healthcheck_controller.go", region: "rbac")
#src("workbook/ch20/step1/internal/controller/healthcheck_controller.go", region: "reconcile")
#src("workbook/ch20/step1/internal/controller/healthcheck_controller.go", region: "setup")

`client.Client` is embedded, so the reconciler itself has `Get`, `List` and
`Status`. The RBAC markers sit next to the code that needs the permissions,
and controller-gen collects them into `config/rbac/role.yaml`.
`logf.FromContext(ctx)` returns a logger that controller-runtime has already
labelled with the controller and the object.

=== Tests against a real API server

_envtest_ starts a real `kube-apiserver` and `etcd` (downloaded by
`setup-envtest`) with no kubelet, scheduler or controller-manager, and
installs your CRDs. It tests what fakes get wrong: schema validation,
defaulting, status subresources, watches, owner references and patches.
Create `internal/controller/suite_test.go`:

#src("workbook/ch20/step1/internal/controller/suite_test.go", region: "imports")
#src("workbook/ch20/step1/internal/controller/suite_test.go", region: "vars")
#src("workbook/ch20/step1/internal/controller/suite_test.go", region: "suite")
#src("workbook/ch20/step1/internal/controller/suite_test.go", region: "helpers")

#goconcept(title: [`TestMain`])[
  If a test package defines `func TestMain(m *testing.M)`, `go test` calls
  it instead of running the tests directly. You do package-wide setup, call
  `m.Run()` to run every test, tear down, and return the exit code. Here it
  starts one API server for the whole package, which takes about two
  seconds, instead of one per test. `os.Exit` skips deferred calls, which is
  why the work lives in `runSuite` and `TestMain` only exits with its
  result. When the envtest binaries are missing, the suite still runs: tests
  that need the API server call `requireEnv` and skip with a message that
  says what to do.
]

The first test checks the plumbing: the CRD is installed and the client's
scheme knows the Go types. Create
`internal/controller/healthcheck_controller_test.go`:

#src("workbook/ch20/step1/internal/controller/healthcheck_controller_test.go", region: "imports")
#src("workbook/ch20/step1/internal/controller/healthcheck_controller_test.go", region: "served")

Last, give the scaffold's sample object a value for its one field. The
scaffold leaves `spec` empty, and the API server rejects an empty required
`spec`. `config/samples/watchtower_v1alpha1_healthcheck.yaml`:

#src("workbook/ch20/step1/config/samples/watchtower_v1alpha1_healthcheck.yaml")

#needspace(14em)
#checkpoint(step: 1, of: 8, title: [Scaffold and run])[
  Tidy the module and regenerate. `make manifests` writes the CRD into
  `config/crd/bases/` and the ClusterRole into `config/rbac/role.yaml`;
  `make generate` writes `zz_generated.deepcopy.go`. Never edit those by
  hand.
  #session(
    ("go mod tidy", "ch20/s1-tidy.txt"),
    ("make manifests generate", "ch20/s1-make.txt"),
  )
  Your Go files:
  #output("ch20/s1-tree.txt", cmd: "find . -name '*.go' -not -path './bin/*' | sort")
  Download the envtest binaries once (the suite finds them in `bin/k8s`),
  then vet, test and lint. The scaffold's own `.golangci.yml` needs a
  custom-built linter (see the table below), so point yours at the
  configuration from Chapter 1:
  #output("ch20/s1-envtest.txt", cmd: "make setup-envtest")
  #output("ch20/s1-test.txt", cmd: "go vet ./... && go test ./...")
  #output("ch20/s1-testv.txt", cmd: "go test -v ./internal/controller/")
  #output("ch20/s1-lint.txt", cmd: "golangci-lint run --config \"$LAB/platform-go/.golangci.yml\" ./...")
  Now the development loop on a real cluster. Create one with
  `kind create cluster --name watchtower` if you don't have it, install the
  CRD, and run the operator on your machine in a second terminal with
  `make run` (or `go run ./cmd`):
  #output("ch20/s1-install.txt", cmd: "make install", size: 6.2pt)
  #session(
    ("kubectl apply -f config/samples/watchtower_v1alpha1_healthcheck.yaml", "ch20/s1-apply.txt"),
    ("kubectl get healthchecks", "ch20/s1-get.txt"),
  )
  The operator's log shows the workers starting and the reconcile that the
  new object triggered:
  #output("ch20/s1-run.txt", cmd: "go run ./cmd", title: "terminal 2", size: 6.2pt)
  Stop it with #kbd("Ctrl-C") and remove the CRD with `make uninstall`.
  #troubleshoot(
    ([#ts("s1-modpath.txt")], [The module path is not `watchtower` (here `github.com/you/watchtower`), so `watchtower/...` imports match no module.], [Make the `module` line and the import paths agree.]),
    ([#ts("s1-noenvtest.txt")], [No envtest binaries in `bin/k8s`, and `KUBEBUILDER_ASSETS` unset.], [Run `make setup-envtest`, or `make test`.]),
    ([#ts("s1-scheme.txt")], [The test client was built without the package's scheme, so it can't map Go types to kinds.], [Pass `client.Options{Scheme: scheme}`, and register every API with `AddToScheme`.]),
    ([#ts("s1-nocrd.txt")], [`config/crd/bases` is missing: `make manifests` hasn't run.], [Run `make manifests`.]),
    ([#ts("s1-scaffoldlint.txt")], [Plain `golangci-lint` read the scaffold's `.golangci.yml`, which expects a custom build with the `logcheck` plugin.], [`make lint` builds that binary; or pass `--config` with the Chapter 1 file.]),
  )
]

#include "20b-operators.typ"
#include "20c-operators.typ"
