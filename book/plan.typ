// The planned table of contents. Chapters with a `label` are included in
// this build and get real page numbers; the rest are listed as planned.
#let plan = (
  (numeral: "I", title: "Foundations: Go for Systems Work",
   blurb: [The language and runtime from a platform engineer's point of view: what makes Go the default for infrastructure, and the disciplines that keep tools correct under concurrency, failure, and change.],
   chapters: (
    (1, "The Platform Engineer's Go: Toolchain, Modules, and the Monorepo", <ch-toolchain>, [Go 1.27 toolchain, `toolchain` and `tool` directives, workspaces, project layout, linting, and the companion monorepo.]),
    (2, "Designing Go APIs That Last", <ch-api-design>, [Small interfaces, functional options, generics and Go 1.27 generic methods, package boundaries, and API stability for internal SDKs.]),
    (3, "Errors, Exit Codes, and Failure as a Feature", <ch-errors>, [Wrapping, `errors.AsType`, typed errors, `errors.Join`, exit-code contracts, panics at boundaries, and user-facing versus operator-facing messages.]),
    (4, "Concurrency Patterns for Production Tooling", <ch-concurrency>, [Scheduler internals, structured concurrency, contexts and causes, bounded parallelism, retries with jitter, singleflight, two-stage shutdown, `synctest`. Builds `sweep`.]),
    (5, "Talking to the Operating System: I/O, Files, Processes, and Signals", <ch-os>, [Streaming I/O, `io/fs` and `os.Root`, atomic writes and locks, `os/exec` with process groups, PTYs, `/proc` and cgroups v2.]),
    (6, "Testing Tools That Touch the Real World", <ch-testing>, [Golden files, `testscript` for CLIs, fakes over mocks, `testcontainers-go`, fuzzing, benchmarks with `b.Loop`, integration coverage with `GOCOVERDIR`.]),
  )),
  (numeral: "II", title: "Command-Line Tools Developers Love",
   blurb: [The developer-experience layer: CLIs that are predictable for humans and machines, configurable without surprises, extensible by other teams, and shipped like real software.],
   chapters: (
    (7, "Anatomy of a Production CLI", none, [Cobra in depth, the testable `run` pattern, command design, completion and generated docs, exit codes, `clig.dev` guidelines.]),
    (8, "Configuration, Contexts, and Credentials", none, [Layered config (defaults, files, env, flags), kubectl-style contexts, OS keychains, OAuth2 device flow and OIDC login for CLIs.]),
    (9, "Output for Humans and Machines", none, [TTY detection, tables, JSON and YAML contracts, JSONPath and templates, progress UIs, and TUIs with Bubble Tea.]),
    (10, "Extensible Tools: Plugins, Policies, and WebAssembly", none, [kubectl/gh-style executable plugins, gRPC plugins, CEL policies, and sandboxed WASM extensions with wazero.]),
    (11, "Shipping Tools: Releases, Signing, SBOMs, and Self-Update", none, [Reproducible builds, GoReleaser, cosign keyless signing, SLSA provenance, SBOMs, Homebrew taps, and verified self-update.]),
  )),
  (numeral: "III", title: "Services and Distributed Systems",
   blurb: [The backend skills platform roles expect: networking fundamentals, production HTTP and gRPC, resilience patterns, data and event systems, and observability designed in from the start.],
   chapters: (
    (12, "Networking for Platform Engineers: DNS, TLS, Proxies, and Load Balancing", none, [Resolvers, TLS and mTLS, building a reverse proxy and load balancer, health checking, and how service meshes work.]),
    (13, "Production HTTP Services", none, [`net/http` routing patterns, middleware, timeouts everywhere, graceful drain in Kubernetes, OpenAPI, authn/authz.]),
    (14, "gRPC, Protobuf, and ConnectRPC", none, [buf for schemas and breaking-change checks, interceptors, deadlines, streaming, rich errors, health and reflection.]),
    (15, "Resilience Engineering: Circuit Breakers, Bulkheads, and Load Shedding", none, [Breakers, retry budgets, hedging, adaptive concurrency, idempotency keys, and fault injection.]),
    (16, "Data and Events: PostgreSQL, Redis, Kafka, and Cloud Queues", none, [pgx and migrations, the outbox pattern, Redis locks and caches, Kafka with franz-go, SQS/SNS and Pub/Sub behind one interface.]),
    (17, "Observability by Design: OpenTelemetry, Prometheus, and Vendor-Neutral Telemetry", none, [Traces, metrics and logs with OpenTelemetry, Prometheus exposition, exemplars, SLIs and SLOs, exporting to Datadog, Grafana, Jaeger and ELK.]),
  )),
  (numeral: "IV", title: "Kubernetes and the Cloud",
   blurb: [Programming the platforms themselves: cloud SDKs without lock-in, the Kubernetes API from first principles, and operators built to production standards.],
   chapters: (
    (18, "Cloud SDKs Without Lock-In: AWS, GCP, and Azure Behind One Interface", none, [Credential chains and workload identity (IRSA, Pod Identity, GKE and AKS), pagination, waiters, and testing with fakes and LocalStack.]),
    (19, "Kubernetes Programming with client-go", none, [GVKs and GVRs, typed, dynamic and unstructured clients, informers and workqueues, server-side apply, and a controller from scratch.]),
    (20, "Building Operators with controller-runtime", <ch-operators>, [CRD design, reconcilers, owned and external resources, finalizers, watches and indexes, envtest and kind. Builds `watchtower`.]),
    (21, "Operators in Production: Webhooks, Versioning, Scale, and Packaging", none, [Admission webhooks, CRD versioning and conversion, sharding, cache tuning, a dedicated prober pool, Helm and OLM packaging.]),
  )),
  (numeral: "V", title: "Flagship Projects",
   blurb: [Four complete systems, each built from an empty directory to a tested, deployable tool, and each designed to run on AWS, GCP, Azure, or a laptop.],
   chapters: (
    (22, "forge: A Multi-Cloud Infrastructure Provisioner", none, [Plan/apply/drift with a resource DAG, provider plugins for AWS, GCP, Azure and local Docker, state locking, and Terraform interop via terraform-exec.]),
    (23, "ship, Part 1: A Deployment CLI Across GitHub Actions, GitLab, and Jenkins", none, [Environment promotion from dev to staging to prod, CI provider adapters, approvals, audit trails, and `sweep`-based health gates.]),
    (24, "ship, Part 2: GitOps Promotion, Progressive Delivery, and Rollback", none, [Promotion by pull request to config repos for Argo CD and Flux, canary and blue-green with Argo Rollouts and Flagger, metric-driven automated rollback.]),
    (25, "sentinel, Part 1: A Host and Container Monitoring Agent", none, [`/proc` and cgroup v2 collection, container runtimes, log tailing, batching with a WAL, and shipping over gRPC and OTLP.]),
    (26, "sentinel, Part 2: A Time-Series Database from Scratch", none, [Gorilla compression, head block and WAL, inverted label index, compaction and retention, and a PromQL-subset query engine.]),
    (27, "sentinel, Part 3: Alerting, Routing, and Integrations", none, [Rule evaluation, alert state machines, grouping, inhibition and silences, PagerDuty and Slack routing, a Grafana-compatible API, Datadog and ELK sinks.]),
    (28, "oncall: An AI Incident Investigator", none, [A provider-agnostic LLM layer (Anthropic, Bedrock, OpenAI-compatible and Ollama), tool calling over Kubernetes, ECS and telemetry backends, redaction, and evaluation.]),
    (29, "MCP Servers in Go: Exposing Your Platform to AI Agents", none, [The official Go MCP SDK, tools, resources and prompts, stdio and streamable HTTP transports, OAuth, guardrails, and audit.]),
  )),
  (numeral: "VI", title: "Production Excellence",
   blurb: [What separates a tool that works from a platform people trust: performance under load, security by default, and an architecture other teams can build on.],
   chapters: (
    (30, "Performance Engineering: pprof, Tracing, PGO, and the Garbage Collector", none, [CPU, heap and mutex profiles, execution traces and the flight recorder, escape analysis, PGO, `GOMEMLIMIT` and the Green Tea collector.]),
    (31, "Security for Platform Tools: IAM, RBAC, Secrets, and Supply Chain", none, [Threat modeling tools and operators, least privilege across clouds and clusters, KMS envelope encryption, External Secrets, `govulncheck`, SLSA.]),
    (32, "Architecting the Internal Developer Platform", none, [Golden paths, platform APIs, Backstage integration, multi-tenancy, versioning and deprecation, and measuring developer experience with DORA and SPACE.]),
  )),
)

#let appendices = (
  ("A", "Go 1.21 to 1.27: A Field Guide for Platform Engineers"),
  ("B", "The Interview Playbook: System Design and Deep-Dive Questions"),
  ("C", "Running the Companion Repository Locally"),
)
