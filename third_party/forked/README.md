# Forked code

Small packages copied into this repository instead of required as modules,
each with its original license and copyright notices.

| Directory | Origin | Version | License | Changes |
| --- | --- | --- | --- | --- |
| `jsonpath/` | `k8s.io/client-go/util/jsonpath` | v0.37.2 | Apache-2.0 (`jsonpath/LICENSE`) | import path of the template package |
| `golang/template/` | `k8s.io/client-go/third_party/forked/golang/template`, itself from Go's `text/template` | v0.37.2 | BSD-3-Clause (`golang/LICENSE`, `golang/PATENTS`) | none |

Why: `pkg/cli/output` implements `-o jsonpath=` with kubectl's dialect.
Requiring `k8s.io/client-go` for these ~1,300 lines of standard-library-only
code would add 37 modules to the root module's build list (96 without it,
133 with it, measured after Chapter 10's dependencies), and would apply
Kubernetes' version requirements to every command-line tool in the root
module. Chapter 9 of the book measures this.

The upstream tests are kept and run in CI. To update, copy the same files
from the new client-go version, re-apply the import-path change, and update
the version above.
