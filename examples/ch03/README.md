# Chapter 3 examples: errors, exit codes, and failure as a feature

| Directory | What it shows |
| --- | --- |
| `deployctl/` | A deploy CLI built on `pkg/clierr` that triggers every failure mode for real |
| `fakeapi/` | The fake deployment API `deployctl` talks to (`fakeapi/cmd/fakeapi` serves it) |
| `chain/` | How `errors.Is`, `errors.As` and `errors.AsType` walk wrapped error trees |
| `gopanic/` | `recover` in `main` cannot stop a panic on another goroutine |
| `httppanic/` | What `net/http` does when a handler panics |

Run it by hand:

```sh
go run ./examples/ch03/fakeapi/cmd/fakeapi &
cd examples/ch03/deployctl/testdata
export DEPLOYCTL_TOKEN=dev-token
go run .. -config prod.json deploy v1.4.2; echo "exit $?"
```

## deployctl exit codes

| Code | Meaning | Retry? |
| --- | --- | --- |
| 0 | Success | |
| 1 | The deploy ran and some targets failed | After fixing the targets |
| 2 | Bad flags, arguments or config | No: fix the command |
| 70 | Internal error (a bug); a crash report was saved | No: report it |
| 75 | Timed out | Yes |
| 77 | Not authenticated or not allowed | No: fix the credentials |
| 130, 143 | Interrupted by SIGINT, SIGTERM | Yes, if you meant to |

## Error catalogue

### DPL-CONFIG

The config file is missing, unreadable, not valid JSON, or incomplete.
`deployctl init` writes a starter `deployctl.json`; `-config FILE` points at
another file. An unreadable file exits with 77, everything else with 2.

### DPL-AUTH

No token, or the deployment API rejected it. Export a fresh
`DEPLOYCTL_TOKEN`. If a fresh token is also rejected, give the platform team
the request ID from the hint: it is how they find your request in their logs.

### DPL-PARTIAL

Some targets were updated and some were not. Each failed target is listed
with the API's reason. Fix those targets and re-run with `-only` to retry
just them; the rollout is idempotent per target and version.

### DPL-TIMEOUT

The whole deploy did not finish within `-timeout` (default 30s). Targets that
were in flight may still converge. Check `deployctl status`, then re-run.

### DPL-INTERRUPTED

You pressed Ctrl-C (exit 130) or the process got SIGTERM (exit 143) during a
rollout. Targets already updated stay updated; re-run to finish the rest.
