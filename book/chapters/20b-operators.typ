#import "../template/book.typ": *

#let ts(name) = quote-output("ch20/ts/" + name)
#let wb = "workbook/ch20/"

#step(2, 8, "The API", label: <sec-op-api>)

The CRD is the part of an operator you can't easily change later. Users write
manifests against it, GitOps repositories store them, and other tools parse
its status. Get the shape right first. This step replaces the scaffold's
`Foo` with the real spec and status, and proves the validation rules against
a real API server before any controller logic exists.

=== Spec: the user's intent

Replace the `spec` region of `api/v1alpha1/healthcheck_types.go` (the
`HealthCheckSpec` type) with:

#src("workbook/ch20/step2/api/v1alpha1/healthcheck_types.go", region: "spec")

Add the target and the expectations below it:

#src("workbook/ch20/step2/api/v1alpha1/healthcheck_types.go", region: "target")
#src("workbook/ch20/step2/api/v1alpha1/healthcheck_types.go", region: "expect")

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

*Bounded everything.* Every string and list has a maximum. Unbounded fields
let one bad manifest create a multi-megabyte object, and they make CEL rules
too expensive for the API server to accept: it estimates the cost of every
rule and rejects CRDs whose rules could be expensive on unbounded input.

#goconcept(title: [Pointer fields for optional values])[
  In Go every type has a zero value: `0`, `""`, a struct of zeros. So a
  plain `int32` field can't tell "the user wrote 0" from "the user wrote
  nothing". A pointer can: `nil` means absent. That is why `Alert *AlertSpec` and `MaxLatency *metav1.Duration` are pointers. Code must
  check before using them (`if hc.Spec.Alert != nil`), and reading through a
  nil pointer panics, which is the most common crash in operator code.
  `Expect` doesn't need a pointer: an empty `Expectations` already means
  "no extra requirements". Python's `None` and Java's `null` play the same
  role, but in Go only pointer, slice, map, channel, function and interface
  types can be `nil`.
]

#newingo("1.24", title: [`omitzero`])[
  The JSON tag option `omitzero` omits a field whose value is the zero value
  of its type, including empty structs, which `omitempty` never did. It is
  why `Interval`, a `metav1.Duration` struct, can be a value type and still
  disappear from the JSON when unset, letting the schema default apply.
]

=== Status: the controller's observations

Replace the scaffold's `HealthCheckStatus` with the condition types and
reasons and the real status:

#src("workbook/ch20/step2/api/v1alpha1/healthcheck_types.go", region: "conditions")
#src("workbook/ch20/step2/api/v1alpha1/healthcheck_types.go", region: "status")

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
- No latency. Latency belongs in metrics (step 4), which are built for
  high-frequency numeric data.
- `consecutiveFailures` _saturates_ at `failureThreshold`. During a long
  outage it stops changing, and the condition's `lastTransitionTime` already
  says how long the check has been failing.
- Messages contain no measurements. "unexpected status 503" is stable;
  "503 after 1.2s" would change on every probe.

The result: a steadily healthy check, or a steadily failing one, costs zero API
writes per probe.

=== The kind

Replace the markers above `type HealthCheck struct`:

#src("workbook/ch20/step2/api/v1alpha1/healthcheck_types.go", region: "kind")

`+kubebuilder:subresource:status` gives status its own endpoint
(`/status`). Users with permission to edit HealthChecks can't forge status,
the controller can't accidentally change the spec while writing status, and
spec updates don't conflict with status updates. The printer columns make
`kubectl get healthchecks` (or `kubectl get hc`, the short name) useful
without `-o yaml`. The resolved target URL is long, so its column has
`priority=1`: like a Pod's IP and node, it appears only with `-o wide`, and
the default view fits an 80-column terminal. `categories=watchtower` makes
`kubectl get watchtower` list every kind the operator owns.

The sample becomes a real check.
`config/samples/watchtower_v1alpha1_healthcheck.yaml`:

#src("workbook/ch20/step2/config/samples/watchtower_v1alpha1_healthcheck.yaml")

After `make manifests`, controller-gen turns all of this into a CRD of about
300 lines with the schema, the CEL rules, the defaults and the printer
columns. You never edit that file by hand.

=== Proving the schema

