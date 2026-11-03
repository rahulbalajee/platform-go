#import "../template/book.typ": *
#import "05-lib.typ": ts, needspace

#step(5, 13, "Atomic replacement", label: <sec-os-atomic>)

This is the first build step: the code goes into `fsx`, a package that
other programs in this module (and later chapters) import. The goal is a
`WriteFile` with the same signature as `os.WriteFile` that never shows a
reader a partial file and never loses the old file in a crash.

=== The six steps

The safe sequence writes a complete new file next to the old one and
swaps the name over in one atomic step. @fig-os-atomic shows the sequence
and what a crash at each point leaves behind.

Create `fsx/atomic.go`. It starts with the package documentation and
`WriteFile`, which is a thin wrapper over the general function:

#src("workbook/ch05/step5/fsx/atomic.go", region: "atomichead")

#fig(placement: auto, caption: [Atomic replacement. A crash at any point leaves either the complete old file or the complete new one under the target name, plus at worst a stray temporary file.])[
  #diagram(
    spacing: (18pt, 9pt),
    dnode((0, 0), [1 · `CreateTemp` in the same directory], kind: "accent"),
    dnode((0, 1), [2 · write the new contents], kind: "accent"),
    dnode((0, 2), [3 · `Chmod` to the final mode], kind: "accent"),
    dnode((0, 3), [4 · `Sync`: data reaches the device], kind: "accent"),
    dnode((0, 4), [5 · `Rename` temp → target (atomic)], kind: "dark"),
    dnode((0, 5), [6 · `Sync` the directory], kind: "accent"),
    dnode((1, 1), [crash: old file intact,\ temp file left over], kind: "good"),
    dnode((1, 3), [skip step 4: rename can reach disk\ before data → empty file], kind: "warn"),
    dnode((1, 5), [skip step 6: rename may be lost\ → old file comes back], kind: "warn"),
    dedge((0, 0), (0, 1), "-|>"),
    dedge((0, 1), (0, 2), "-|>"),
    dedge((0, 2), (0, 3), "-|>"),
    dedge((0, 3), (0, 4), "-|>"),
    dedge((0, 4), (0, 5), "-|>"),
    dedge((0, 1), (1, 1), "--"),
    dedge((0, 3), (1, 3), "--"),
    dedge((0, 5), (1, 5), "--"),
  )
] <fig-os-atomic>

`Write` takes a `fill` function instead of a byte slice, so a caller can
stream the new contents (from a template, an encoder, or standard input)
without building them in memory first. Add it below `WriteFile`:

#src("workbook/ch05/step5/fsx/atomic.go", region: "atomic")

Each numbered step exists for a reason:

+ *Same directory.* `rename(2)` is atomic only within one file system.
  Across file systems it fails with `EXDEV`, and `/tmp` is often a
  separate `tmpfs`. Creating the temporary file next to the target
  guarantees the rename is local. The leading dot keeps it out of most
  globs, so a config loader scanning `*.yaml` does not pick up a
  half-written file.
+ *Write.* Nobody can see the data yet, because nothing refers to the
  temporary name. A `bufio.Writer` turns many small writes from the
  caller's `fill` function into few system calls.
+ *Chmod.* `CreateTemp` creates files with mode `0600`. Without this step
  a world-readable config becomes private after its first atomic update,
  and the service running as another user stops reading it. (An explicit
  `Chmod` is not reduced by the umask, unlike the `perm` of `os.WriteFile`.)
+ *Sync the file.* Without it, the file system may persist the rename
  before the data blocks. After a crash the name points at the new inode
  and the inode is empty. This is the ext4 failure from lab 4.
+ *Rename.* POSIX guarantees that a process opening the target sees the
  old file or the new one, never neither. Readers that already have the
  old file open keep reading the old inode, which stays alive until they
  close it.
+ *Sync the directory.* The rename changed a directory entry, and
  directories are files with their own dirty pages. Until the directory is
  flushed, a crash can roll the rename back. Most file systems journal
  this, but only the directory `fsync` makes it a guarantee rather than a
  likely outcome.

`syncDir` differs by platform. On Unix a directory can be opened and
flushed like a file; on Windows it cannot, and NTFS journals the rename's
metadata itself. Create the two files:

#src("workbook/ch05/step5/fsx/syncdir_unix.go")
#src("workbook/ch05/step5/fsx/syncdir_windows.go")

Two idioms in `Write` are worth a closer look.

#goconcept(title: [`defer` for cleanup on failure])[
  `Write` has many exits, and all but the last must remove the temporary
  file. Rather than repeat the cleanup before each `return`, it records
  success in a variable (`renamed`) and defers one function that cleans up
  unless that variable is true. Deferred functions run after the return
  value is set, by any path, including a panic in `fill`. The pattern
  scales to any multi-step acquisition: set a flag on success, clean up in
  one deferred closure. It reads better than Python's `try/finally` with
  a flag only because it sits next to the acquisition.
]

