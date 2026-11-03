#import "../template/book.typ": *

#let ts(name) = quote-output("ch20/ts/" + name)
#let wb = "workbook/ch20/"

#step(6, 8, "PrometheusRules", label: <sec-op-owned>)

A check that fails should page someone. Not every cluster runs the same
monitoring stack, so alerting goes behind an interface chosen once at
startup with `--alert-backend`. Create `internal/alerting/alerting.go`:

#src("workbook/ch20/step6/internal/alerting/alerting.go", region: "head")
#src("workbook/ch20/step6/internal/alerting/alerting.go", region: "backend")
#src("workbook/ch20/step6/internal/alerting/alerting.go", region: "none")

#goconcept(title: [Interfaces as plug-in points])[
  `Backend` is the same idea as `Prober` from step 3, used for a bigger
  decision. The reconciler holds an `alerting.Backend` and never learns
  which stack it talks to; `main` picks the concrete type. `None` is an
  empty struct, `struct{}`, which takes no memory and still has methods, so
  "no alerting" is a real implementation rather than a `nil` to check for
  everywhere. When code does need the concrete type, a _type assertion_
  asks for it: `if _, ok := r.Alerts.(alerting.None); ok {...}`. The
  two-value form never panics; the one-value form, `r.Alerts.(alerting.None)`,
  panics if the type is wrong. `any` is the interface with no methods,
  which every type satisfies; it is how `unstructured` objects hold
  arbitrary JSON as `map[string]any`.
]

=== Owned resources and server-side apply

For clusters running the Prometheus Operator, `watchtower` generates one
`PrometheusRule` per HealthCheck. Create `internal/alerting/prometheus.go`.
Rendering the rule is plain data construction:

#src("workbook/ch20/step6/internal/alerting/prometheus.go", region: "head")
#src("workbook/ch20/step6/internal/alerting/prometheus.go", region: "render")

Two decisions are worth defending in a design review.

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

Applying the rule is where server-side apply comes in:

#src("workbook/ch20/step6/internal/alerting/prometheus.go", region: "ensure")
#src("workbook/ch20/step6/internal/alerting/prometheus.go", region: "remove")

The read comes from the informer cache, so in steady state, where the rule
exists and matches, `Ensure` makes no API calls at all, and it can run on
every reconcile without cost. When the rule is missing or different, the
controller applies it.

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

The rendering test needs no API server. Create
`internal/alerting/prometheus_test.go`:

#src("workbook/ch20/step6/internal/alerting/prometheus_test.go")

=== Wiring alerting into the reconciler

Status gets a helper for the second condition. Add it to `status.go`:

#src("workbook/ch20/step6/internal/controller/status.go", region: "setalerting")

The reconciler gets the backend, a flag saying whether to watch rules, and
the RBAC to manage them. Replace the imports and the type, and add the
marker:

#src("workbook/ch20/step6/internal/controller/healthcheck_controller.go", region: "imports")
#src("workbook/ch20/step6/internal/controller/healthcheck_controller.go", region: "reconciler")
#src("workbook/ch20/step6/internal/controller/healthcheck_controller.go", region: "rbac")

In `Reconcile`, call `r.reconcileAlerting(ctx, &hc)` right after
`reconcileHealth`:

#src("workbook/ch20/step6/internal/controller/healthcheck_controller.go", region: "reconcile")

And the new method, after `resolveURL`:

#src("workbook/ch20/step6/internal/controller/healthcheck_controller.go", region: "alerting")

`ErrUnavailable` gets its own reason, `BackendUnavailable`, so a cluster
without the Prometheus Operator shows a clear message instead of a stream of
errors. Finally the `Owns` watch, added only when the PrometheusRule CRD
exists at startup, because a watch on a kind the API server doesn't know
would stop the whole manager from starting:

#src("workbook/ch20/step6/internal/controller/healthcheck_controller.go", region: "setup")

*`Owns` for the rules we create.* Every PrometheusRule we write carries a
controller owner reference to its HealthCheck. `Owns` watches
PrometheusRules and enqueues the _owner_ when one changes or disappears. The
combination is a _self-healing_ loop. A human deletes or edits the
generated rule, the watch enqueues the owning HealthCheck, `Ensure` sees the
difference in the cache, and the rule is restored within a second or two.
You will see exactly that on a real cluster in step 8.

