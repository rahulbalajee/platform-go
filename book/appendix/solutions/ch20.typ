#import "../../template/book.typ": *

#solutions-for(20, "Building Operators with controller-runtime")

#solution(20, 1, title: [Why did it fail?], code: "solutions/ch20/ex1")[
  One marker, after `Target` so the column order matches the test:

  #src("solutions/ch20/ex1/api/v1alpha1/healthcheck_types.go", region: "kind")

  `priority=1` is what keeps it out of the default view: `kubectl get`
  shows priority-0 columns, `-o wide` shows all of them. Then
  `make manifests`. The acceptance test reads
  `config/crd/bases/watchtower.platformgo.dev_healthchecks.yaml`, so it
  fails until you regenerate, which is the lesson of step 2's first
  troubleshooting row. The trap is putting the failure text in a
  priority-0 column: messages can be long, and the default view of
  `kubectl get hc` was designed to fit 80 columns.
]

#solution(20, 2, title: [Suspended means silent], code: "solutions/ch20/ex2")[
  The suspended branch of `reconcileHealth` forgets the check's series before
  returning:

  #src("solutions/ch20/ex2/internal/controller/healthcheck_controller.go", region: "health")

  Dropping the series, rather than setting `up` to 1, is the honest answer:
  a paused check has no opinion about its target, and an absent series makes
  the generated alert expression (`== 0`) match nothing. When the user
  resumes the check, the next probe recreates the series. The alternative,
  deleting the PrometheusRule while suspended, is heavier and fights the
  `Owns` watch for no benefit. The test calls `reconcileHealth` on an empty
  reconciler: a suspended check needs no client, prober or recorder, and the
  test proves it.
]

#solution(20, 3, title: [Webhook-free immutability], code: "solutions/ch20/ex3")[
  A transition rule on the field:

  #src("solutions/ch20/ex3/api/v1alpha1/healthcheck_types.go", region: "spec")

  Rules that mention `oldSelf` run only on updates, so creation is
  unaffected. The rule sits on `target` rather than on the whole spec, so
  `interval` and `failureThreshold` stay editable. The first acceptance test
  reads the generated CRD and needs no API server; the second proves the
  rule against envtest.

  Why bother: a HealthCheck's history (its conditions, its metric series,
  its alert's firing history and silences) is about one endpoint. Silently
  pointing `payments-api` at a different URL would splice two endpoints'
  histories together, and an incident review would read it wrong. The user
  creates a new HealthCheck and deletes the old one, which is also what
  GitOps does when a name changes. The trap: with an immutable field,
  `kubectl apply` of an edited manifest fails, so say so in the field's
  doc comment, which `kubectl explain` shows.
]

#solution(20, 4, title: [Drift resync for external rules], code: "solutions/ch20/ex4")[
  The reconciler remembers when it last pushed each rule, in memory, like
  `lastProbe`:

  #src("solutions/ch20/ex4/internal/controller/healthcheck_controller.go", region: "reconciler")

  The gate in `reconcileAlerting` gains one condition, and a successful
  `Ensure` records the time:

  #src("solutions/ch20/ex4/internal/controller/healthcheck_controller.go", region: "alerting")
  #src("solutions/ch20/ex4/internal/controller/healthcheck_controller.go", region: "resyncdue")

  `main.go` adds the flag `--alert-resync` (default 0, off) and passes it in.
  The test runs inside `synctest.Test`, where `time.Now` and `time.Sleep`
  use a virtual clock: sleeping 29 minutes takes no real time, and the
  assertions about "not yet" and "now" are exact. Keeping the timestamp in
  memory means a restarted operator resyncs every external rule once. That
  is a reasonable drift check after an upgrade, but at 2,000 checks it is a
  burst against Datadog's rate limit, which Exercise 20.7 handles. Comparing
  with `AlertingReady`'s `lastTransitionTime` instead doesn't work: that
  time only moves when the condition changes, so a long-healthy rule would
  be pushed on every reconcile once it is old enough.
]