#goconcept(title: [`bufio.Writer` and `Flush`])[
  `bufio.NewWriterSize(w, n)` collects small writes in an `n`-byte buffer
  and passes them to `w` in large chunks. The cost of that speed is a rule
  you must not forget: data still in the buffer when you stop is lost
  unless you call `Flush`, and `Flush` is where a write error from `w`
  finally appears. `Write` above calls `bw.Flush()` and checks it before
  the `Chmod`, `Sync` and `Rename`; forgetting it would rename a file that
  is missing its last few kilobytes.
]

#goconcept(title: [File modes])[
  `fs.FileMode` holds Unix permission bits, written in octal: `0o644` is
  read-write for the owner and read-only for everyone else, `0o600`
  owner-only, `0o755` for executables and directories. The type also
  carries type bits (`fs.ModeDir`, `fs.ModeSymlink`), and `m.Perm()`
  returns only the permission bits. Two traps: a mode passed when
  _creating_ a file is reduced by the process's umask (usually `022`), and
  the mode of an existing file is not changed by opening it with a
  different one. `f.Chmod(perm)` sets exactly what you ask.
]

The deferred cleanup removes the temporary file on any failure, so a full
disk does not leave `.config.yaml.tmp-*` files accumulating.

#internals(title: [The price of durability])[
  `torn -mode atomic` below manages a couple of hundred writes in two
  seconds. Almost all of that is `fsync`. On macOS, Go's `File.Sync`
  issues `fcntl(F_FULLFSYNC)`, because a plain `fsync` there only pushes
  data to the drive, whose own cache may still lose it; the full flush
  costs milliseconds. On Linux, `fsync` also asks the device to flush its
  volatile write cache, and costs anything from well under a millisecond
  on an enterprise NVMe drive to tens of milliseconds on network block
  storage. Atomic writes are for files that matter: config, state,
  checkpoints, credentials. A log file is append-only and needs neither
  the rename nor an `fsync` per line.
]

Renaming has limits: it replaces a symlink at the target name instead of
writing through it, the new inode loses hard links, extended attributes
and ownership unless you copy them, and it needs write permission on the
directory. On Windows, `os.Rename` maps to `MoveFileEx` with
`MOVEFILE_REPLACE_EXISTING`, which fails if another process holds the
target open without `FILE_SHARE_DELETE`.

=== Tests, with a leak check

The package gets its first test dependency: `goleak`, from Chapter 4,
fails the tests if any goroutine is still running at the end. `fsx`
starts no goroutines yet, but step 6's tests start processes and timers,
and it costs nothing to watch from the beginning. Add the module:

#output("ch05/s5-goget.txt", cmd: "go get go.uber.org/goleak@v1.3.0")

and create `fsx/main_test.go`:

#src("workbook/ch05/step5/fsx/main_test.go")

`TestMain`, if a test package defines it, runs instead of the tests; it
calls `m.Run` (here through `goleak.VerifyTestMain`) to run them. The
tests are in package `fsx_test`, outside the package, so they can only use
what a caller can use. Create `fsx/atomic_test.go` with the basic cases:

#src("workbook/ch05/step5/fsx/atomic_test.go", region: "basic")

`TestWriteFailureLeavesOldFileAndNoDebris` is the important one. Its
`fill` writes half a file and then fails, and the test checks both halves
of the promise: the old contents survive, and the directory contains
nothing but the original file. The last test checks the property `torn`
measured, with four readers against 200 rewrites:

#src("workbook/ch05/step5/fsx/atomic_test.go", region: "torn")

=== `torn -mode atomic`, and a command-line tool

Give `torn` the second write strategy. Replace the top of
`cmd/torn/main.go` (the comment gains a line, and the imports gain
`oskit/fsx`):

#src("workbook/ch05/step5/cmd/torn/main.go", region: "imports")

Replace `main`, to update the flag's help text:

#src("workbook/ch05/step5/cmd/torn/main.go", region: "main")

and `writer`, which now has two cases:

#src("workbook/ch05/step5/cmd/torn/main.go", region: "writer")

`fsx.WriteFile` has the same signature as `os.WriteFile`, so it is a
`writeFunc` too, and nothing else in `torn` changes.

`atomicput` wraps `fsx.Write` as a command that copies standard input to a
file, which is the shape a deploy script needs: `render-config | atomicput /etc/myapp/config.json`. Create `cmd/atomicput/main.go`:

#src("workbook/ch05/step5/cmd/atomicput/main.go")

Its `fill` function shows the other bounded-I/O idiom of this chapter: copy
through `io.LimitReader(os.Stdin, limit+1)`, and if more than `limit` bytes
arrived, fail. One extra byte detects an oversized input without ever
buffering it, and because the failure happens inside `fill`, the target
file is left exactly as it was.

