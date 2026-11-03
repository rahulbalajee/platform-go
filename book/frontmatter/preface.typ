#import "../template/book.typ": *
#import "../plan.typ": plan

#heading(level: 1, numbering: none)[Preface] <preface>

Most Go books stop where platform work begins. They teach the language,
then a CLI that reads a file, then an HTTP client, and leave you to work out
the rest in production: what happens when the tool runs against 3,000
endpoints, when #kbd("Ctrl-C") arrives mid-deploy, when a controller writes
status 30 times a second, or when the monitoring stack in one cluster is
Prometheus and in the next it is Datadog.

This book starts at that line and stays there. It is written for DevOps,
platform, and site reliability engineers who know some Go, or are fluent in
another language, and want to build the tools their organization runs on:
CLIs developers reach for every day, Kubernetes operators, deployment
systems, monitoring pipelines, and AI agents that help on-call engineers find
root causes faster.

=== What is different about this book

*Everything runs.* Every listing is pulled from the companion repository when
the book is built, from files that compile and pass `go vet`,
`golangci-lint`, and `go test -race` in CI. Terminal sessions are captured
from real runs. When a chapter says a test takes 0.00 seconds while
simulating six seconds of timeouts, that is the output the test produced.

*Production first.* Each chapter's code is built the way you would build it
at work: bounded concurrency, timeouts and cancellation everywhere, retries
that can't amplify an outage, status that doesn't overload the API server,
idempotent handling of external systems, and tests at the right layer. The
text spends its time on _why_, because the decisions are what transfer to your
own systems and what interviewers ask about.

*Stack-agnostic by design.* Real platforms are mixed. The projects run on
AWS, GCP, or Azure; on EKS, GKE, AKS, or kind; against Prometheus, Grafana,
Datadog, or ELK; with GitHub Actions, GitLab, or Jenkins; delivered by Argo CD
or Flux. Each integration sits behind an interface chosen at startup, and
the book shows how to design those seams.

*Current.* The book targets Go 1.27 and calls out every feature by version:
generic methods, `testing/synctest`, `httptest.NewTestServer`, container-aware
`GOMAXPROCS`, `WaitGroup.Go`, `errors.AsType`, the goroutine leak profile,
and more. Kubernetes code targets the 1.37 APIs with controller-runtime 0.25.

=== How the book is organized

#for part in plan {
  block(above: 0.9em, below: 0.5em, breakable: false)[
    #text(font: fonts.sans, size: 8pt, weight: "bold", fill: c.go, tracking: 0.12em)[PART #part.numeral]
    #h(4pt) #text(font: fonts.sans, size: 9.6pt, weight: "bold", fill: c.navy)[#part.title]
    #v(2pt)
    #text(size: 9.6pt)[#part.blurb]
  ]
}

Parts I and II are cumulative: the packages built there (`pkg/conc`,
`pkg/retry`, `pkg/lifecycle`, and the CLI framework of Chapter 7) are reused
by every project after them. From Part III on, chapters can be read in the
order your work needs them. If you are preparing for interviews, read
Chapter 4, Chapter 20, and Appendix B first, then the flagship project
closest to the role.

=== Conventions

Code identifiers, commands and file paths are set in `monospace`. Listings
show their path in the repository in a tab above the code. Dark blocks are
terminal sessions: lines starting with `$` are commands, everything else is
output. Callouts mark material you may want to find again:

#note[Background or a clarification that doesn't fit the main flow.]
#warning[A mistake that is easy to make and expensive to discover in production.]
#production[How the topic plays out at scale, in real clusters and real organizations.]
#interview[How to talk about the topic in a technical interview, and what a strong answer covers.]
#newingo("1.27")[A feature that requires a specific Go version (here, 1.27 or later).]

=== The companion repository

The code lives in one repository, organized as a monorepo with independent
modules where dependencies differ:

#code(file: "github.com/rahulbalajee/platform-go")[```
platform-go/
├── pkg/            reusable libraries: conc, retry, lifecycle, ...
├── internal/       code shared by the tools in this module
├── cmd/            small tools built in Parts I–II (sweep, ...)
├── examples/       focused programs that demonstrate one idea
├── projects/       flagship projects, each its own Go module
│   └── watchtower/ the Kubernetes operator from Chapter 20
├── book/           this book's Typst sources; listings are read from the code
└── .github/        CI: build, vet, lint, race tests, envtest, and the book
```]

To run everything in Chapter 4, clone the repository and run
`go test -race ./...` at the root. The operator's tests need envtest
binaries, which `make test` in `projects/watchtower` downloads for you.
Appendix C covers running every project locally, including the kind-based
end-to-end tests.

#pagebreak(weak: true)
#heading(level: 1, numbering: none)[The skills map] <skills-map>

Platform job descriptions draw on a familiar set of skills. This map
connects each one to the chapters that build it, so you can plan your
reading around the roles you are targeting, and so that in an interview you
can point to something you have actually built.

#{
  set text(size: 8.6pt)
  table(
    columns: (1.25fr, 2fr, auto),
    align: (left, left, left),
    table.header([Skill area], [What the book builds], [Chapters]),
    [Go, CLIs, Cobra, developer tooling], [`sweep`; a CLI framework with contexts, credentials and plugins; signed, self-updating releases], [1–11],
    [Distributed systems, concurrency, resilience], [bounded fan-out, retry budgets, circuit breakers, load shedding, idempotency], [4, 15],
    [Networking: DNS, TLS, HTTP, load balancing, service mesh, CDNs], [a reverse proxy and load balancer, mTLS, and a working model of how meshes route], [12],
    [REST APIs, gRPC, protobuf], [production HTTP services, gRPC and Connect services with buf, interceptors and deadlines], [13, 14],
    [PostgreSQL, Redis, Kafka, Pub/Sub, SQS/SNS], [the outbox pattern, caches and locks, consumers, and a portable queue interface], [16],
    [Observability: OpenTelemetry, Prometheus, Grafana, Jaeger, Datadog, ELK, CloudWatch], [instrumented services, a monitoring agent, a TSDB, and alerting with integrations], [17, 20, 25–27],
    [SLOs, SLIs, incident response, PagerDuty, runbooks, RCA], [SLO-based alerting, routing to on-call, and an AI investigator that drafts root-cause analyses], [17, 27, 28],
    [Kubernetes, Helm, operators, EKS, GKE, AKS], [a controller from scratch, the `watchtower` operator, webhooks, versioning, packaging], [19–21],
    [AWS, GCP, Azure; Terraform, infrastructure as code], [a multi-cloud provisioner with plan/apply, drift detection, and Terraform interop], [18, 22],
    [CI/CD: GitHub Actions, GitLab CI, Jenkins], [`ship`: promotions, approvals, and health gates across CI providers], [23],
    [GitOps: Argo CD, Flux; canary and blue/green], [promotion by pull request, progressive delivery, and metric-driven rollback], [24],
    [Security: IAM, RBAC, KMS, OAuth2, External Secrets, vulnerability management], [least-privilege operators, OIDC login for CLIs, envelope encryption, supply-chain controls], [8, 11, 31],
    [AI-assisted operations: LLM incident triage, agents, MCP], [`oncall` with a provider-agnostic LLM layer, and MCP servers for your platform], [28, 29],
    [Performance engineering], [profiling, tracing, PGO, GC tuning on real workloads from the book], [30],
    [Platform architecture and developer experience], [golden paths, platform APIs, Backstage, DORA metrics], [32],
  )
}
