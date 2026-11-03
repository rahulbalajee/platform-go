#import "../template/book.typ": *

#chapter(20, "Building Operators with controller-runtime", label: <ch-operators>,
  abstract: [
    An operator is the way your team runs something, written down as a
    control loop the Kubernetes API server can drive. This chapter builds
    `watchtower`, a monitoring operator. You declare a `HealthCheck`, and
    the operator probes it, reports health as conditions and Prometheus
    metrics, records Events when health changes, and keeps an alert rule in
    sync with whichever monitoring stack the cluster runs: the Prometheus
    Operator, Datadog, or nothing at all.
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
    *`watchtower`*: a `HealthCheck` CRD and controller with health conditions,
    metrics and Events, plus stack-agnostic alerting. It writes
    `PrometheusRule` objects that repair themselves if edited, or Datadog
    monitors protected by a finalizer.

    #v(4pt)
    An envtest suite against a real API server, and an end-to-end script that
    deploys the operator to kind.
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

== The machinery under controller-runtime <sec-op-machinery>

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

== Scaffolding with kubebuilder <sec-op-scaffold>

kubebuilder generates the project skeleton, a Makefile wired to
`controller-gen` and `setup-envtest`, kustomize manifests, and a secure-by-
default `main.go`. These two commands created the project in the repository
(kubebuilder 4.16, targeting Kubernetes 1.37 and controller-runtime 0.25):

#terminal(```
$ kubebuilder init --domain platformgo.dev \
    --repo github.com/rahulbalajee/platform-go/projects/watchtower \
    --project-name watchtower
$ kubebuilder create api --group watchtower --version v1alpha1 \
    --kind HealthCheck --resource --controller
```)

That gives the group-version-kind `watchtower.platformgo.dev/v1alpha1,
Kind=HealthCheck`. The layout worth knowing:

#table(
  columns: (auto, 1fr),
  table.header([Path], [What it is]),
  [`api/v1alpha1/`], [Go types for the API. Comments starting with `+kubebuilder:` are _markers_ that `controller-gen` turns into the CRD schema, validation, defaults and printer columns.],
  [`internal/controller/`], [The reconciler. Its `+kubebuilder:rbac` markers generate the ClusterRole.],
  [`cmd/main.go`], [Builds the manager: metrics endpoint served with authentication and authorization, health probes, leader election, HTTP/2 disabled by default (a mitigation for the 2023 HTTP/2 rapid-reset CVEs), and our wiring.],
  [`config/`], [Kustomize bases: `crd/`, `rbac/`, `manager/`, `default/` (the deployable bundle), `prometheus/` (a ServiceMonitor), `network-policy/`, `samples/`.],
  [`Makefile`], [`make manifests generate` runs controller-gen; `make test` downloads envtest binaries and runs tests; `make deploy` applies the kustomize bundle; `make build-installer` emits a single install YAML.],
  [`zz_generated.deepcopy.go`], [Generated `DeepCopy` methods. Never edit; regenerate.],
)

The Makefile installs pinned tool versions into `./bin` with `go install`.
Go 1.24's `tool` directive in `go.mod` is an alternative for Go-based tools,
pinning them in the module graph. Either way, the point is the same: tool
versions are part of the build, not of whoever's laptop runs it. Recent
kubebuilder versions also generate an `AGENTS.md` that describes the
project's conventions for AI coding assistants. Read it once; it is a good
summary of the scaffold's rules for humans too.

== Designing the API <sec-op-api>

The CRD is the part of an operator you can't easily change later. Users write
manifests against it, GitOps repositories store them, and other tools parse
its status. Get the shape right first.

=== Spec: the user's intent

#src("projects/watchtower/api/v1alpha1/healthcheck_types.go", region: "spec")

Several conventions are at work here.

*Validation lives in the schema.* `Minimum`, `Maximum`, `Enum`, `Pattern`,
`MaxLength` and `MaxItems` become OpenAPI constraints that the API server
enforces before anything is stored, so `kubectl apply` fails immediately with
a precise message. Rules that span fields use CEL
(`x-kubernetes-validations`): "exactly one of `url` or `service`", "interval
at least 5s", "timeout shorter than interval". CEL validation has been GA
since Kubernetes 1.29. It has replaced most validating webhooks for this kind
of rule, removing a TLS-serving component from the operator. Chapter 21 covers
webhooks for the cases CEL can't handle.

*Defaults live in the schema too.* `+kubebuilder:default` values are applied
by the API server, so `kubectl get -o yaml` shows the effective spec. Users and
GitOps diff tools then see the same thing the controller acts on, and the
controller needs no defaulting code.

*Optional and zero values are explicit.* Pointers (`*AlertSpec`,
`*metav1.Duration`) distinguish "unset" from "zero". `omitzero`, the JSON tag
option added in Go 1.24, omits empty structs, which `omitempty` never did. It
is why `Expect` can be a value type here.

*Bounded everything.* Every string and list has a maximum. Unbounded fields
let one bad manifest create a multi-megabyte object, and they make CEL rules
too expensive for the API server to accept. The API server estimates the cost
of every CEL rule and rejects CRDs whose rules could be expensive on unbounded
input.

The CRD rejects invalid objects before the controller ever sees them, and a
test proves it against a real API server (@sec-op-testing):

#src("projects/watchtower/internal/controller/healthcheck_controller_test.go", region: "validation")

=== Status: the controller's observations

#src("projects/watchtower/api/v1alpha1/healthcheck_types.go", region: "status")

*Conditions are the API.* `metav1.Condition` is the standard shape: a `type`,
a `status` (`True`, `False`, `Unknown`), a CamelCase `reason` meant for
machines, a free-text `message` meant for humans, `observedGeneration`, and
`lastTransitionTime`. Standard conditions mean standard tooling works:
`kubectl wait --for=condition=Healthy`, Argo CD health checks, and generic
dashboards. `+listType=map` with `+listMapKey=type` tells the API server and
server-side apply that conditions are keyed by type.

*`observedGeneration` closes the loop.* `metadata.generation` increments on
every spec change. When `status.observedGeneration` equals it, the status
describes the current spec, not an older one. CI pipelines and GitOps tools
rely on this to know when a change has been fully processed.

*Status is designed for write economy.* This is the decision that most
separates a production operator from a tutorial. Every status write is an API
call, an etcd write, and a watch event fanned out to every client watching the
resource. A status that changes on every probe, with a `lastProbeTime` or a
`latencyMillis` field, turns 1,000 checks at a 30-second interval into 33
writes per second of pure churn. `watchtower`'s status only changes when
something a human cares about changes:

- No timestamps except the conditions' `lastTransitionTime`, which only moves
  when status flips.
- No latency. Latency belongs in metrics (@sec-op-metrics), which are built for
  high-frequency numeric data.
- `consecutiveFailures` _saturates_ at `failureThreshold`. During a long
  outage it stops changing, and the condition's `lastTransitionTime` already
  says how long the check has been failing.
- Messages contain no measurements. "unexpected status 503" is stable;
  "503 after 1.2s" would change on every probe.

The result: a steadily healthy check, or a steadily failing one, costs zero API
writes per probe.

=== The kind

#src("projects/watchtower/api/v1alpha1/healthcheck_types.go", region: "kind")

`+kubebuilder:subresource:status` gives status its own endpoint
(`/status`). Users with permission to edit HealthChecks can't forge status,
the controller can't accidentally change the spec while writing status, and
spec updates don't conflict with status updates. The printer columns make
`kubectl get healthchecks` (or `kubectl get hc`, the short name) useful
without `-o yaml`. The resolved target URL is long, so its column has
`priority=1`: like a Pod's IP and node, it appears only with `-o wide`, and
the default view fits an 80-column terminal. `categories=watchtower` makes
`kubectl get watchtower` list every kind the operator owns.

Here is a check as a user writes it:

#src("projects/watchtower/config/samples/demo.yaml", region: "storefront")

After `make manifests`, controller-gen turns all of this into a 300-line
CRD with the schema, the CEL rules, the defaults and the printer columns. You
never edit that file by hand.

== The reconcile loop <sec-op-reconcile>

The reconciler's dependencies are all interfaces or plain values, injected in
`main`. That is what lets the same code run in the cluster, in envtest, and in
unit tests with fakes:

#src("projects/watchtower/internal/controller/healthcheck_controller.go", region: "reconciler")

The RBAC markers sit next to the code that needs the permissions, and
controller-gen collects them into `config/rbac/role.yaml`. Note
`healthchecks/status` and `healthchecks/finalizers` as separate resources,
and `events.k8s.io` rather than the legacy core `events`, since the operator
uses the newer events API.

#src("projects/watchtower/internal/controller/healthcheck_controller.go", region: "reconcile")

Read it as a sequence of decisions, each of which is safe to repeat:

+ *Fetch, and treat "not found" as success.* The object may have been deleted
  after the event was queued. There is nothing to do except drop its metric
  series. Returning an error would retry a deletion forever.
+ *Handle deletion first.* A `deletionTimestamp` means Kubernetes is waiting on
  our finalizer (@sec-op-external).
+ *Add the finalizer before creating anything external.* If the order were
  reversed, a crash or a delete between "create Datadog monitor" and "add
  finalizer" would leave a monitor no one will ever clean up.
+ *Compute the desired status on a copy.* `base` is the object as read;
  `reconcileHealth` and `reconcileAlerting` mutate `hc.Status`.
+ *Write only if something changed.* `equality.Semantic.DeepEqual` compares
  Kubernetes types correctly (for example, resource quantities by value).
  `client.MergeFrom(base)` sends a JSON merge patch containing only the
  difference, without a `resourceVersion` precondition. That is safe because
  this controller is the only writer of this status. If several writers
  shared a field, you would use `client.MergeFromWithOptions(base,
  client.MergeFromWithOptimisticLock{})` and handle conflicts.
+ *Schedule the next reconcile.* `reconcileHealth` returns the delay: the
  interval with ±10% jitter after a probe, or the remainder of the interval
  when the reconcile was triggered early (@sec-op-health). Without jitter,
  500 checks created by one `kubectl apply` would probe in lockstep forever,
  producing a synchronized spike every interval.

#warning(title: [`Requeue` versus `RequeueAfter` versus returning an error])[
  Return an error when the reconcile _failed_ and should be retried with
  backoff: an API conflict, a 500 from Datadog during cleanup. Return
  `RequeueAfter` when the work _succeeded_ and must simply happen again later,
  like the next probe. Don't return an error to get periodic behaviour: errors
  increment `controller_runtime_reconcile_errors_total`, feed the exponential
  backoff (so the period grows to minutes), and log stack traces for
  something that isn't an error.
]

== Probing and the health state machine <sec-op-health>

#src("projects/watchtower/internal/controller/healthcheck_controller.go", region: "health")

The prober is a small interface (`Probe(ctx, Spec) Result`) whose HTTP
implementation knows nothing about Kubernetes. Service targets resolve to the
Service's cluster DNS name, `name.namespace.svc.cluster.local`, after the
controller confirms through the cache that the Service and port exist. A
missing Service gets the precise reason `TargetUnresolved` instead of a
confusing DNS error.

=== Not every reconcile is a timer tick

The first version of this function probed on every reconcile, and the unit
tests and envtest suite all passed. The end-to-end run on kind caught the
bug. The `payments-api` check, configured with a 10-second interval and a
failure threshold of 3, went unhealthy _10 seconds_ after creation instead of
roughly 30. The creation event triggered a reconcile and a probe. Creating
its PrometheusRule triggered a second reconcile through the `Owns` watch, and
server-side apply's follow-up update triggered a third. Three probes, three
failures, threshold reached.

Reconciles arrive for many reasons: the requeue timer, the object's own spec
changes, owned objects changing, mapped Service events, and periodic cache
resyncs. A reconciler that does expensive or time-sensitive work on _every_
call has to decide whether that work is actually due. `untilDue` records the
time and generation of the last probe in memory. A reconcile arriving less
than half an interval after the last probe skips probing and requeues for the
remainder of the interval, keeping the cadence. A new generation, meaning the
user changed the spec, always probes immediately. The record is deliberately
not persisted. Writing it to status would bring back the per-probe churn the
status design avoids, and losing it on a restart costs at most one early
probe. The regression test drives `Reconcile` directly:

#src("projects/watchtower/internal/controller/healthcheck_controller_test.go", region: "cadencetest")

=== The state machine

#fig(placement: auto, caption: [The `Healthy` condition. Failures below `failureThreshold` are absorbed; Events fire only on the two transitions that a human cares about.])[
  #diagram(
    spacing: (46pt, 58pt),
    dnode((1, 0), [*Unknown*\ Pending · first failures], kind: "muted"),
    dnode((0, 1), [*True*\ ProbeSucceeded], kind: "good"),
    dnode((2, 1), [*False*\ ProbeFailing\ counter saturated], kind: "warn"),
    dedge((1, 0), (0, 1), "-|>", label: [success], label-side: right),
    dedge((1, 0), (2, 1), "-|>", label: [n ≥ threshold], label-side: left),
    dedge((0, 1), (2, 1), "-|>", label: [n ≥ threshold\ Event: ProbeFailing], bend: -16deg),
    dedge((2, 1), (0, 1), "-|>", label: [success\ Event: Recovered], bend: -16deg),
    dedge((0, 1), (0, 1), "-|>", label: [blip < threshold], bend: 130deg, loop-angle: 180deg),
  )
] <fig-health-sm>

How a probe result changes the status (@fig-health-sm) is a pure function,
which makes the heart of the operator testable without any Kubernetes at all:

#src("projects/watchtower/internal/controller/status.go", region: "apply")

A table-driven test walks the machine through a realistic sequence: an early
failure, a recovery, absorbed blips, crossing the threshold, saturation, and
recovery again:

#src("projects/watchtower/internal/controller/status_test.go", region: "statetest")

Testing the logic as a pure function also makes the rest of the testing
strategy cheaper. The envtest suite only needs to prove the _wiring_ (that
statuses are written, events are emitted, rules appear), not every edge of the
state machine.

== Watching the right things <sec-op-watches>

What a controller watches decides how quickly it reacts and how much work it
does for nothing.

#src("projects/watchtower/internal/controller/healthcheck_controller.go", region: "setup")

*`GenerationChangedPredicate` on the primary resource.* Every status patch
the controller makes is itself an update event on the HealthCheck. Without a
predicate, each status change would immediately trigger another reconcile of
the same object. Generation only changes on spec updates (and on deletion),
so filtering on it means "reconcile when the user changes something". The
periodic `RequeueAfter` drives everything else, and the cadence gate from
@sec-op-health stops the remaining triggers from causing early probes.

*A secondary watch on Services, mapped through a field index.* A HealthCheck
targeting a Service that doesn't exist yet reports `TargetUnresolved`. When
the Service is created, we want the check to resolve now, not after the next
interval. `Watches(&corev1.Service{}, handler.EnqueueRequestsFromMapFunc(...))`
turns each Service event into reconcile requests for the HealthChecks that
target it. The map function has to find those checks efficiently, so
`IndexField` registers an index on the informer cache keyed by
`.spec.target.service.name`, and the lookup becomes an indexed cache read:

#code(file: "projects/watchtower/internal/controller/healthcheck_controller.go")[```go
var list v1alpha1.HealthCheckList
err := r.List(ctx, &list, client.InNamespace(svc.GetNamespace()),
	client.MatchingFields{serviceNameField: svc.GetName()})
```]

A predicate on the Service watch passes only creates, deletes and port
changes. Services are updated far more often than that (annotations,
load-balancer status, managed fields), and none of those updates affect
resolution.

*`Owns` for the rules we create.* Every PrometheusRule we write carries a
controller owner reference to its HealthCheck. `Owns` watches PrometheusRules
and enqueues the _owner_ when one changes or disappears. That is the
mechanism behind self-healing in the next section. It is added only when the
PrometheusRule CRD exists at startup, because a watch on a kind the API server
doesn't know would stop the whole manager from starting.

#production(title: [What the cache costs you])[
  Each `For`, `Owns` and `Watches` starts an informer that lists and then
  watches _every_ object of that kind the operator can see. Watching Services
  cluster-wide means holding every Service in memory, which is modest, but the
  same line written for Pods or Secrets in a 5,000-node cluster can mean
  gigabytes. Tools for keeping it under control, covered in Chapter 21:
  restrict namespaces (`cache.Options.DefaultNamespaces`), select by label
  (`ByObject` with a label selector), transform objects before they are
  cached (strip `managedFields` and annotations you don't read), or watch
  metadata only (`WatchesMetadata`) when you only need names and labels.
]

== Owned resources and server-side apply <sec-op-owned>

For clusters running the Prometheus Operator, `watchtower` generates one
`PrometheusRule` per HealthCheck. Rendering it is plain data construction:

#src("projects/watchtower/internal/alerting/prometheus.go", region: "render")

Three decisions are worth defending in a design review.

*Unstructured instead of typed.* Importing the Prometheus Operator's Go
module would pull a large dependency tree into the operator and tie our
release cadence to theirs, for one object we write. `unstructured.Unstructured`
plus a `GroupVersionKind` keeps `watchtower` independent of it and lets the
same binary run in clusters without the CRD. The cost is losing compile-time
checking of the rule's shape, which `TestPrometheusRuleRender` covers.

*A controller owner reference.* `SetControllerReference` records the
HealthCheck as the rule's owner, with `controller: true` and
`blockOwnerDeletion: true`. When the HealthCheck is deleted, the garbage
collector in kube-controller-manager deletes the rule, with no finalizer and no
cleanup code. Owner references only work within a namespace (or from
cluster-scoped owners), which is why the rule lives next to its check.

*Metric labels that survive scraping.* The alert expression selects on
`check_namespace` and `check_name`, not `namespace` and `name`. When
Prometheus scrapes the operator's metrics endpoint, it attaches the operator
pod's own `namespace` target label. A metric label with the same name is
renamed to `exported_namespace` unless the scrape config sets
`honorLabels: true`. Alerts written against `namespace` then silently match
nothing. Prefixing the labels avoids the collision entirely.

Applying the rule is where server-side apply comes in:

#src("projects/watchtower/internal/alerting/prometheus.go", region: "ensure")

The read comes from the informer cache, so in steady state, where the rule
exists and matches, `Ensure` makes no API calls at all, and it runs on every
reconcile without cost. When the rule is missing or different, the controller
applies it.

*Server-side apply* (`client.Apply` with a field owner) sends the fields we
want to own, and the API server merges them, tracking ownership per field in
`managedFields`. It removes the read-modify-write race of `Update`, and it
plays well with other actors. If a policy engine adds a label to our rule, we
don't erase it, because we never claimed that field. `ForceOwnership` says
that when another manager has taken over a field we declare (someone ran
`kubectl edit` on the alert expression), we take it back. For a generated
object that is the right call: the HealthCheck is the source of truth.
controller-runtime's `client.Client.Apply` takes an apply configuration, and
`client.ApplyConfigurationFromUnstructured` adapts unstructured objects to it.
The older `client.Patch(ctx, obj, client.Apply)` form is deprecated in 0.25.

The combination is a _self-healing_ loop. A human deletes or edits the
generated rule, the `Owns` watch enqueues the owning HealthCheck, `Ensure`
sees the difference in the cache, and the rule is restored within a second or
two. You will see exactly that on a real cluster in @sec-op-testing.

== External resources, finalizers, and idempotency <sec-op-external>

Not every cluster runs Prometheus. The alerting layer is an interface, chosen
once at startup with `--alert-backend`:

#src("projects/watchtower/internal/alerting/alerting.go", region: "backend")

The `External` method carries the key distinction. A PrometheusRule lives in
the cluster, so owner references and garbage collection handle its lifecycle.
A Datadog monitor lives in someone else's API. Kubernetes knows nothing about
it, and deleting the HealthCheck would orphan the monitor forever unless the
operator deletes it first. _Finalizers_ exist for exactly this.

=== Finalizers

A finalizer is a string in `metadata.finalizers`. While the list is non-empty,
a delete request only sets `deletionTimestamp`; the object stays in the API,
visible and updatable, until every finalizer is removed. The controller sees
the deletion as an ordinary update, does its cleanup, removes its finalizer,
and only then does the object disappear:

#src("projects/watchtower/internal/controller/healthcheck_controller.go", region: "finalize")

The rules for finalizers are strict:

- Add it _before_ creating the external resource, as `Reconcile` does.
- Name it after your domain (`watchtower.platformgo.dev/alert-cleanup`) and
  remove only your own.
- Cleanup must be idempotent and must treat "already gone" as success.
  `Remove` on a monitor that returns 404 succeeds.
- Failure blocks deletion, and that is the point. The error return retries with
  backoff and the `CleanupFailed` Event tells the user why the object is
  stuck. Namespace deletion waits on it too, which is how a broken operator
  produces namespaces stuck in `Terminating`.
- Document the escape hatch: if the external system is gone for good, an
  administrator can remove the finalizer by hand
  (`kubectl patch hc NAME --type=merge -p '{"metadata":{"finalizers":null}}'`)
  and clean up the external side manually.

=== Idempotency against an external API

Kubernetes gives in-cluster resources idempotent creation for free: names are
unique, and apply is declarative. Most external APIs offer neither, so the
operator has to build idempotency itself:

#src("projects/watchtower/internal/alerting/datadog.go", region: "ddensure")

Consider the failure the UID tag defends against. The operator creates the
monitor, and then the status patch recording its ID fails: a conflict, a
network blip, or the pod being rescheduled. The next reconcile sees no ID in
status. A naive implementation creates a second monitor, and you now have
duplicate pages for every incident. Tagging every monitor with the
HealthCheck's UID, which never changes for the object's lifetime and is never
reused, gives the operator a lookup key that works even when its own records
are lost. The test for it simulates exactly that crash:

#src("projects/watchtower/internal/alerting/datadog_test.go", region: "ddtest")

The fake is a tiny in-memory implementation of the documented Monitors API
(`GET`, `POST`, `PUT` and `DELETE` on `/api/v1/monitor`, with the
`DD-API-KEY` and `DD-APPLICATION-KEY` headers), packaged as `ddfake` in the
style of `httptest` so the controller tests can use it as well. Run the
backend against a real Datadog organization before you trust it in
production: fakes encode your _understanding_ of an API, and the point of the
fake is to test your logic against that understanding quickly and
deterministically.

#production(title: [Generation-gated external sync])[
  `reconcileAlerting` skips external backends when the current generation has
  already been synced and `AlertingReady` is true. Datadog's API is
  rate-limited per organization, and 2,000 checks re-asserting their monitors
  every 30 seconds would burn through that limit for no benefit. The
  trade-off is that edits made in the Datadog UI aren't reverted until the
  spec changes. Exercise 3 adds a slow periodic drift check, the usual
  compromise. In-cluster rules don't need the gate, because the comparison
  against the cache is free.
]

== Metrics, Events, and RBAC <sec-op-metrics>

#src("projects/watchtower/internal/controller/metrics.go", region: "metrics")

Metrics registered with controller-runtime's registry are served on the
manager's metrics endpoint, next to the built-in series for every controller:
`controller_runtime_reconcile_total`, `controller_runtime_reconcile_errors_total`,
`controller_runtime_reconcile_time_seconds`, `workqueue_depth`,
`workqueue_queue_duration_seconds`, and client-go request metrics. Those
built-ins are how you operate the operator. A growing `workqueue_depth`
means the workers can't keep up (@sec-op-capacity).

Two habits matter. Label cardinality is bounded by the number of
HealthCheck objects, never by anything unbounded such as URLs, error
messages or status codes. And `forget` deletes a check's series when the check
is deleted. Otherwise the last value, `up = 0` for a check deleted while
failing, is exported forever, and the alert for a check that no longer exists
can never resolve.

Events are the human-facing record: `kubectl describe` shows them and
`kubectl get events` lists them. `watchtower` emits Events only on
transitions (`ProbeFailing` and `Recovered`) and on cleanup failure. Events on
every probe would be noise, and the API server rate-limits event writes per
source. The recorder comes from `mgr.GetEventRecorder("watchtower")`, the
`events.k8s.io/v1` API. controller-runtime 0.25 deprecates
`GetEventRecorderFor`, which writes the legacy core `v1` Events.

The RBAC markers produce this ClusterRole, which is the operator's entire
privilege set:

#code(file: "projects/watchtower/config/rbac/role.yaml (excerpt)")[```yaml
- apiGroups: [""]
  resources: [services]
  verbs: [get, list, watch]
- apiGroups: [events.k8s.io]
  resources: [events]
  verbs: [create, patch]
- apiGroups: [monitoring.coreos.com]
  resources: [prometheusrules]
  verbs: [create, delete, get, list, patch, update, watch]
- apiGroups: [watchtower.platformgo.dev]
  resources: [healthchecks]
  verbs: [get, list, patch, update, watch]
- apiGroups: [watchtower.platformgo.dev]
  resources: [healthchecks/status]
  verbs: [get, patch, update]
- apiGroups: [watchtower.platformgo.dev]
  resources: [healthchecks/finalizers]
  verbs: [update]
```]

Notice what is absent: no Secrets, no Pods, no wildcards. Datadog credentials
reach the process as environment variables from a Secret mounted by the
Deployment, so the operator never needs permission to _read_ Secrets through
the API. Chapter 31 goes further, with namespace-scoped Roles for multi-tenant
clusters and auditing what an operator actually uses.

== Wiring it together <sec-op-main>

`main.go` keeps the scaffold's secure defaults (authenticated metrics, health
probes, leader election, HTTP/2 off) and adds the backend selection:

#src("projects/watchtower/cmd/main.go", region: "backend")

#src("projects/watchtower/cmd/main.go", region: "wiring")

The `RESTMapping` lookup is a discovery call: it asks the API server whether
`monitoring.coreos.com/v1 PrometheusRule` exists. If it doesn't, the operator
still starts. Probing and metrics work, and every check reports
`AlertingReady=False` with reason `BackendUnavailable` and a message saying
what to install. Degrading with a clear explanation, rather than
crash-looping, is the behaviour that lets a platform team ship one operator
build to every cluster.

== Testing: unit, envtest, and a real cluster <sec-op-testing>

The test pyramid for an operator has three layers, and `watchtower` has all
of them.

*Unit tests* cover the prober, the state machine, rule rendering and the
Datadog backend, all without Kubernetes. They run in milliseconds and cover
most of the logic.

*envtest* starts a real `kube-apiserver` and `etcd` (downloaded by
`setup-envtest`) with no kubelet, scheduler or controller-manager, installs
the CRDs, and runs the controller in a manager exactly as `main` does. It
tests the things fakes get wrong: schema validation and CEL, defaulting,
status subresources, watches, owner references, field indexes, and the real
behaviour of patches. Kubebuilder scaffolds this with Ginkgo; `watchtower`
uses the standard `testing` package with a `TestMain`, which works the same
way:

#src("projects/watchtower/internal/controller/suite_test.go", region: "suite")

Two details make the suite robust. The manager's cache is restricted to one
namespace, so tests that call `Reconcile` by hand can use another namespace
without the running controller interfering. And a small prober wrapper
answers for `*.svc.cluster.local` URLs, since envtest has no cluster DNS.
Everything else, including the HTTP probes to an `httptest` server, is real.

The lifecycle test drives the whole loop: healthy, broken, an Event, a rule
deleted by hand and restored, and alerting turned off:

#src("projects/watchtower/internal/controller/healthcheck_controller_test.go", region: "lifecycle")

The finalizer test calls `Reconcile` directly, step by step, so it can assert
on the intermediate states: the finalizer is present, only one monitor exists
after three reconciles, the object lingers with a `deletionTimestamp`, and it
disappears only after cleanup:

#src("projects/watchtower/internal/controller/healthcheck_controller_test.go", region: "finalizertest")

#output("wt/make-test.txt", cmd: "make test")

#warning(title: [envtest has no garbage collector])[
  There is no kube-controller-manager in envtest, so owner references are
  recorded but nothing acts on them. Deleting a HealthCheck in a test does
  _not_ delete its PrometheusRule. Test that the owner reference is set
  correctly and trust Kubernetes to do the collection, or run that scenario on
  kind. This gap caught a real bug while writing the chapter: a rule left over
  from a deleted-and-recreated HealthCheck still pointed at the old UID, and
  `Ensure` considered it up to date. `upToDate` now also compares the
  controller reference.
]

=== End to end on kind

The last layer runs the real image in a real cluster. `hack/e2e-kind.sh`
creates a kind cluster and installs the Prometheus Operator's actual
PrometheusRule CRD (with server-side apply, because the CRD is too large for
client-side apply's annotation). It then cross-compiles the operator and a
tiny demo service on the host, packages each into a `FROM scratch` image (the
approach `ko` takes, with no base images to pull and rebuilds in seconds),
loads them into kind, deploys with kustomize, applies a demo namespace, and
waits on conditions with `kubectl wait`. Release images still come from the
scaffold's multi-stage Dockerfile. The output below was captured from the
script against Kubernetes 1.36.

The demo has four checks: a Service in the cluster backed by the demo app,
`go.dev`, an endpoint that always returns 503, and a check whose Service
doesn't exist yet:

#output("wt/get-hc.txt", cmd: "kubectl get healthchecks -n shop")

#output("wt/describe-payments.txt", cmd: "kubectl describe hc payments-api -n shop")

The printer columns tell the story at a glance, and `describe` shows the
conditions with their reasons, the saturated failure counter, and the
`ProbeFailing` Event emitted exactly once on the transition. The generated
rules, one per alerting check:

#output("wt/get-rules.txt", cmd: "kubectl get prometheusrules -n shop")

The full object shows everything from @sec-op-owned at once: the
`managed-by` label, the controller owner reference with
`blockOwnerDeletion`, and the alert expression rendered as a YAML block,
because `Render` deliberately puts newlines in it:

#output("wt/rule-yaml.txt", cmd: "kubectl get prometheusrule watchtower-storefront -n shop -o yaml")

Deleting a generated rule by hand brings it back within seconds, through the
`Owns` watch. Its age gives it away:

#session(
  ("kubectl delete prometheusrule watchtower-storefront -n shop", "wt/rule-deleted.txt"),
  ("sleep 3", none),
  ("kubectl get prometheusrule watchtower-storefront -n shop", "wt/rule-restored.txt"),
)

Creating the missing `inventory` Service resolves the check immediately
through the Service watch, without waiting for its interval. The first probe
may still fail while the new Service's endpoints are programmed; that is a
blip below the threshold, and the next probe succeeds:

#session(
  ("cols='NAME:.metadata.name,TARGET:.status.resolvedURL'", none),
  ("cols+=',REASON:.status.conditions[?(@.type==\"Healthy\")].reason'", none),
  ("kubectl get hc inventory -n shop -o custom-columns=\"$cols\"", "wt/resolved-inventory.txt"),
)
#output("wt/get-hc-after.txt", cmd: "kubectl get healthchecks -n shop   # one interval later")

The operator's Events record each transition exactly once:

#output("wt/events.txt", cmd: "kubectl get events -n shop --field-selector reportingComponent=watchtower \\\n  -o custom-columns='REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message'")

And the operator's own metrics, read through the authenticated metrics
endpoint with a ServiceAccount token:

#output("wt/metrics.txt", cmd: "curl -sk -H \"Authorization: Bearer $TOKEN\" https://localhost:8443/metrics \\\n  | grep -E '^watchtower_healthcheck_(up|probes_total)' | sort", size: 6.4pt)

== Capacity and failure modes <sec-op-capacity>

Before an operator goes to production, someone should do the arithmetic.

*Probes hold workers.* `watchtower` probes inside `Reconcile`, so each probe
occupies one of `MaxConcurrentReconciles` workers for up to its timeout. With
16 workers and a 5-second timeout, the worst case, where every target is
timing out, is 3.2 probes per second, or 96 checks per 30-second interval.
Beyond that, `workqueue_depth` grows and probes run late. Healthy targets
answer in milliseconds, so the typical capacity is far higher, but capacity
plans are built on the worst case, because that is when you need the
monitoring most. The levers are more workers (cheap, since probes are
network-bound), shorter timeouts, or the architectural fix in Chapter 21: a
dedicated prober pool that runs as a `manager.Runnable`, with results fed back
to the reconciler as events from a `source.Channel`.

*API write budget.* Thanks to the status design, writes happen only on
transitions. Even a cluster-wide outage, with every check failing at once,
produces one burst of status writes and Events, then silence.

*When the operator is down, nothing probes.* The HealthChecks keep their last
status, which goes stale, and the `watchtower_healthcheck_up` series
disappear: when scrapes of the operator fail, Prometheus marks its series
stale. An alert expression comparing `== 0` does _not_ fire on a series that
no longer exists, so every generated rule goes quiet at exactly the moment you
have lost visibility. Pair the generated rules with an alert on the operator
itself, such as `absent(up{job="watchtower"} == 1)`. Monitor the monitor.

*Leader election makes it highly available, not parallel.* With
`--leader-elect` and two replicas, one is active and the other waits on a
Lease. Failover takes a few seconds (the lease duration), during which no
probes run. Sharding work across replicas is a Chapter 21 topic.

#interview(title: [“Walk me through an operator you built.”])[
  Use `watchtower` as the spine and spend your time on decisions, not on the
  API. Status design for write economy (saturating counters, no timestamps,
  stable messages). Owned versus external resources (owner references and
  garbage collection versus finalizers with UID-tagged idempotency).
  Server-side apply and what `ForceOwnership` means. Why
  `GenerationChangedPredicate`, why a field-indexed Service watch, and the
  capacity math on reconcile workers. Then testing: a pure state machine,
  envtest for the API-server-dependent behaviour, and kind for the image.
  Interviewers for platform roles are listening for whether you understand
  what your controller costs the API server and what happens when things
  fail.
]

#takeaways(
  [Write an operator when domain knowledge must run continuously against declarative state that already lives in Kubernetes. Otherwise prefer a CLI, a Job, or a chart.],
  [controller-runtime is level-triggered: the queue holds keys, reads come from an eventually consistent cache, and reconcilers must be idempotent.],
  [Put validation and defaults in the CRD schema with markers and CEL; it is enforced before your code runs.],
  [Design status for write economy: conditions, `observedGeneration`, stable messages, no per-probe timestamps. Metrics carry the high-frequency data.],
  [Write status only when it changed, filter your own writes with `GenerationChangedPredicate`, and jitter periodic requeues.],
  [Reconciles arrive for many reasons besides the timer. Gate expensive or time-sensitive work on whether it is actually due.],
  [Owned in-cluster objects: controller owner references, server-side apply with a field owner, cache comparison, and an `Owns` watch for self-healing.],
  [External objects: add the finalizer first, make creation idempotent with a stable key such as the object UID, treat "already gone" as success, and gate expensive syncs on generation.],
  [Test in three layers: pure logic, envtest for API semantics, kind for the deployable artifact.],
)

#exercises(
  [*Webhook-free immutability.* Make `spec.target` immutable once set using a CEL transition rule (`self == oldSelf`). Add a test case to `TestCRDValidationRejectsBadSpecs`. Why would you want this for a monitoring resource, and what would users do instead of editing the target?],
  [*A second backend.* Implement a `grafana` backend that manages Grafana-managed alert rules through Grafana's alerting provisioning API, with a fake in the style of `ddfake`. Decide whether it is `External`, and justify the decision.],
  [*Drift detection.* Datadog monitors are synced only when the generation changes. Add a configurable drift interval: re-assert external rules if `AlertingReady`'s `lastTransitionTime` is older than, say, 30 minutes. Use a fake clock or `synctest` to test it without waiting.],
  [*Orphan cleanup.* Switching `--alert-backend` from `datadog` to `prometheus` leaves finalizers that the new backend will "clean up" by doing nothing, orphaning the monitors. Design a migration: record the backend name in the finalizer string, and make `finalize` refuse to remove a finalizer belonging to a backend it can't reach.],
  [*Capacity test.* Create 500 HealthChecks against a slow fake target in envtest and plot `workqueue_depth` and probe lateness for 4, 16 and 64 workers. Where does it stop scaling, and what is the bottleneck?],
)