#solution(20, 5, title: [A Grafana backend: design review])[
  *External: yes.* The rules live in Grafana's database, not in the cluster,
  so owner references can't clean them up. The backend needs the finalizer
  path, exactly like Datadog, even when Grafana itself runs in the same
  cluster.

  *Idempotency is easier than with Datadog.* The provisioning API lets the
  client choose the rule's `uid`. Derive it from the HealthCheck's UID, and
  `Ensure` becomes "update by uid, create if missing": no tag search, and a
  crash between create and status write can't produce a duplicate, because
  a second create with the same uid fails instead of making a twin.

  *Provenance.* Rules created through the provisioning API are marked as
  provisioned, and Grafana's UI refuses to edit them unless the request
  sent `X-Disable-Provenance`. Keep the default. A UI edit that the
  operator would later overwrite is worse than one the UI refuses, and the
  refusal points the user at the HealthCheck, which is the source of
  truth. It also removes most of the need for Exercise 20.4's resync.

  *The rest.* Rules belong to a folder and a rule group, so the backend
  needs a folder per namespace (created idempotently) and a group per
  check. Credentials are a service-account token from a Secret via an
  environment variable, as with Datadog. A Grafana rule queries a data
  source, so the backend also needs to know which Prometheus data source
  holds `watchtower_healthcheck_up`: one more flag. `ddfake` is the template
  for the fake you would test it with.
]

#solution(20, 6, title: [Backend-aware finalizers], code: "solutions/ch20/ex5")[
  The finalizer name carries the backend, and a sentinel error names the
  failure:

  #src("solutions/ch20/ex5/internal/controller/healthcheck_controller.go", region: "consts")
  #src("solutions/ch20/ex5/internal/controller/healthcheck_controller.go", region: "finalizerfor")

  `Reconcile` adds `finalizerFor(r.Alerts.Name())`, and `finalize` looks for
  a finalizer it doesn't own before doing anything else:

  #src("solutions/ch20/ex5/internal/controller/healthcheck_controller.go", region: "finalize")

  Returning an error keeps the object, and the reconcile retries with
  backoff. That is deliberate: the HealthCheck stays visible, with an Event
  that says what will release it, until someone runs an operator that can
  delete the Datadog monitor, or removes the finalizer by hand after
  cleaning up. The trap is the migration itself: HealthChecks created by
  the old version carry `alert-cleanup`, which has no backend in its name.
  A real rollout either rewrites old finalizers to `cleanup-datadog` once,
  or treats the legacy name as Datadog's. The existing finalizer test
  changes to expect `finalizerFor("datadog")`.
]

#solution(20, 7, title: [Respect Datadog's rate limit], code: "solutions/ch20/ex6")[
  The error type lives next to `ErrUnavailable`:

  #src("solutions/ch20/ex6/internal/alerting/alerting.go", region: "ratelimited")

  `do` turns a 429 into it before the generic error path, and `retryAfter`
  bounds the header:

  #src("solutions/ch20/ex6/internal/alerting/datadog.go", region: "ddbody")

  `reconcileAlerting` returns a retry hint, and `Reconcile` takes the
  earlier of the probe interval and the hint:

  #src("solutions/ch20/ex6/internal/controller/healthcheck_controller.go", region: "reconcile")
  #src("solutions/ch20/ex6/internal/controller/healthcheck_controller.go", region: "alerting")

  Returning `RequeueAfter` instead of the error matters: an error would
  feed the exponential backoff, which knows nothing about Datadog's window,
  and count as a reconcile failure in the metrics. Bounding the header
  matters too: a missing or garbage header must not mean "retry
  immediately", and a huge one must not park the check for a day. The
  cadence gate is what makes the early reconcile safe: without it, coming
  back after 7 seconds on a 10-second interval would probe early, which is
  the step 8 bug again. The condition message leaves out the wait, so it
  doesn't change on every rate-limited attempt and cause a status write.
]