=== Choosing the backend in `main`

`main.go` gets the flags, the backend selection, and two helpers:

#src("workbook/ch20/step6/cmd/main.go", region: "imports")
#src("workbook/ch20/step6/cmd/main.go", region: "ownflags")
#src("workbook/ch20/step6/cmd/main.go", region: "wiring")
#src("workbook/ch20/step6/cmd/main.go", region: "backend")
#src("workbook/ch20/step6/cmd/main.go", region: "labels")

The `RESTMapping` lookup is a discovery call: it asks the API server whether
`monitoring.coreos.com/v1 PrometheusRule` exists. If it doesn't, the operator
still starts. Probing and metrics work, and every check reports
`AlertingReady=False` with reason `BackendUnavailable` and a message saying
what to install. Degrading with a clear explanation, rather than
crash-looping, is the behaviour that lets a platform team ship one operator
build to every cluster.

=== Testing owned rules

envtest needs the PrometheusRule CRD. The real one is large and versioned
by another project; a minimal stand-in that accepts any `spec` is enough to
exercise our code path. Create
`internal/controller/testdata/crds/prometheusrules.yaml`:

#src("workbook/ch20/step6/internal/controller/testdata/crds/prometheusrules.yaml")

Add its directory to `CRDDirectoryPaths` in `runSuite`, and give the suite's
reconciler the backend (with the import for `watchtower/internal/alerting`):

#src("workbook/ch20/step6/internal/controller/suite_test.go", region: "testcrds")
#src("workbook/ch20/step6/internal/controller/suite_test.go", region: "imports")
#src("workbook/ch20/step6/internal/controller/suite_test.go", region: "reconciler")

The test walks the rule's life: created and owned, edited by another field
manager and taken back, deleted and restored, and removed when alerting is
turned off. Replace the test imports and add:

#src("workbook/ch20/step6/internal/controller/healthcheck_controller_test.go", region: "imports")
#src("workbook/ch20/step6/internal/controller/healthcheck_controller_test.go", region: "ruletest")

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

