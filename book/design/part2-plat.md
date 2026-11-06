# Part II design: `plat`, a developer-platform CLI

Part II (Chapters 7 to 11) builds one tool, `plat`, on top of a reusable CLI
framework, `pkg/cli`. The chapters are cumulative: Chapter N's first build
step is Chapter N-1's last. Later projects (ship, forge, oncall) reuse
`pkg/cli`, so its API is designed for more than one tool.

Decisions confirmed by the user:

- The tool is `plat`, a CLI for the platform API that Chapter 2's SDK
  (`pkg/platformapi`) talks to: login, services, environments, deploy,
  deployments, logs, plugins.
- Chapter 11 publishes for real: tagged GitHub Releases on
  rahulbalajee/platform-go, cosign keyless signatures (public Rekor entries),
  SLSA build provenance, and a Homebrew tap in a new public repo
  rahulbalajee/homebrew-tap.
- Chapter 8 login: an in-repo OIDC provider that every build step uses
  (offline, testable), plus a real "log in with GitHub" via the device flow
  and a GitHub OAuth App that the user registers (public client ID only).

## Where the code lives

`plat` lives in the root module, so `go install
github.com/rahulbalajee/platform-go/cmd/plat@latest` works and a release tag
`vX.Y.Z` is both the module version and the `plat` version. A separate module
would need a `replace` directive for the root packages it uses, and
`go install pkg@version` refuses modules with `replace` directives. The
editor adds Part II dependencies to the root `go.mod`; authors don't.

```
cmd/plat/                 main: wires pkg/cli to internal/plat
cmd/platformd/            dev backend: the fake API + dev OIDC provider
internal/plat/
  cmd/                    one file per command group (cobra commands)
  factory/                the Factory: lazily built dependencies
  policy/                 CEL deploy policies (Ch 10)
  wasmext/                wazero-hosted extensions (Ch 10)
  update/                 verified self-update (Ch 11)
pkg/cli/                  the framework, reused by later projects
  iostreams.go            In/Out/ErrOut, TTY detection, colour decisions
  run.go                  Main: signals, exit codes, error rendering
  errors.go               FlagError (usage, exit 2), SilentError, CancelError
  config/                 layered config, kubectl-style contexts (Ch 8)
  auth/                   credential stores, device flow, token refresh (Ch 8)
  output/                 printers: table, wide, json, yaml, jsonpath,
                          template; progress (Ch 9)
  plugin/                 executable plugin discovery and exec (Ch 10)
pkg/devidp/               a small OIDC provider for development and tests
```

Existing packages it builds on: `pkg/platformapi` (+ `platformapifake`),
`pkg/clierr` (exit codes, `Program`, `Secret`), `pkg/lifecycle`
(`NotifyContext`), `pkg/buildinfo`, `pkg/fsx` (atomic writes),
`pkg/retry`.

## Dependencies (versions checked 2026-11-06)

| Module | Version | Used for |
|---|---|---|
| github.com/spf13/cobra | v1.10.2 | commands, completion, `cobra/doc` |
| github.com/spf13/pflag | v1.1.0 | flags (via cobra) |
| golang.org/x/term | v0.47.0 | TTY detection, terminal width |
| golang.org/x/oauth2 | v0.37.0 | device flow (`DeviceAuth`), refresh |
| github.com/coreos/go-oidc/v3 | v3.21.0 | discovery, ID-token verification |
| github.com/go-jose/go-jose/v4 | v4.1.9 | devidp signing, JWKS |
| github.com/zalando/go-keyring | v0.2.8 | OS keychain credential store |
| sigs.k8s.io/yaml | v1.6.0 | config file, `-o yaml` |
| charm.land/bubbletea/v2 | v2.1.1 | `plat deployments watch` TUI |
| charm.land/lipgloss/v2 | v2.0.6 | TUI styling |
| github.com/google/cel-go | v0.32.0 | deploy policies |
| github.com/tetratelabs/wazero | v1.12.0 | sandboxed WASM extensions |
| github.com/hashicorp/go-plugin | v1.8.0 | gRPC plugins |
| github.com/sigstore/sigstore-go | v1.4.0 | verifying release signatures |
| GoReleaser | v2.20.0 | releases (CI tool, not a Go dependency) |
| cosign | v3.1.4 | keyless signing (CI tool) |
| syft | v1.57.0 | SBOMs (CI tool) |
| actions/attest-build-provenance | v4.2.2 | SLSA provenance (CI) |