#needspace(14em)
#checkpoint(step: 5, of: 13, title: [Atomic replacement])[
  `go mod tidy` has nothing left to change, and `go.mod` now requires
  goleak. `ls -C` lists the commands and the new package in columns:
  #output("ch05/s5-tidy.txt", cmd: "go mod tidy")
  #output("ch05/s5-tree.txt", cmd: "ls -C cmd fsx")
  #output("ch05/s5-test.txt", cmd: "go vet ./... && go test ./...")
  Compare the two write strategies:
  #output("ch05/s5-build.txt", cmd: "go build -o bin/ ./cmd/...")
  #output("ch05/s5-naive.txt", cmd: "bin/torn -mode naive")
  #output("ch05/s5-atomic.txt", cmd: "bin/torn -mode atomic")
  Write a file with `atomicput`, then try to replace it with input that is
  too large. The old contents survive, and no temporary file is left:
  #output("ch05/s5-put.txt", cmd: "echo '{\"replicas\": 3}' | bin/atomicput deploy.json && cat deploy.json")
  #output("ch05/s5-big.txt", cmd: "head -c 100 /dev/zero | bin/atomicput -max 10 deploy.json; echo \"exit status $?\"; cat deploy.json")
  #output("ch05/s5-debris.txt", cmd: "ls -a | grep deploy")
  #troubleshoot(
    ([#ts("s5-chmod.txt")], [Step 3, the `Chmod`, is missing, so the file keeps `CreateTemp`'s `0600`.], [Restore `f.Chmod(perm)` before the `Sync`.]),
    ([#ts("s5-debris-test.txt")], [The deferred cleanup is missing, so a failed `fill` leaves the temporary file behind.], [Restore the `defer` with the `renamed` flag. See "`defer` for cleanup on failure".]),
    ([#ts("s5-exdev.txt")], [The temporary file was created in the default temporary directory (`os.CreateTemp("", ...)`), here a `tmpfs` in a container, and `rename` cannot cross file systems.], [Create it in the target's directory. Step 1 of the six.]),
    ([#ts("s5-nogoleak.txt")], [The test imports goleak but `go.mod` does not require it.], [`go get go.uber.org/goleak@v1.3.0`.]),
  )
]

`torn -mode naive` tore thousands of reads; `-mode atomic` tore none, at
the price of far fewer writes per second, which is the `fsync` cost from
the box above.

#production(title: [Atomic config deploys])[
  Kubernetes ConfigMap and Secret volumes are updated the same way, one
  level up. The kubelet writes every key into a fresh timestamped
  directory, then atomically renames a symlink called `..data` to point at
  it. Each key in the mount is a symlink through `..data`, so a reader sees
  the whole old set or the whole new set. Two consequences catch people
  out. A file watcher on `config.yaml` sees no write event, because the
  file never changes; watch the directory, or poll. And a volume mounted
  with `subPath` bypasses the symlink and never updates at all. For files
  you deploy yourself, the rule is the one in this step: write the new
  version beside the old, `fsync`, rename, `fsync` the directory, then
  signal the service (lab 12). Exercise 5.6 builds the directory version.
]

#step(6, 13, "Locks", label: <sec-os-lock>)

Some tools must never run concurrently with themselves on one machine: a
backup that snapshots a database, a migration, a certificate renewal, a
node agent's upgrade step. Cron makes overlap easy: if Tuesday's run takes
longer than the interval, Wednesday's starts anyway. The usual answer is a
lock file, and there are several ways to build one. This step builds the
traditional one first, to see how it fails, and then the one that cannot.

=== The pid file and its problem

The traditional _pid file_ creates the file with `O_CREAT|O_EXCL`, which
fails if it exists, writes the process ID into it, and deletes it on exit.
`lockdemo` is a stand-in for a tool that must not run twice; it takes a
lock, "works" for a while and exits. Create `cmd/lockdemo/main.go`, which
supports both kinds of lock:

#src("workbook/ch05/step6/cmd/lockdemo/main.go", region: "lockdemohead")
#src("workbook/ch05/step6/cmd/lockdemo/main.go", region: "acquire")

Exit status 75 is `EX_TEMPFAIL` from `sysexits.h`, "try again later",
which tells a scheduler the failure is not a bug. The pid-file version is
`acquirePIDFile`, and its problem is the word "exit". Once the rest of the
step is in place, the checkpoint kills a holder with `kill -9`:

#output("ch05/s6-pidfile.txt")

`kill -9`, an OOM kill or a power cut skips the cleanup, and every later
run refuses to start until someone deletes the file by hand. Checking
whether the recorded PID is alive with `kill(pid, 0)` has two holes: PIDs
are reused, so an unrelated process may have that number (recording the
start time from `/proc/<pid>/stat` as well fixes this, step 8), and two
runs that both decide the file is stale can both delete it and both
proceed. The fix for the race is to stop using file existence as the
lock.

=== `flock`: a lock the kernel releases for you

`flock(2)` takes an advisory lock on an open file. The kernel ties the lock
to the open file description and releases it when the last descriptor
referring to it is closed, which happens automatically when the process
exits for any reason, including `SIGKILL`. A flock lock cannot go stale.

The standard library's `syscall` package is frozen, and new system call
wrappers live in `golang.org/x/sys`, maintained by the Go team. Add it:

#output("ch05/s6-goget.txt", cmd: "go get golang.org/x/sys@v0.49.0")

Create `fsx/lock_unix.go` for the Unix systems that have `flock`:

#src("workbook/ch05/step6/fsx/lock_unix.go")

`f.SyscallConn().Control` runs a function with the file's raw descriptor
while keeping the runtime's bookkeeping consistent; it is the supported way
to make a system call on an `*os.File`. The loop retries `EINTR`, which a
blocking system call returns when a signal arrives. `LOCK_NB` makes the
call fail at once with `EWOULDBLOCK` instead of waiting.

Windows has a different mechanism, `LockFileEx`, and every other platform
gets a stub that reports `errors.ErrUnsupported`. Create both:

#src("workbook/ch05/step6/fsx/lock_windows.go")
#src("workbook/ch05/step6/fsx/lock_other.go")

Now the portable part. Create `fsx/lock.go` with the error types and the
`Lock` type:

#src("workbook/ch05/step6/fsx/lock.go", region: "lockhead")

#goconcept(title: [Error types, `errors.Is` and `errors.AsType`])[
  An error is any value with an `Error() string` method. A sentinel such as
  `ErrLocked` is a fixed value callers compare against with
  `errors.Is(err, ErrLocked)`, which also looks through wrapped errors
  (`fmt.Errorf("...: %w", err)`). A struct type such as `LockedError`
  carries details, here who holds the lock. Giving it an
  `Is(target error) bool` method makes `errors.Is(err, ErrLocked)` true for
  it as well, so callers who only care _whether_ the lock is held never
  need the type. Callers who want the details extract it with
  `errors.AsType[*fsx.LockedError](err)`, the generic form of `errors.As`
  that Chapter 3 introduced. Never compare errors with `==`: the last
  troubleshooting row shows what happens when the error is wrapped.
]

Then `TryLock`:

#src("workbook/ch05/step6/fsx/lock.go", region: "trylock")

The file's _existence_ means nothing here; only the kernel lock does. That
changes how you treat the file:

- *Never delete it on unlock.* If process A holds the lock and B is
  waiting on the same file, and A unlinks the file as it unlocks, B gets
  the lock on an inode that no longer has a name. Meanwhile C creates a
  fresh file at the same path and locks _that_. B and C now both believe
  they are alone. `Unlock` releases and closes, and leaves the file.
- *Check the inode after locking.* Someone else may still delete it: an
  operator tidying up, or `systemd-tmpfiles` cleaning `/tmp`. After
  getting the lock, `TryLock` compares the open file with what the path
  names now (`os.SameFile`), and retries if they differ.
- *Write diagnostics into it.* The holder records its PID, host and start
  time. Losers include that in their error, which turns "lock held" into
  something an on-call engineer can act on. The record is advisory; the
  kernel lock is the truth.

`Acquire` adds waiting, and `Unlock` releases. A blocking `flock` cannot be
interrupted by a context, so `Acquire` polls `TryLock` with backoff up to
500 ms and gives up when the context ends:

#src("workbook/ch05/step6/fsx/lock.go", region: "acquire")

The returned error wraps both causes with two `%w` verbs, so
`errors.Is(err, ErrLocked)` and `errors.Is(err, context.DeadlineExceeded)`
are both true. Finally, the helpers that write and read the holder record
and compare inodes:

#src("workbook/ch05/step6/fsx/lock.go", region: "holder")

=== Testing a lock across processes

A lock between two goroutines proves little; the interesting case is two
processes, one of which dies. The test binary can be its own helper
process: `TestMain` checks an environment variable and, if it is set,
takes the lock and waits to be killed instead of running tests. Replace
`fsx/main_test.go`:

#src("workbook/ch05/step6/fsx/main_test.go")

Create `fsx/lock_test.go`, starting with the helper and a test of the
basic exclusion:

#src("workbook/ch05/step6/fsx/lock_test.go", region: "locktests")

Then the crash test. It starts `os.Args[0]` (the test binary itself) with
`FSX_HOLD_LOCK` set, waits for the helper to say it holds the lock, checks
that the holder record names the helper's PID, kills it with `SIGKILL`, and
takes the lock:

#src("workbook/ch05/step6/fsx/lock_test.go", region: "crash")

and the tests for `Acquire`:

#src("workbook/ch05/step6/fsx/lock_test.go", region: "acquiretests")

#needspace(14em)
#checkpoint(step: 6, of: 13, title: [Locks])[
  Tidy the module, and check that the new files are in place:
  #output("ch05/s6-tidy.txt", cmd: "go mod tidy")
  #output("ch05/s6-tree.txt", cmd: "ls -C cmd fsx")
  #output("ch05/s6-test.txt", cmd: "go vet ./... && go test ./...")
  Build, then run the pid-file experiment shown above (`bin/lockdemo -pidfile ...`) and delete `/tmp/lockdemo.pid` afterwards. Then the same
  with `flock`: A holds the lock, B gives up at once, C waits for it, D is
  killed while holding it, and E gets it immediately:
  #output("ch05/s6-build.txt", cmd: "go build -o bin/ ./cmd/...")
  #output("ch05/s6-flock.txt")
  The crash and wait tests, by name:
  #output("ch05/s6-crash.txt", cmd: "go test -v -run 'TestLockReleasedWhenHolderIsKilled|TestAcquire' ./fsx 2>&1 | grep -E '^(--- |ok)'")
  #troubleshoot(
    ([#ts("s6-xsys.txt")], [`golang.org/x/sys` is not in `go.mod`.], [`go get golang.org/x/sys@v0.49.0`.]),
    ([#ts("s6-block.txt")], [`LOCK_NB` is missing, so the second `TryLock` blocks in `flock` forever instead of failing.], [Use `LOCK_EX|LOCK_NB`; `Acquire` does the waiting.]),
    ([#ts("s6-fcntl.txt")], [The lock was built on `fcntl(F_SETLK)` instead of `flock`. POSIX record locks belong to the _process_, so a second lock from the same process always succeeds.], [Use `flock`. See "Which lock, where".]),
    ([#ts("s6-eq.txt")], [`err == errWouldBlock` instead of `errors.Is`. `flock` returns the errno inside `errors.Join`, so `==` never matches and the condition falls through to the generic error.], [Use `errors.Is`. See "Error types".]),
  )
]

B failed at once, printed the holder's record, and exited with status 75.
C waited, and got the lock within a poll interval of A releasing it. D was
killed with `SIGKILL` while holding the lock, and E acquired it
immediately, because the kernel closed D's descriptors.

=== Which lock, where

#table(
  columns: (auto, 1fr, 1fr),
  table.header([Mechanism], [Semantics], [Watch out for]),
  [pid file (`O_EXCL`)], [Existence is the lock], [Stale after any crash; PID reuse; racy stale detection],
  [`flock`], [Per open file description; released on last close; whole file], [Advisory: only cooperating programs respect it. A child that inherits the descriptor keeps the lock alive. On NFS, Linux emulates it with byte-range locks],
  [`fcntl` `F_SETLK`], [Per _process_, byte ranges. Linux 3.15+ adds `F_OFD_SETLK`, owned by the open file description like `flock`], [Closing _any_ descriptor for the file releases all of the process's locks on it, including one opened by a library. Two opens in one process never conflict],
  [Windows `LockFileEx`], [Mandatory byte-range lock on a handle; released when the handle closes], [Other processes cannot read or write the locked range],
)

`fsx` uses `flock` on Unix and `LockFileEx` on Windows (`lock_windows.go`
compiles under `GOOS=windows`; CI does not run it). Go opens every file
with `O_CLOEXEC`, so a child started with `os/exec` does not inherit the
lock unless you pass the descriptor in `ExtraFiles`. In C programs that
`fork` without `O_CLOEXEC`, a long-lived child holding the lock open is a
classic source of "the lock is held, but nobody is running".

#tip(title: [Where lock files live])[
  Put lock files in `/run/<tool>/` (or `$XDG_RUNTIME_DIR` for per-user
  tools), not `/tmp`. `/run` is a `tmpfs` cleared at boot, which is the
  right lifetime for a lock, and it is not swept by `tmp` cleaners.
]

All of this is per machine. A lock that must hold across a fleet (one
backup per database, one leader per controller) needs a lease in a shared
system: a Kubernetes `Lease` object, a row in a database, or a key with a
TTL. Chapter 16 covers distributed locks and why they need fencing tokens.

#step(7, 13, "Safe extraction", label: <sec-os-root>)

Tools constantly turn untrusted strings into file paths: names inside an
archive, a path from an API request, a key from a config file, a file name
in a Git repository. The classic bug has a name, _zip slip_, after a 2018
disclosure that found it in archive libraries across most ecosystems. This
step reproduces it and then builds an extractor that is immune to it.

=== The naive extractor

`untar` extracts a tar archive two ways, and can write a malicious sample
to try them on. Create `cmd/untar/main.go` with the command itself:

#src("workbook/ch05/step7/cmd/untar/main.go", region: "untarhead")

`extract` calls one of two extractors. The naive one, the version most
first attempts look like, trusts the entry names. `filepath.Join` cleans
`..` elements, which is exactly the problem: joined with `out`, the name
`../escaped.txt` becomes `escaped.txt`, outside the destination. Symbolic
links make it worse, because an archive can contain a link named `logs`
that points to `..` and then a regular file named `logs/via-symlink.txt`.
Each name looks innocent on its own. Add the naive extractor after
`extract`:

#src("workbook/ch05/step7/cmd/untar/main.go", region: "naive")

The end of the file builds the test subject: an archive with one honest
entry and exactly those two escapes. Add it at the bottom:

#src("workbook/ch05/step7/cmd/untar/main.go", region: "evil")

The `fsx.ExtractTar` call in `extract` does not exist yet. Before writing
it, it is worth seeing why validating names by hand is harder than it
looks. A correct check has to handle `..`, absolute paths, symlinks at
every component, symlinks _created by earlier entries_ in the same
archive, and the race where another process swaps a directory for a
symlink between your check and your write. Go 1.24 moved that work into the
standard library.

#newingo("1.24", title: [`os.Root`: directory-limited file access])[
  `os.OpenRoot(dir)` opens a directory and returns an `*os.Root`. Its methods
  (`Open`, `Create`, `OpenFile`, `Mkdir`, `Remove`, `Stat`, `Lstat`, ...)
  take names relative to the root and fail if any component, including a
  symlink, would resolve outside it. On Unix the root holds a directory
  file descriptor, and every operation walks the path one component at a
  time with `openat(2)` and `O_NOFOLLOW`, resolving each symlink itself and
  refusing any step that would climb above the root. Because it works from
  the descriptor, renaming or replacing the directory path afterwards does
  not redirect it.
]

Go 1.25 completed the API with `Chmod`, `Chown`, `Chtimes`, `Lchown`,
`Link`, `MkdirAll`, `ReadFile`, `Readlink`, `RemoveAll`, `Rename`,
`Symlink` and `WriteFile`, so a tool can do all of its file work through
a `Root`, and `Root.FS()` returns an `fs.FS` that cannot be escaped.

#warning(title: [`os.DirFS` is not a sandbox])[
  The documentation is explicit: `os.DirFS("/prefix").Open("file")` is the
  same as `os.Open("/prefix/file")`. If `file` is a symbolic link to
  `/etc/shadow`, `DirFS` follows it. `fs.ValidPath` rejects `..` in the
  name, but not a symlink that leads out. When the tree may contain
  content you did not create, use `Root.FS()`.
]

=== `fsx.ExtractTar`

Create `fsx/extract.go`. `ExtractTar` reads entries with `tar.Reader.Next`,
stops after `MaxFiles` entries, and hands each one to `extractEntry` along
with what is left of a `MaxBytes` budget:

#src("workbook/ch05/step7/fsx/extract.go", region: "tar")

`tar.Reader` is itself an `io.Reader`: after `Next` returns a header,
reading from `tr` yields that entry's contents and then EOF. Every file
operation in `extractEntry` goes through the root, and one policy decision
is its own:

#src("workbook/ch05/step7/fsx/extract.go", region: "extract")

Three details are deliberate. Files are opened with `O_EXCL`, so an entry
can never write through something that is already at its name, whether a
symlink, a FIFO or an earlier entry. Permission bits are reduced to
`Perm()`, which drops setuid and setgid: an archive should not be able to
create a setuid binary just because the extractor runs as root. And
symlinks whose target would leave the root are refused even though the
`Root` would refuse to _follow_ them, because the program that later uses
the extracted tree, a compiler or a web server, will not be using a `Root`.
`filepath.IsLocal` (Go 1.20) is the lexical check: it rejects absolute
paths, `..` escapes, empty names and, on Windows, reserved names like
`NUL`.

The byte budget uses the `LimitReader` trick once more: each file may read
one byte more than the budget that remains, and a negative remainder means
the archive was over its limit. The limit counts bytes that come _out_ of
the archive, which is what matters for a compressed one.

=== Tests

Create `fsx/extract_test.go` with a helper that builds a tar archive in
memory from a list of entries, and one that makes a destination with a
parent directory the test can inspect:

#src("workbook/ch05/step7/fsx/extract_test.go", region: "helpers")

The happy path extracts directories, files and an internal symlink, then
runs `fstest.TestFS` over the result. Given a file system and the files it
should contain, `TestFS` checks that every interface the implementation
claims (`ReadDir`, `Stat`, `Glob`, `Sub`) agrees with `Open`; run it
against any `fs.FS` you write.

#src("workbook/ch05/step7/fsx/extract_test.go", region: "good")

The attacks come from a table. Each case is an archive, and each must fail
without creating `escaped.txt` next to the destination:

#src("workbook/ch05/step7/fsx/extract_test.go", region: "attacks")

The last two tests cover a symlink planted in the destination _before_
extraction starts, which only `os.Root` can catch, and the limits:

#src("workbook/ch05/step7/fsx/extract_test.go", region: "planted")

#needspace(14em)
#checkpoint(step: 7, of: 13, title: [Safe extraction])[
  #output("ch05/s7-tree.txt", cmd: "ls -C cmd fsx")
  #output("ch05/s7-test.txt", cmd: "go vet ./... && go test ./...")
  Build, then try both extractors on the evil archive in a scratch
  directory (`mkdir evil && cd evil`):
  #output("ch05/s7-build.txt", cmd: "go build -o bin/ ./cmd/...")
  #output("ch05/s7-untar.txt")
  The attack tests, with the error each archive produced:
  #output("ch05/s7-attacks.txt", cmd: "go test -v -run 'TestExtractTar(RejectsEscapes|RefusesPlantedSymlink)' ./fsx 2>&1 \\\n    | grep -E 'extract_test|^(--- |ok)'", size: 6.4pt)
  #troubleshoot(
    ([#ts("s7-join.txt")], [Files were created with `os.OpenFile(filepath.Join(root.Name(), ...))`, bypassing the root. The lexical join lets `..` and absolute names out.], [Do every operation through `root`.]),
    ([#ts("s7-excl.txt")], [`O_TRUNC` instead of `O_EXCL`: a second entry with the same name overwrites the first, and could write through a symlink an earlier entry planted.], [Open with `O_CREATE|O_EXCL`.]),
    ([#ts("s7-symlink.txt")], [The symlink target check is missing. `os.Root` would refuse to follow the link, but the link itself was created, pointing outside.], [Restore the `filepath.IsLocal` check on the joined target.]),
    ([#ts("s7-budget.txt")], [The budget is decremented but never compared, so an archive over `MaxBytes` extracts in full.], [Return `ErrArchiveTooLarge` when the budget goes negative.]),
  )
]

The naive extractor wrote two files outside `out`. In a real attack the
targets are `~/.ssh/authorized_keys`, a cron directory, or a binary on
`PATH`, and the archive arrives as a Helm chart, a Terraform module or a
build artifact. The messages from the safe extractor show which layer
refused: "path escapes from parent" is `os.Root` refusing a `..`, an
absolute name or a planted symlink; "leaves the destination" is the
lexical check on symlink targets; and "file exists" is `O_EXCL`. Note also
that `README.md` was extracted before the bad entry stopped the run. For
deployable artifacts, extract into a temporary directory and swap it into
place only when extraction succeeds, which is the atomic-replace idea of
step 5 applied to a directory (exercise 5.6).

#warning(title: [What `os.Root` does not cover])[
  The documentation lists the limits. A root does not stop traversal into
  other file systems mounted inside it, Linux bind mounts, `/proc` magic
  links or device files. On Unix, `Root.Chmod`, `Chown` and `Chtimes` can
  be redirected by a symlink swapped in during the call. And a root
  constrains _paths_, not resources: archive bombs (a 1 KB file that
  decompresses to 10 GB, or a million empty files) still need the byte and
  file limits in `Limits`.
]

#step(8, 13, "/proc and zombies", label: <sec-os-proc>)

Linux exposes almost everything it knows about a process as text files
under `/proc`. Tools read them to show what is running (`ps`, `top`), to
find leaks, and to identify processes reliably. This step starts the third
package, `sysinfo`, with a parser for the most important of those files,
and uses it to watch zombies accumulate under PID 1. For tools, a handful
of files matter:

#table(
  columns: (auto, 1fr),
  table.header([File], [What it gives you]),
  [`/proc/self/status`], [Human-readable summary: `VmRSS` (resident memory now), `VmHWM` (peak), `Threads`, `FDSize`, signal masks, capabilities.],
  [`/proc/<pid>/stat`], [One line, space-separated: state, parent, process group, session, CPU times, start time, RSS. What `ps` and `top` read.],
  [`/proc/<pid>/fd/`], [One symlink per open descriptor, pointing at the file, socket or pipe. Counting them finds descriptor leaks.],
  [`/proc/<pid>/cmdline`, `environ`], [Arguments and environment, NUL-separated. `environ` is how secrets passed as environment variables leak to anyone who can read it.],
)

=== Parsing `/proc/<pid>/stat`

The `stat` line looks easy to parse and is a favourite interview question
because it is not. The second field is the executable name in parentheses,
and a process can set its own name to anything up to 15 bytes, including
spaces and `)`. Splitting on spaces is wrong, and so is splitting at the
first `)`. The only safe point is the _last_ `)` on the line.

Every reader in `sysinfo` takes an `fs.FS` rooted at `/`, so tests can hand
it a `MapFS` that looks like a Linux machine. Create `sysinfo/proc.go` with
the package documentation, imports and `Host`:

#src("workbook/ch05/step8/sysinfo/proc.go", region: "imports")

then the `Stat` type and the parser:

#src("workbook/ch05/step8/sysinfo/proc.go", region: "stat")

`f[0]` is the third field in the numbering of `proc(5)`, the manual page
that documents the format, so `f[19]` is field 22, `starttime`. The
`//nolint:gosec` comment answers a linter warning that is right in general
(converting a signed integer to an unsigned one can overflow) and wrong
here, because the kernel never writes a negative start time; the comment
says why, which is the rule for every `nolint` in this book.

`StartTime` deserves a note: it is the process's start time in clock ticks
since boot, and the pair (PID, start time) identifies a process uniquely,
which is what a pid file needs to detect PID reuse (step 6, and exercise
5.3). Add the readers:

#src("workbook/ch05/step8/sysinfo/proc.go", region: "readstat")

`statParser` keeps the first parse error instead of checking after each
field, which keeps the struct literal in `parseStat` readable; the pattern
is the same as `bufio.Scanner`'s `Err`. `Processes` lists `/proc`, keeps the
entries whose names are numbers, and skips any process that has exited
between the listing and the read: a race every `ps` implementation
handles.

=== Tests on any OS, and on Linux

The parsing tests use `MapFS` literals, including a process that named
itself `evil) S 1 2 3` to fool a naive parser. Create
`sysinfo/sysinfo_test.go`:

#src("workbook/ch05/step8/sysinfo/sysinfo_test.go", region: "imports")
#src("workbook/ch05/step8/sysinfo/sysinfo_test.go", region: "stat")

The real `/proc` exists only on Linux, so the tests that read it go into a
file with a build constraint. Create `sysinfo/sysinfo_linux_test.go`:

#src("workbook/ch05/step8/sysinfo/sysinfo_linux_test.go", region: "imports")
#src("workbook/ch05/step8/sysinfo/sysinfo_linux_test.go", region: "proc")

On a Mac, `go test` skips that file. To run it, cross-compile the test
binary with `go test -c` and run it in the container; the checkpoint shows
how.

=== Zombies

When a process exits, the kernel keeps a small record of it, its exit
status and resource usage, until the parent collects it with `wait`. In
between, the process is a _zombie_: state `Z`, no memory, no running code,
but still a slot in the process table and a PID. `os/exec` always waits for
the children it starts. The problem is the children it did not start.

When a process dies, its children are re-parented to PID 1 (or to the
nearest ancestor marked as a _subreaper_). On a normal Linux system PID 1
is `systemd` or another init, which reaps everything it inherits. In a
container, PID 1 is whatever the image's entrypoint is, very often your Go
binary. `zombies` runs a child that starts three short jobs and exits
without waiting for them, then lists the container's processes with
`sysinfo.Processes`, because a `FROM scratch` image has no `ps`. Create
`cmd/zombies/main.go`:

#src("workbook/ch05/step8/cmd/zombies/main.go")

The program re-runs its own binary (`os.Executable`) with a `-role` flag
to play the child and the grandchildren. Every demo in the rest of the
chapter uses that trick, because the image contains nothing else to run.

#needspace(14em)
#checkpoint(step: 8, of: 13, title: [`/proc` and zombies])[
  Your module has a third package:
  #output("ch05/s8-tree.txt", cmd: "ls -C cmd fsx sysinfo")
  #output("ch05/s8-test.txt", cmd: "go vet ./... && go test ./...")
  Build the Linux binaries and the image, then run `zombies` as PID 1, and
  again with Docker's `--init`:
  #output("ch05/s8-image.txt", cmd: "CGO_ENABLED=0 GOOS=linux go build -o linux/ ./cmd/... && docker build -q -f scratch.Dockerfile -t oskit linux")
  #output("ch05/s8-zombies.txt", cmd: "docker run --rm oskit /zombies")
  #output("ch05/s8-init.txt", cmd: "docker run --rm --init oskit /zombies")
  Run the Linux-only tests: build a Linux test binary into `linux/`,
  rebuild the image so it contains it, and run it:
  #output("ch05/s8-testc.txt", cmd: "CGO_ENABLED=0 GOOS=linux go test -c -o linux/ ./sysinfo && docker build -q -f scratch.Dockerfile -t oskit linux")
  #output("ch05/s8-linuxtest.txt", cmd: "docker run --rm oskit /sysinfo.test -test.v | grep -E '^(---|PASS|FAIL)'")
  #troubleshoot(
    ([#ts("s8-paren.txt")], [The parser splits at the _first_ `)` (`bytes.IndexByte`), so a name containing `)` shifts every field.], [Use `bytes.LastIndexByte`. See "Parsing `/proc/<pid>/stat`".]),
    ([#ts("s8-mac.txt")], [You ran `bin/zombies` on macOS, which has no `/proc`, so `Processes` finds nothing.], [Run it in the container.]),
    ([#ts("s8-gosec.txt")], [The `//nolint:gosec` comment on the conversion is missing.], [Keep the comment, with its reason.]),
  )
]

As PID 1, the Go program inherited the three jobs, never waited for them,
and they stayed as zombies. Each holds a PID; with a `pids.max` of a few
hundred, typical for a pod, a long-running agent that calls scripts which
background things will eventually be unable to start anything at all.
With `--init`, Docker runs its bundled `docker-init` (which is `tini`) as
PID 1. It reaps every orphan, forwards signals to your program, and exits
with its exit status. That is the whole job of `tini`, and why it exists.

#internals(title: [Why not reap in Go?])[
  A Go PID 1 can reap orphans itself: subscribe to `SIGCHLD` and call
  `wait4(-1, ..., WNOHANG)` in a loop. The trouble is that `wait4(-1)`
  reaps _any_ child, including the ones `os/exec` is about to `Wait` for,
  which then fail with `ECHILD` and lose their exit status. Doing it
  correctly means peeking with `waitid(..., WNOWAIT)` and only reaping PIDs
  you did not start. Unless you are writing an init system, use `tini`:
  `docker run --init`, `ENTRYPOINT ["/tini", "--", "/app"]`, or in
  Kubernetes `shareProcessNamespace: true`, which makes the pod's `pause`
  container PID 1, and `pause` reaps zombies.
]

PID 1 is special in a second way: the kernel does not apply a signal's
default action to it, so a C program with no `SIGTERM` handler running as
PID 1 ignores `docker stop`, which waits ten seconds and sends `SIGKILL`.
A Go binary still exits, because the runtime installs handlers for all
signals and, when re-raising an unhandled `SIGTERM` has no effect, exits
with status 143 (its source comments: "this probably means we're PID
1"). Deferred cleanup does not run either way, so handle `SIGTERM`
explicitly, as Chapter 4 does.