#needspace(14em)
#checkpoint(step: 6, of: 8, title: [PrometheusRules])[
  #output("ch20/s6-tree.txt", cmd: "find . -name '*.go' -not -path './bin/*' | sort")
  #output("ch20/s6-make.txt", cmd: "make manifests generate", size: 6.2pt)
  #output("ch20/s6-test.txt", cmd: "go vet ./... && go test ./...")
  #output("ch20/s6-testv.txt", cmd: "go test -v -run 'PrometheusRule' ./... 2>&1 | grep -E '^(---|ok|FAIL)'")
  #output("ch20/s6-lint.txt", cmd: "golangci-lint run --config \"$LAB/platform-go/.golangci.yml\" ./...")
  #troubleshoot(
    ([#ts("s6-nocrd.txt")], [The test CRD isn't installed. The `Owns` watch on an unknown kind can't start, so neither can the controller, and nothing reconciles.], [Add `testdata/crds` to `CRDDirectoryPaths`.]),
    ([#ts("s6-noowner.txt")], [`Render` used `SetOwnerReference`, which records an owner without `controller: true`. `Owns` and `GetControllerOf` only follow controller references.], [Use `SetControllerReference`.]),
    ([#ts("s6-noowns.txt")], [`WatchRules` is false, so nothing watches the rules and a deleted rule waits for the next interval.], [Watch owned rules when the CRD exists.]),
    ([#ts("s6-deprecated.txt")], [`client.Patch` with `client.Apply` is deprecated in controller-runtime 0.25.], [Use `client.Apply` with an apply configuration.]),
  )
]

#step(7, 8, "Datadog and finalizers", label: <sec-op-external>)

The `External` method carries the key distinction in `Backend`. A
PrometheusRule lives in the cluster, so owner references and garbage
collection handle its lifecycle. A Datadog monitor lives in someone else's
API. Kubernetes knows nothing about it, and deleting the HealthCheck would
orphan the monitor forever unless the operator deletes it first.
_Finalizers_ exist for exactly this.

=== A client for the Monitors API

Create `internal/alerting/datadog.go`:

#src("workbook/ch20/step7/internal/alerting/datadog.go", region: "ddhead")
#src("workbook/ch20/step7/internal/alerting/datadog.go", region: "ddmonitor")

Kubernetes gives in-cluster resources idempotent creation for free: names
are unique, and apply is declarative. Most external APIs offer neither, so
the operator has to build idempotency itself:

#src("workbook/ch20/step7/internal/alerting/datadog.go", region: "ddensure")

Consider the failure the UID tag defends against. The operator creates the
monitor, and then the status patch recording its ID fails: a conflict, a
network blip, or the pod being rescheduled. The next reconcile sees no ID in
status. A naive implementation creates a second monitor, and you now have
duplicate pages for every incident. Tagging every monitor with the
HealthCheck's UID, which never changes for the object's lifetime and is never
reused, gives the operator a lookup key that works even when its own records
are lost.

#src("workbook/ch20/step7/internal/alerting/datadog.go", region: "ddremove")
#src("workbook/ch20/step7/internal/alerting/datadog.go", region: "ddbody")

The API keys come from environment variables, never from flags: flags show
up in `ps` output and in the Pod spec, and the Deployment can fill the
variables from a Secret, so the operator never needs RBAC to _read_ Secrets.

=== A fake Datadog

Tests need an API to talk to. `ddfake` is a tiny in-memory implementation of
the documented Monitors API (`GET`, `POST`, `PUT` and `DELETE` on
`/api/v1/monitor`, with the `DD-API-KEY` and `DD-APPLICATION-KEY` headers),
packaged in the style of `httptest` so the controller tests can use it as
well. Create `internal/alerting/ddfake/ddfake.go`:

#src("workbook/ch20/step7/internal/alerting/ddfake/ddfake.go", region: "fakehead")
#src("workbook/ch20/step7/internal/alerting/ddfake/ddfake.go", region: "fake")
#src("workbook/ch20/step7/internal/alerting/ddfake/ddfake.go", region: "fakeapi")

The tests simulate exactly the crash described above. Create
`internal/alerting/datadog_test.go`:

#src("workbook/ch20/step7/internal/alerting/datadog_test.go", region: "ddtesthead")
#src("workbook/ch20/step7/internal/alerting/datadog_test.go", region: "ddtest")
#src("workbook/ch20/step7/internal/alerting/datadog_test.go", region: "ddtestmore")

Run the backend against a real Datadog organization before you trust it in
production: fakes encode your _understanding_ of an API, and the point of the
fake is to test your logic against that understanding quickly and
deterministically.

=== Finalizers

A finalizer is a string in `metadata.finalizers`. While the list is non-empty,
a delete request only sets `deletionTimestamp`; the object stays in the API,
visible and updatable, until every finalizer is removed. The controller sees
the deletion as an ordinary update, does its cleanup, removes its finalizer,
and only then does the object disappear. Add the finalizer's name to the
constants and replace the imports:

#src("workbook/ch20/step7/internal/controller/healthcheck_controller.go", region: "imports")
#src("workbook/ch20/step7/internal/controller/healthcheck_controller.go", region: "consts")

`Reconcile` handles deletion first, and adds the finalizer before anything
external exists:

#src("workbook/ch20/step7/internal/controller/healthcheck_controller.go", region: "reconcile")

The cleanup itself goes after `reconcileAlerting`:

#src("workbook/ch20/step7/internal/controller/healthcheck_controller.go", region: "finalize")

The rules for finalizers are strict:

- Add it _before_ creating the external resource, as `Reconcile` does. If the
  order were reversed, a crash or a delete between "create monitor" and "add
  finalizer" would leave a monitor no one will ever clean up.
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

=== Generation-gated sync

`reconcileAlerting` gets one more check, the gate before `Ensure`, and
`status.go` the helper it uses:

#src("workbook/ch20/step7/internal/controller/healthcheck_controller.go", region: "alerting")
#src("workbook/ch20/step7/internal/controller/status.go", region: "synced")

#production(title: [Generation-gated external sync])[
  External backends are skipped when the current generation has already been
  synced and `AlertingReady` is true. Datadog's API is rate-limited per
  organization, and 2,000 checks re-asserting their monitors every 30 seconds
  would burn through that limit for no benefit. The trade-off is that edits
  made in the Datadog UI aren't reverted until the spec changes. Exercise 20.4
  adds a slow periodic resync, the usual compromise. In-cluster rules don't
  need the gate, because the comparison against the cache is free.
]

`main.go` learns the `datadog` backend:

#src("workbook/ch20/step7/cmd/main.go", region: "imports")
#src("workbook/ch20/step7/cmd/main.go", region: "ownflags")
#src("workbook/ch20/step7/cmd/main.go", region: "wiring")
#src("workbook/ch20/step7/cmd/main.go", region: "backend")

The finalizer test calls `Reconcile` directly, in the namespace the manager
ignores, so it can assert on the intermediate states: the finalizer is
present, only one monitor exists after three reconciles, the object lingers
with a `deletionTimestamp`, and it disappears only after cleanup. Replace
the test imports and add:

#src("workbook/ch20/step7/internal/controller/healthcheck_controller_test.go", region: "imports")
#src("workbook/ch20/step7/internal/controller/healthcheck_controller_test.go", region: "finalizertest")

#needspace(14em)
#checkpoint(step: 7, of: 8, title: [Datadog and finalizers])[
  #output("ch20/s7-tree.txt", cmd: "find . -name '*.go' -not -path './bin/*' | sort")
  #output("ch20/s7-make.txt", cmd: "make manifests generate", size: 6.2pt)
  #output("ch20/s7-test.txt", cmd: "go vet ./... && go test ./...")
  #output("ch20/s7-testv.txt", cmd: "go test -v -run 'Datadog' ./... 2>&1 | grep -E '^(---|ok|FAIL)'")
  #output("ch20/s7-lint.txt", cmd: "golangci-lint run --config \"$LAB/platform-go/.golangci.yml\" ./...")
  #troubleshoot(
    ([#ts("s7-notag.txt")], [`Ensure` doesn't look for a monitor tagged with the UID, so a lost status record means a duplicate monitor.], [Search by tag before creating.]),
    ([#ts("s7-noupdate.txt")], [The finalizer was removed from the Go object but never written back.], [`return r.Update(ctx, hc)` after `RemoveFinalizer`.]),
    ([#ts("s7-nokeys.txt")], [`Ensure` calls Datadog without credentials, so every check would report `SyncFailed` with a 403 instead of a clear `BackendUnavailable`.], [Check the keys first and wrap `ErrUnavailable`.]),
  )
]

#step(8, 8, "Cadence and kind", label: <sec-op-health>)

Every test passes, and the operator is still wrong. This step is about the
bug that only a real cluster found, and the end-to-end script that found it.

=== Not every reconcile is a timer tick

The first version of `reconcileHealth` probed on every reconcile, and the
unit tests and envtest suite all passed. The end-to-end run on kind caught
the bug. The `payments-api` check, with a 10-second interval and a failure
threshold of 3, should turn unhealthy about 20 seconds after it is created:
three failures, two intervals apart. On kind it took 11. The creation event
triggered a reconcile and a probe. Creating its PrometheusRule triggered a
second reconcile through the `Owns` watch, and that probed too. Here is the
step 7 code under the script you are about to write:

#quote-output("ch20/ts/s8-e2e-nogate.txt")

Reconciles arrive for many reasons: the requeue timer, the object's own spec
changes, owned objects changing, mapped Service events, and periodic cache
resyncs. A reconciler that does expensive or time-sensitive work on _every_
call has to decide whether that work is actually due. Add a record of the
last probe to the reconciler, and the `sync` import:

#src("workbook/ch20/step8/internal/controller/healthcheck_controller.go", region: "imports")
#src("workbook/ch20/step8/internal/controller/healthcheck_controller.go", region: "reconciler")

`reconcileHealth` checks it before probing and updates it after:

#src("workbook/ch20/step8/internal/controller/healthcheck_controller.go", region: "health")
#src("workbook/ch20/step8/internal/controller/healthcheck_controller.go", region: "untildue")

A reconcile arriving less than half an interval after the last probe skips
probing and requeues for the remainder of the interval, keeping the cadence.
A new generation, meaning the user changed the spec, always probes
immediately. The record is deliberately not persisted. Writing it to status
would bring back the per-probe churn the status design avoids, and losing it
on a restart costs at most one early probe. Forget the record with the
object, in `Reconcile`'s not-found branch and in `finalize`:

#src("workbook/ch20/step8/internal/controller/healthcheck_controller.go", region: "reconcile")
#src("workbook/ch20/step8/internal/controller/healthcheck_controller.go", region: "finalize")

#goconcept(title: [`sync.Map`])[
  Reconciles for different objects run on different goroutines at once, so
  a plain `map` shared between them is a data race. `sync.Map` is a map
  that is safe for concurrent use, tuned for keys written once and read
  many times, or for goroutines working on disjoint keys, which is exactly
  this case: each key belongs to one object, and the workqueue never runs
  two reconciles for the same key together. Its values are `any`, so
  reading needs a type assertion (`v.(probeRecord)`). A `map` guarded by a
  `sync.Mutex` works too and is typed; pick `sync.Map` when contention on
  one lock would hurt.
]

The regression test drives `Reconcile` directly, so it fails on step 7's
code without a cluster:

#src("workbook/ch20/step8/internal/controller/healthcheck_controller_test.go", region: "cadencetest")

=== Images without base images

The end-to-end run needs the operator and a demo service as container
images. Instead of the scaffold's multi-stage `Dockerfile`, the script
cross-compiles on the host and copies each static binary into a `FROM scratch` image: no base images to pull, and the host's build cache makes
rebuilds take seconds. Release images still come from the `Dockerfile`.
Create `hack/scratch.Dockerfile`:

#src("workbook/ch20/step8/hack/scratch.Dockerfile")

The demo service answers `/healthz`, and `/status/503` with a 503, so the
demo needs no internet for its failing check. Create `hack/demoapp/main.go`:

#src("workbook/ch20/step8/hack/demoapp/main.go")

The demo: the app, then four checks. Create `config/samples/demo.yaml`:

#src("workbook/ch20/step8/config/samples/demo.yaml")

=== The end-to-end script

Create `hack/e2e-kind.sh`; you run it with `bash`. It is a test, so it
asserts, and it fails loudly:

#src("workbook/ch20/step8/hack/e2e-kind.sh", region: "head")

It creates the cluster if needed and installs the Prometheus Operator's
actual PrometheusRule CRD:

#src("workbook/ch20/step8/hack/e2e-kind.sh", region: "cluster")

Then it builds both images, loads them into kind, deploys with kustomize, and
waits until the new pod holds the leader Lease, so an old pod still on its
way out can't probe alongside it:

#src("workbook/ch20/step8/hack/e2e-kind.sh", region: "build")

The demo goes in app first, so every check can probe from its first
reconcile, and the cadence assertion is the one that caught the bug:

#src("workbook/ch20/step8/hack/e2e-kind.sh", region: "demo")
#src("workbook/ch20/step8/hack/e2e-kind.sh", region: "cadence")
#src("workbook/ch20/step8/hack/e2e-kind.sh", region: "ready")

The rest shows the operator's work and checks self-healing, the Service
watch and the metrics endpoint:

#src("workbook/ch20/step8/hack/e2e-kind.sh", region: "capture")
#src("workbook/ch20/step8/hack/e2e-kind.sh", region: "service")
#src("workbook/ch20/step8/hack/e2e-kind.sh", region: "metrics")

#needspace(14em)
#checkpoint(step: 8, of: 8, title: [Cadence and kind])[
  #output("ch20/s8-tree.txt", cmd: "find hack config/samples -type f | sort")
  #output("ch20/s8-test.txt", cmd: "go vet ./... && go test ./...")
  #output("ch20/s8-testv.txt", cmd: "go test -v -run 'Cadence' ./internal/controller/ | grep -v '^=== RUN'")
  #output("ch20/s8-lint.txt", cmd: "golangci-lint run --config \"$LAB/platform-go/.golangci.yml\" ./...")
  Then the real cluster. The script prints every command; these are its
  key lines and the outputs it saved with `OUT`:
  #output("ch20/s8-e2e-key.txt", cmd: "OUT=/tmp/wt bash hack/e2e-kind.sh")
  #output("ch20/e2e/describe-payments.txt", cmd: "kubectl describe hc payments-api -n shop", size: 6.6pt)
  `describe` shows both conditions with their reasons, the saturated failure
  counter, and the `ProbeFailing` Event emitted exactly once on the
  transition. The generated rules, one per alerting check, and one of them
  in full: the `managed-by` label, the controller owner reference with
  `blockOwnerDeletion`, and the expression rendered as a YAML block,
  because `Render` puts newlines in it:
  #output("ch20/e2e/get-rules.txt", cmd: "kubectl get prometheusrules -n shop")
  #output("ch20/e2e/rule-yaml.txt", cmd: "kubectl get prometheusrule watchtower-storefront -n shop -o yaml", size: 6.6pt)
  Deleting a generated rule by hand brings it back within seconds, through
  the `Owns` watch. Its age gives it away:
  #session(
    ("kubectl delete prometheusrule watchtower-storefront -n shop", "ch20/e2e/rule-deleted.txt"),
    ("sleep 3", none),
    ("kubectl get prometheusrule watchtower-storefront -n shop", "ch20/e2e/rule-restored.txt"),
  )
  Creating the missing `inventory` Service resolves the check at once
  through the Service watch. The first probe may still fail while the new
  Service's endpoints are programmed; that is a blip below the threshold,
  and the next probe succeeds:
  #output("ch20/e2e/resolved-inventory.txt", cmd: "kubectl get hc inventory -n shop -o custom-columns=\"$cols\"")
  #output("ch20/e2e/get-hc-after.txt", cmd: "kubectl get healthchecks -n shop")
  #output("ch20/e2e/events.txt", cmd: "kubectl get events -n shop --field-selector reportingComponent=watchtower \\\n  -o custom-columns='REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message'")
  #output("ch20/e2e/metrics.txt", cmd: "metrics   # curl the authenticated endpoint, keep watchtower_healthcheck_*", size: 6.0pt)
  #troubleshoot(
    ([#ts("s8-nogate.txt")], [Reconciles triggered by watch events probe early: no cadence gate.], [`untilDue` before every probe.]),
    ([#ts("s8-e2e-nogate.txt")], [The same bug on kind: the `Owns` event after creating the rule caused a second probe at once.], [As above; see "Not every reconcile is a timer tick".]),
    ([#ts("s8-nogen.txt")], [`untilDue` ignores the generation, so a spec change waits for the old interval.], [Probe at once when `generation` changed.]),
  )
]

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
probes run; `LeaderElectionReleaseOnCancel` shortens planned handovers. The
e2e script waits for the new leader for the same reason: during a rollout,
two pods briefly run, and only the leader should probe. Sharding work across
replicas is a Chapter 21 topic.

*RBAC is the operator's whole privilege set.* The markers produced a
ClusterRole with `get`, `list` and `watch` on Services, `create` and `patch`
on `events.k8s.io` Events, full control of PrometheusRules, and the
HealthCheck resources with their `status` and `finalizers` subresources.
Notice what is absent: no Secrets, no Pods, no wildcards. Chapter 31 goes
further, with namespace-scoped Roles for multi-tenant clusters and auditing
what an operator actually uses.

#interview(title: [“Walk me through an operator you built.”])[
  Use `watchtower` as the spine and spend your time on decisions, not on the
  API. Status design for write economy (saturating counters, no timestamps,
  stable messages). Owned versus external resources (owner references and
  garbage collection versus finalizers with UID-tagged idempotency).
  Server-side apply and what `ForceOwnership` means. Why
  `GenerationChangedPredicate`, why a field-indexed Service watch, the
  cadence gate and the bug that motivated it, and the capacity math on
  reconcile workers. Then testing: a pure state machine, envtest for the
  API-server-dependent behaviour, and kind for the image. Interviewers for
  platform roles are listening for whether you understand what your
  controller costs the API server and what happens when things fail.
]

#takeaways(
  [Write an operator when domain knowledge must run continuously against declarative state that already lives in Kubernetes. Otherwise prefer a CLI, a Job, or a chart.],
  [controller-runtime is level-triggered: the queue holds keys, reads come from an eventually consistent cache, and reconcilers must be idempotent.],
  [Put validation and defaults in the CRD schema with markers and CEL; it is enforced before your code runs. Regenerate after every marker change.],
  [Design status for write economy: conditions, `observedGeneration`, stable messages, no per-probe timestamps. Metrics carry the high-frequency data.],
  [Write status only when it changed, filter your own writes with `GenerationChangedPredicate`, and jitter periodic requeues.],
  [Reconciles arrive for many reasons besides the timer. Gate expensive or time-sensitive work on whether it is actually due.],
  [Owned in-cluster objects: controller owner references, server-side apply with a field owner, cache comparison, and an `Owns` watch for self-healing.],
  [External objects: add the finalizer first, make creation idempotent with a stable key such as the object UID, treat "already gone" as success, and gate expensive syncs on generation.],
  [Test in three layers: pure logic, envtest for API semantics, kind for the deployable artifact. Each layer catches bugs the others can't.],
)

#exercise-set(20,
  (tier: "warm-up", title: [Why did it fail?],
   body: [`kubectl get hc -o wide` shows the target but not the reason a check is failing; you need `describe` for that. Add a `Last Failure` printer column showing `.status.lastFailure`, visible only with `-o wide`, after `Target`. The acceptance test reads the generated CRD.],
   hint: [One marker line and `make manifests`. Look at how `Target` hides itself from the default view.],
   tests: "workbook/ch20/exercises/ex1"),
  (tier: "warm-up", title: [Suspended means silent],
   body: [A check that is suspended while failing keeps exporting `watchtower_healthcheck_up 0` from its last probe, so its alert fires for as long as it is paused. Make `reconcileHealth` drop a suspended check's series. Base: step 4.],
   hint: [The function that clears a deleted check's series already exists.],
   tests: "workbook/ch20/exercises/ex2"),
  (tier: "core", title: [Webhook-free immutability],
   body: [Make `spec.target` immutable once set, with a CEL transition rule, and the message `target is immutable; create a new HealthCheck instead`. Other fields must stay editable. Why would you want this for a monitoring resource, and what does a user do instead of editing the target? Base: step 3.],
   hint: [`self == oldSelf` on the field. Transition rules only run on updates.],
   tests: "workbook/ch20/exercises/ex3"),
  (tier: "core", title: [Drift resync for external rules],
   body: [Datadog monitors are pushed only when the generation changes, so edits made in Datadog's UI stick. Add `AlertResync time.Duration` to the reconciler (and an `--alert-resync` flag): when non-zero, an external rule that is in sync is pushed again once that much time has passed since its last push. The tests run in a `synctest` bubble, so half an hour passes instantly.],
   hint: [Remember the last push per object in memory, like `lastProbe`. `time.Now` is virtual inside the bubble.],
   tests: "workbook/ch20/exercises/ex4"),
  (tier: "core", title: [A Grafana backend: design review],
   body: [Grafana-managed alert rules can be provisioned through Grafana's HTTP API (`/api/v1/provisioning/alert-rules`). Sketch a `grafana` backend: is it `External`? How do you make creation idempotent, and what happens to rules created through the API when someone edits them in the UI? No code; write the design you would defend.],
   hint: [Look at what the provisioning API lets the client choose, and at the `X-Disable-Provenance` header.]),
  (tier: "stretch", title: [Backend-aware finalizers],
   body: [Switching `--alert-backend` from `datadog` to `prometheus` leaves Datadog finalizers that the new backend "cleans up" by doing nothing, orphaning the monitors. Name finalizers after their backend (`watchtower.platformgo.dev/cleanup-datadog`, from `finalizerFor`), and make `finalize` refuse to remove another backend's finalizer: return an error wrapping `ErrBackendMismatch` and emit a `CleanupBlocked` Event that says which operator configuration can clean up.],
   hint: [`strings.CutPrefix` splits the backend name off the finalizer. Update the existing finalizer test too.],
   tests: "workbook/ch20/exercises/ex5"),
  (tier: "stretch", title: [Respect Datadog's rate limit],
   body: [When Datadog answers 429, it sends `X-RateLimit-Reset`, the seconds until the limit window resets. Return an `*alerting.RateLimitedError` with `RetryAfter` (a minute if the header is missing or invalid, at most an hour), report `AlertingReady=False` with a new reason `RateLimited`, and make `reconcileAlerting` return the wait so `Reconcile` comes back no later than that. Why is the cadence gate from step 8 what makes the early reconcile safe?],
   hint: [`errors.AsType` finds the error through `%w` wrapping. `min` is a builtin.],
   tests: "workbook/ch20/exercises/ex6"),
)