The CRD rejects invalid objects before the controller ever sees them, and
the API server applies defaults. Tests prove both against envtest. Replace
the imports of `healthcheck_controller_test.go` and add a helper that builds
a check with short timings:

#src("workbook/ch20/step2/internal/controller/healthcheck_controller_test.go", region: "imports")
#src("workbook/ch20/step2/internal/controller/healthcheck_controller_test.go", region: "newcheck")

#newingo("1.27", title: [Promoted fields in struct literals])[
  A key in a struct literal may now be any valid field selector, not just a
  top-level field. `HealthCheck{Namespace: ns, Name: name}` sets fields of
  the embedded `ObjectMeta`; before Go 1.27 you had to write
  `ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name}`. Every Kubernetes
  object literal in this chapter uses the short form.
]

Then the two tests. Each table entry breaks one rule and names the message
the API server must answer with:

#src("workbook/ch20/step2/internal/controller/healthcheck_controller_test.go", region: "validation")
#src("workbook/ch20/step2/internal/controller/healthcheck_controller_test.go", region: "defaults")

#needspace(14em)
#checkpoint(step: 2, of: 8, title: [The API])[
  Regenerate, then look at what the CEL markers became in the CRD:
  #output("ch20/s2-make.txt", cmd: "make manifests generate", size: 6.2pt)
  #output("ch20/s2-cel.txt", cmd: "grep -B1 -A2 'rule:' config/crd/bases/watchtower.platformgo.dev_healthchecks.yaml", size: 6.4pt)
  #output("ch20/s2-test.txt", cmd: "go vet ./... && go test ./...")
  #output("ch20/s2-testv.txt", cmd: "go test -v -run 'CRD' ./internal/controller/ | grep -v '^=== RUN'")
  #output("ch20/s2-lint.txt", cmd: "golangci-lint run --config \"$LAB/platform-go/.golangci.yml\" ./...")
  #troubleshoot(
    ([#ts("s2-stale.txt")], [The markers changed but the CRD in `config/crd/bases` is the old one: envtest installs the file, not your Go types.], [Run `make manifests` after every marker change.]),
    ([#ts("s2-celtypo.txt")], [A CEL rule names a field that doesn't exist (here `self.uri`). controller-gen copies rules verbatim; the API server compiles them when the CRD is installed.], [Fix the rule; field names are the JSON names.]),
    ([#ts("s2-noroot.txt")], [`+kubebuilder:object:root=true` is missing above `HealthCheckList`, so `make generate` wrote no `DeepCopyObject` for it.], [Restore the marker and regenerate.]),
    ([#ts("s2-tag.txt")], [A struct tag with a missing quote. It compiles; only `go vet` notices, and `encoding/json` would ignore the tag.], [Fix the quoting. See "Struct tags and marker comments".]),
  )
]

#step(3, 8, "Probe and report", label: <sec-op-reconcile>)

Now the operator does its job: probe the target, decide whether it is
healthy, and write that down in status. Three pieces arrive: a prober that
knows nothing about Kubernetes, a pure function that turns probe results
into status, and the reconciler that connects them.

=== The prober

Create `internal/probe/probe.go`. The types first:

#src("workbook/ch20/step3/internal/probe/probe.go", region: "types")

#goconcept(title: [Interfaces and function adapters])[
  An interface lists methods; any type with those methods satisfies it, with
  no `implements` keyword. `Prober` has one method, so the reconciler can be
  given the real `HTTP` prober in `main` and a three-line fake in tests.
  `ProberFunc` is the adapter trick from `net/http`'s `HandlerFunc`: a
  function type with a method that calls the function itself, so any
  function with the right signature becomes a `Prober`:
  `probe.ProberFunc(func(ctx context.Context, s probe.Spec) probe.Result {...})`.
  Keep interfaces small and define them where they are _used_; a one-method
  interface is the most common kind in Go.
]

The HTTP implementation bounds every probe with its own timeout, reads at
most 64 KiB of the body so the connection can be reused, and turns
transport errors into short, stable messages:

#src("workbook/ch20/step3/internal/probe/probe.go", region: "http")
#src("workbook/ch20/step3/internal/probe/probe.go", region: "helpers")

Its test runs a local `httptest` server with one handler per behaviour.
Create `internal/probe/probe_test.go`:

#src("workbook/ch20/step3/internal/probe/probe_test.go")

=== The health state machine

#fig(placement: auto, caption: [The `Healthy` condition. Failures below `failureThreshold` are absorbed; Events (step 4) fire only on the two transitions a human cares about.])[
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
which makes the heart of the operator testable without any Kubernetes at
all. Create `internal/controller/status.go`:

#src("workbook/ch20/step3/internal/controller/status.go", region: "imports")
#src("workbook/ch20/step3/internal/controller/status.go", region: "transition")
#src("workbook/ch20/step3/internal/controller/status.go", region: "apply")
#src("workbook/ch20/step3/internal/controller/status.go", region: "sethealthy")

`meta.SetStatusCondition` only moves `lastTransitionTime` when the status
value changes, which is what keeps a steady state free of writes. A
table-driven test walks the machine through a realistic sequence: an early
failure, a recovery, absorbed blips, crossing the threshold, saturation,
and recovery again. A second test pins down the write economy. Create
`internal/controller/status_test.go`:

#src("workbook/ch20/step3/internal/controller/status_test.go", region: "head")
#src("workbook/ch20/step3/internal/controller/status_test.go", region: "statetest")
#src("workbook/ch20/step3/internal/controller/status_test.go", region: "saturated")

Testing the logic as a pure function makes the rest of the testing cheaper.
The envtest suite only needs to prove the _wiring_: that statuses are
written, Events emitted, rules created. Not every edge of the state machine.

=== The reconcile loop

Replace `internal/controller/healthcheck_controller.go`. The reconciler's
dependencies are interfaces or plain values, injected in `main`. That is
what lets the same code run in the cluster, in envtest, and in unit tests
with fakes:

#src("workbook/ch20/step3/internal/controller/healthcheck_controller.go", region: "imports")
#src("workbook/ch20/step3/internal/controller/healthcheck_controller.go", region: "reconciler")
#src("workbook/ch20/step3/internal/controller/healthcheck_controller.go", region: "rbac")
#src("workbook/ch20/step3/internal/controller/healthcheck_controller.go", region: "reconcile")

Read `Reconcile` as a sequence of decisions, each of which is safe to repeat:

+ *Fetch, and treat "not found" as success.* The object may have been deleted
  after the event was queued. Returning an error would retry a deletion
  forever.
+ *Compute the desired status on a copy.* `base` is the object as read;
  `reconcileHealth` mutates `hc.Status`.
+ *Write only if something changed.* `equality.Semantic.DeepEqual` compares
  Kubernetes types correctly (resource quantities by value, for example).
  `client.MergeFromWithOptions(base, MergeFromWithOptimisticLock{})` sends a
  JSON merge patch with only the difference, plus the `resourceVersion` it
  was computed from. If the cache served a stale object (our own previous
  write hasn't arrived yet), the API server answers 409 Conflict instead of
  silently overwriting newer status, and the reconciler retries a second
  later from a fresh read.
+ *Schedule the next reconcile.* `reconcileHealth` returns the delay: the
  interval with ±10% jitter after a probe. Without jitter, 500 checks created
  by one `kubectl apply` would probe in lockstep forever, producing a
  synchronized spike every interval.

#src("workbook/ch20/step3/internal/controller/healthcheck_controller.go", region: "health")
#src("workbook/ch20/step3/internal/controller/healthcheck_controller.go", region: "resolve")

Service targets resolve to the Service's cluster DNS name,
`name.namespace.svc.cluster.local`, after the controller confirms through
the cache that the Service and port exist. A missing Service gets the
precise reason `TargetUnresolved` instead of a confusing DNS error.

#warning(title: [`Requeue` versus `RequeueAfter` versus returning an error])[
  Return an error when the reconcile _failed_ and should be retried with
  backoff: an API conflict, a 500 from Datadog during cleanup. Return
  `RequeueAfter` when the work _succeeded_ and must simply happen again later,
  like the next probe. Don't return an error to get periodic behaviour: errors
  increment `controller_runtime_reconcile_errors_total`, feed the exponential
  backoff (so the period grows to minutes), and log stack traces for
  something that isn't an error.
]

The setup gains a predicate, and two helpers close the file:

#src("workbook/ch20/step3/internal/controller/healthcheck_controller.go", region: "setup")
#src("workbook/ch20/step3/internal/controller/healthcheck_controller.go", region: "jitter")

*`GenerationChangedPredicate` on the primary resource.* Every status patch
the controller makes is itself an update event on the HealthCheck. Without a
predicate, each status change would immediately trigger another reconcile of
the same object. Generation only changes on spec updates (and on deletion),
so filtering on it means "reconcile when the user changes something". The
periodic `RequeueAfter` drives everything else.

`main.go` gets two flags of its own and passes the prober in. Add this block
after the scaffold's flags, and replace the wiring:

#src("workbook/ch20/step3/cmd/main.go", region: "imports")
#src("workbook/ch20/step3/cmd/main.go", region: "ownflags")
#src("workbook/ch20/step3/cmd/main.go", region: "wiring")

=== Testing the loop

The suite now runs the controller in a manager, exactly as `main` does.
Replace the imports of `suite_test.go`, and insert the manager between the
namespace creation and `envUp = true`:

#src("workbook/ch20/step3/internal/controller/suite_test.go", region: "imports")
#src("workbook/ch20/step3/internal/controller/suite_test.go", region: "manager")

The manager's cache only sees `wt-managed`, so tests that call `Reconcile`
by hand (steps 7 and 8) can use `wt-manual` without the running controller
interfering. Add a polling helper at the end of the file:

#src("workbook/ch20/step3/internal/controller/suite_test.go", region: "eventually")

The lifecycle test breaks and fixes a real HTTP target. Replace the test
file's imports and add:

#src("workbook/ch20/step3/internal/controller/healthcheck_controller_test.go", region: "imports")
#src("workbook/ch20/step3/internal/controller/healthcheck_controller_test.go", region: "gethelpers")
#src("workbook/ch20/step3/internal/controller/healthcheck_controller_test.go", region: "lifecycle")

`atomic.Bool` lets the test goroutine flip the target's behaviour while the
server's goroutines read it, without a data race; `-race` would flag a plain
`bool`.

#needspace(14em)
#checkpoint(step: 3, of: 8, title: [Probe and report])[
  #output("ch20/s3-tree.txt", cmd: "find . -name '*.go' -not -path './bin/*' | sort")
  #output("ch20/s3-make.txt", cmd: "make manifests generate", size: 6.2pt)
  #output("ch20/s3-test.txt", cmd: "go vet ./... && go test ./...")
  #output("ch20/s3-testv.txt", cmd: "go test -v -run 'ApplyProbe|Saturated|Lifecycle' ./internal/controller/ \\\n  | grep -v '^=== RUN'")
  #output("ch20/s3-lint.txt", cmd: "golangci-lint run --config \"$LAB/platform-go/.golangci.yml\" ./...")
  #troubleshoot(
    ([#ts("s3-nostatus.txt")], [Status written with `r.Patch` instead of `r.Status().Patch`. With a status subresource, the main endpoint ignores `.status`.], [Write status through `r.Status()`.]),
    ([#ts("s3-threshold.txt")], [`>` where `>=` belongs: the counter saturates at the threshold, so it never exceeds it.], [Compare with `>=`. See @fig-health-sm.]),
    ([#ts("s3-bodyclose.txt")], [`defer resp.Body.Close()` is missing; every probe leaks a connection.], [Close the body right after the error check.]),
    ([#ts("s3-cancel.txt")], [The `cancel` from `context.WithTimeout` was discarded, so the timer leaks until it fires.], [`ctx, cancel := ...; defer cancel()`.]),
  )
]

#step(4, 8, "Metrics and Events", label: <sec-op-metrics>)

Status says what is true now. Metrics say how it got there, at high
frequency, and Events tell a human what changed. Create
`internal/controller/metrics.go`:

#src("workbook/ch20/step4/internal/controller/metrics.go", region: "head")
#src("workbook/ch20/step4/internal/controller/metrics.go", region: "metrics")
#src("workbook/ch20/step4/internal/controller/metrics.go", region: "observe")

#goconcept(title: [`init` and package-level state])[
  A package can declare variables outside any function, like `checkUp`, and
  any number of `func init()` blocks. Go runs the variable initializers and
  then the `init` functions once, before `main` (or before the tests), in
  dependency order. Registering metrics there is the idiom, because a
  collector registered twice panics. The cost is hidden global state: tests
  in the same package share these metrics, which is why the exercise tests
  give their checks unique names. Keep `init` small and side-effect-light;
  anything that can fail belongs in `main`, where you can report the error.
]

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

*Metric labels that survive scraping.* The labels are `check_namespace` and
`check_name`, not `namespace` and `name`. When Prometheus scrapes the
operator, it attaches the operator pod's own `namespace` target label. A
metric label with the same name is renamed to `exported_namespace` unless
the scrape config sets `honorLabels: true`, and alerts written against
`namespace` then silently match nothing.

Events are the human-facing record: `kubectl describe` shows them and
`kubectl get events` lists them. `watchtower` emits Events only on
transitions, `ProbeFailing` and `Recovered`. Events on every probe would be
noise, and the API server rate-limits event writes per source. The
reconciler gets a recorder field and an RBAC marker for `events.k8s.io`:

#src("workbook/ch20/step4/internal/controller/healthcheck_controller.go", region: "imports")
#src("workbook/ch20/step4/internal/controller/healthcheck_controller.go", region: "reconciler")
#src("workbook/ch20/step4/internal/controller/healthcheck_controller.go", region: "rbac")

`Reconcile` forgets a deleted check's series, and `reconcileHealth` records
each probe and emits an Event when the state machine reports a transition:

#src("workbook/ch20/step4/internal/controller/healthcheck_controller.go", region: "reconcile")
#src("workbook/ch20/step4/internal/controller/healthcheck_controller.go", region: "health")

The recorder comes from `mgr.GetEventRecorder("watchtower")`, the
`events.k8s.io/v1` API. controller-runtime 0.25 deprecates
`GetEventRecorderFor`, which writes the legacy core `v1` Events. Pass it in
`main.go`'s wiring and in the suite's reconciler:

#src("workbook/ch20/step4/cmd/main.go", region: "wiring")
#src("workbook/ch20/step4/internal/controller/suite_test.go", region: "reconciler")

The lifecycle test checks the Event. Insert this right after step 2 of
`TestHealthCheckLifecycle`, where the target breaks, and add
`eventsv1 "k8s.io/api/events/v1"` to the imports:

#src("workbook/ch20/step4/internal/controller/healthcheck_controller_test.go", region: "event")
#src("workbook/ch20/step4/internal/controller/healthcheck_controller_test.go", region: "imports")

#needspace(14em)
#checkpoint(step: 4, of: 8, title: [Metrics and Events])[
  The new marker adds a rule to the ClusterRole:
  #output("ch20/s4-make.txt", cmd: "make manifests generate", size: 6.2pt)
  #output("ch20/s4-rbac.txt", cmd: "grep -A6 events.k8s.io config/rbac/role.yaml")
  #output("ch20/s4-test.txt", cmd: "go vet ./... && go test ./...")
  #output("ch20/s4-lint.txt", cmd: "golangci-lint run --config \"$LAB/platform-go/.golangci.yml\" ./...")
  #troubleshoot(
    ([#ts("s4-norecorder.txt")], [The suite's reconciler has no `Recorder`. The nil interface panics inside `Reconcile`; controller-runtime recovers the panic, so the test only sees status that never changes.], [Set `Recorder` wherever you build the reconciler.]),
    ([#ts("s4-dupreg.txt")], [The same collectors registered twice.], [Register once, in `init`.]),
    ([#ts("s4-noforget.txt")], [`forget` is never called, so deleted checks keep exporting their last value.], [Call it when `Get` returns NotFound.]),
  )
]

#step(5, 8, "Watching Services", label: <sec-op-watches>)

What a controller watches decides how quickly it reacts and how much work it
does for nothing. A HealthCheck targeting a Service that doesn't exist yet
reports `TargetUnresolved`. When the Service is created, the check should
resolve now, not after its next interval. This step adds a second watch.

Add the index name next to the reconciler type, and replace the imports:

#src("workbook/ch20/step5/internal/controller/healthcheck_controller.go", region: "imports")
#src("workbook/ch20/step5/internal/controller/healthcheck_controller.go", region: "consts")

`SetupWithManager` now takes a context for the index and watches Services:

#src("workbook/ch20/step5/internal/controller/healthcheck_controller.go", region: "setup")
#src("workbook/ch20/step5/internal/controller/healthcheck_controller.go", region: "mapfunc")

*A secondary watch, mapped through a field index.*
`Watches(&corev1.Service{}, handler.EnqueueRequestsFromMapFunc(...))` turns
each Service event into reconcile requests for the HealthChecks that target
it. The map function has to find those checks efficiently, so `IndexField`
registers an index on the informer cache keyed by
`.spec.target.service.name`, and the lookup becomes an indexed cache read
instead of a scan of every HealthCheck.

*A predicate on the Service watch* passes only creates, deletes and port
changes. Services are updated far more often than that (annotations,
load-balancer status, managed fields), and none of those updates affect
resolution.

#goconcept(title: [Closures as callbacks, and method values])[
  `IndexField` takes a function literal, `func(o client.Object) []string`,
  that the cache calls for every HealthCheck it stores. A function literal
  is a _closure_: it can use variables from the code around it, and keeps
  them alive as long as it exists. `predicate.Funcs{UpdateFunc: ...}` is a
  struct whose fields are functions; you fill in the one you care about.
  `r.checksForService`, without parentheses, is a _method value_: a
  function bound to this particular `r`, which the handler can call later
  as `f(ctx, svc)`. All three run on the cache's goroutines, not yours, so
  they must be fast and must not block: no API calls, only cache reads.
]

`main.go` passes its context to the new signature:

#src("workbook/ch20/step5/cmd/main.go", region: "wiring")

envtest has no cluster DNS, so the suite wraps the prober: requests for
`*.svc.cluster.local` URLs are answered as healthy without dialling.
Everything else, including the probes to `httptest` servers, stays real.
Update the suite's imports and reconciler, and add the wrapper at the end:

#src("workbook/ch20/step5/internal/controller/suite_test.go", region: "imports")
#src("workbook/ch20/step5/internal/controller/suite_test.go", region: "reconciler")
#src("workbook/ch20/step5/internal/controller/suite_test.go", region: "dnsprober")

The test proves the watch, not the timer, did the work: the check resolves
in well under its 5-second interval. Add `corev1 "k8s.io/api/core/v1"` to the
test imports, and the test:

#src("workbook/ch20/step5/internal/controller/healthcheck_controller_test.go", region: "imports")
#src("workbook/ch20/step5/internal/controller/healthcheck_controller_test.go", region: "servicetest")

#production(title: [What the cache costs you])[
  Each `For`, `Owns` and `Watches` starts an informer that lists and then
  watches _every_ object of that kind the operator can see. Watching Services
  cluster-wide means holding every Service in memory, which is modest, but the
  same line written for Pods or Secrets in a 5,000-node cluster can mean
  gigabytes. Tools for keeping it under control, covered in Chapter 21:
  restrict namespaces (`cache.Options.DefaultNamespaces`, as the test suite
  does), select by label (`ByObject` with a label selector), transform
  objects before they are cached (strip `managedFields` and annotations you
  don't read), or watch metadata only (`WatchesMetadata`) when you only need
  names and labels.
]

#needspace(14em)
#checkpoint(step: 5, of: 8, title: [Watching Services])[
  #output("ch20/s5-make.txt", cmd: "make manifests generate", size: 6.2pt)
  #output("ch20/s5-test.txt", cmd: "go vet ./... && go test ./...")
  #output("ch20/s5-testv.txt", cmd: "go test -v -run 'ServiceTarget' ./internal/controller/ | grep -v '^=== RUN'")
  #output("ch20/s5-lint.txt", cmd: "golangci-lint run --config \"$LAB/platform-go/.golangci.yml\" ./...")
  #troubleshoot(
    ([#ts("s5-nowatch.txt")], [The predicate drops Service creates, so the new Service triggers nothing and the check waits for its next interval.], [Let creates and deletes through; filter only updates.]),
    ([#ts("s5-noindex.txt")], [The index isn't registered, so `List` with `MatchingFields` fails inside the map function and nothing is enqueued.], [Call `IndexField` before the controller starts.]),
    ([#ts("s5-nodns.txt")], [The real prober tried to resolve a `.svc.cluster.local` name; envtest has no cluster DNS.], [Use `clusterDNSProber` in the suite.]),
  )
]