JSONPath for `-o jsonpath=` is decided in Chapter 9 (k8s
`client-go/util/jsonpath` for kubectl compatibility versus a dependency-free
subset); write it down here when decided.

## The dev environment

`platformd` serves `platformapifake` and `pkg/devidp` on localhost:

```
platformd --addr 127.0.0.1:8484 [--auto-approve] [--token-ttl 10m]
  /v1/...                         the platform API (fake, in memory)
  /.well-known/openid-configuration, /jwks, /device, /token, /verify
```

With `--auto-approve` the provider approves device codes without a
browser, so capture scripts and testscript tests can log in. The API
middleware verifies bearer JWTs (issuer, audience `plat`, expiry) before
the fake sees the request.

## Commands, and the chapter that introduces each

| Command | Ch | Notes |
|---|---|---|
| `plat version` | 7 | `pkg/buildinfo`; `-o json` added in 9 |
| `plat completion bash\|zsh\|fish\|powershell` | 7 | cobra built-in |
| `plat docs man\|markdown DIR` | 7 | hidden; generated docs |
| `plat services list\|get` | 7 | dynamic completion of names |
| `plat envs list` | 7 | |
| `plat deploy SERVICE VERSION --env E [--wait]` | 7 | exit codes from `clierr` |
| `plat deployments list\|get\|cancel` | 7 | |
| `plat logs DEPLOYMENT [-f]` | 7 | streams; SIGPIPE-safe |
| `plat config view\|get-contexts\|use-context\|set-context\|delete-context` | 8 | |
| `plat login [--provider github] / logout / whoami / auth token` | 8 | |
| `-o table\|wide\|json\|yaml\|jsonpath=\|template=` | 9 | every read command |
| `plat deployments watch` | 9 | Bubble Tea TUI; plain stream when not a TTY |
| `plat <name>` → `plat-<name>` on PATH; `plat plugin list` | 10 | |
| `plat policy check` and policy enforcement in `deploy` | 10 | CEL |
| WASM pre-deploy checks | 10 | wazero, wasip1 modules |
| gRPC notifier plugins | 10 | go-plugin |
| `plat update` | 11 | sigstore-go verified |

## Rules the code follows (from clig.dev and the earlier chapters)

- Data to stdout, messages and progress to stderr. Machine output never
  changes shape without a new format name.
- Every command is a `func(opts *XOptions) error` "run" function that a test
  calls directly with a fake Factory; cobra only parses flags into options.
- Exit codes: 0 ok, 1 error, 2 usage (`FlagError`), 130 interrupted, and the
  `clierr` codes from Chapter 3 for temporary failures.
- No colour, spinners or prompts unless the stream is a TTY; `NO_COLOR` and
  `CLICOLOR_FORCE` are honoured; `--no-input` (and a non-TTY stdin) disables
  prompts.
- Tokens are `clierr.Secret`, never logged; `plat auth token` is the only
  command that prints one.
- Contexts and timeouts everywhere; Ctrl-C cancels cleanly (exit 130).

## Tests

- Unit tests call run functions with `factory.Test()` (buffers for IO, an
  `httptest` server running `platformapifake`, an in-memory credential store).
- `cmd/plat` has testscript tests (`testdata/script/*.txtar`) that run the
  real binary against an in-process `platformd`.
- TTY behaviour is tested through `creack/pty`.
- Everything passes `go test -race`, `golangci-lint` and the 86-column limit.
