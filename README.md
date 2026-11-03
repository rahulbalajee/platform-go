# Platform Go

Companion code for **Platform Go: Production-Grade Tools, Operators, Services,
and AI Systems for Platform Engineering** (Go 1.27 edition).

Every listing in the book is read from this repository when the book is
built, and every package here compiles, lints clean, and passes
`go test -race` in CI.

## Layout

| Path | What |
|---|---|
| `pkg/conc` | Leak-free concurrency helpers: `Map` (ordered, fail-fast), `Stream` (iterator, collect-all), `KeyedSemaphore` |
| `pkg/retry` | Context-aware retries with full jitter, `Permanent`, `After` (Retry-After), and a Go 1.27 generic method |
| `pkg/lifecycle` | Two-stage signal handling: first Ctrl-C cancels, second exits 130 |
| `cmd/sweep`, `internal/sweep` | Chapter 4: concurrent fleet checker (HTTP, TCP, TLS, DNS) |
| `examples/` | Small focused programs (e.g. the goroutine leak profile demo) |
| `projects/watchtower` | Chapter 20: Kubernetes monitoring operator (own Go module, kubebuilder layout) |
| `book/` | Typst sources for the book, fonts, captured terminal output, build scripts |

## Quick start

```sh
go test -race ./...                       # root module
go run ./cmd/sweep -timeout 3s book/output/fleet.txt

make -C projects/watchtower test          # operator unit + envtest suites
projects/watchtower/hack/e2e-kind.sh      # deploy to a kind cluster and assert

make book                                 # build platform-go.pdf (Typst 0.15)
```

Requirements: Go 1.27 (the `toolchain` line in `go.mod` lets older Go
installs download it automatically), Docker and kind for the e2e test, and
Typst 0.15 for the book.
