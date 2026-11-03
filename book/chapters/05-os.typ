#import "../template/book.typ": *
#import "05-lib.typ": ts

#chapter(5, "Talking to the Operating System: I/\u{2060}O, Files, Processes, and Signals", label: <ch-os>,
  abstract: [
    Platform tools are glue between the kernel and everything else. They
    read logs that are bigger than their memory limit, write config files
    that running services read, start other programs and wait for them, and
    run as PID 1 in containers whose limits they cannot see unless they
    look. The Go standard library makes each of these look like one function
    call. In this chapter you build the code that closes the gap between
    that call and what the kernel does, one verified step at a time, and you
    run the experiments that show why each line is there.
  ],
  learn: (
    [What `io.Reader` and `io.Writer` are, how to implement them, and how `io.Copy`, `io.ReadAll` and the wrappers compose],
    [Streaming I/O in constant memory, and the two bugs that turn log processing into an incident],
    [`io/fs` and `testing/fstest` for file code you can test on any OS],
    [Atomic writes, lock files that cannot go stale, and safe archive extraction with `os.Root`],
    [Running subprocesses without a shell, and stopping the whole process tree],
    [PTYs, SIGPIPE, SIGHUP reloads, zombies and PID 1],
    [Reading `/proc` and cgroup v2, and making a Go binary container-aware],
  ),
  build: [
    Three packages that later chapters use: *`fsx`* (atomic writes, lock
    files, safe archive extraction), *`procx`* (subprocesses in their own
    process group) and *`sysinfo`* (procfs and cgroup v2 readers), built in
    thirteen steps and labs.

    #v(4pt)
    A dozen small programs that make the kernel's behaviour visible, run for
    real on Linux in an empty Docker image. The last step is the production
    code in the book's repository.
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
operating system does. This chapter closes them one at a time. You reproduce
each failure first, in a lab, and then write the code that prevents it. The
fixes go into three packages: `fsx` for files, `procx` for processes and
`sysinfo` for reading what the kernel knows about a process.

Everything Linux-specific runs for real. The programs are cross-compiled
with `CGO_ENABLED=0 GOOS=linux`, copied into a `FROM scratch` image that
contains nothing else, and run with `docker run`; no base image is ever
pulled. `book/scripts/capture-ch05.sh` regenerates every terminal block in
this chapter. Host runs were made on macOS on an Apple M5. Where macOS and
Linux behave differently, the text says so.

== What we're building <sec-os-building>

The chapter has one Go module, `oskit`, that grows from a log generator to
three reusable packages and a dozen demo programs. Two of the finished
programs show the range. `logscan` summarises a 2.2 GB access log in a few
megabytes of memory:

#output("ch05/s3-stream.txt", cmd: "bin/logscan -sum access.log")

and `limits`, run in a container with limits on CPU, memory, processes and
file descriptors, reports what the kernel enforces and what the Go runtime
made of it:

#output("ch05/s13-set.txt", cmd: "docker run --rm --cpus=1.5 --memory=256m --pids-limit=100 --ulimit nofile=1024:4096 \\\n    oskit /limits")

Between those two, you build atomic file replacement, lock files, archive
extraction that cannot be tricked into writing outside its directory, and a
subprocess runner that cleans up after the programs it starts.

=== The plan

The chapter alternates two kinds of section. A *lab* makes the operating
system's behaviour visible: you build a small program, run it, and compare
what you see with the book. A *build step* adds code to one of the three
packages. Both end with a checkpoint, and both leave a module that compiles
and passes its tests.

#table(
  columns: (auto, 1.25fr, 1fr),
  table.header([Step], [What it adds], [Go you meet there]),
  [Lab 1 #h(3pt) Readers and writers], [`loggen`, a log generator that is an `io.Reader`; a counting `io.Writer`; a copy benchmark], [`io.Reader`, `io.Writer`, `io.Copy`, `io.MultiWriter`, `io.LimitReader`, pointer receivers, `testing/iotest`],
  [Lab 2 #h(3pt) What `io.ReadAll` costs], [`logscan` the naive way; an OOM kill in Docker; the silent `bufio.Scanner` stop], [`io.ReadAll`, `bufio.Scanner`, build constraints, cross-compiling],
  [Lab 3 #h(3pt) Streaming], [A line iterator in fixed memory, gzip, directories through `io/fs`], [`bufio.Reader`, iterators, `io.TeeReader`, `io/fs`, `fstest.MapFS`],
  [Lab 4 #h(3pt) Torn writes], [`torn`, which catches readers seeing half-written files], [function types, `sync/atomic`, `-race`],
  [5 #h(3pt) Atomic replacement], [`fsx.Write` and `fsx.WriteFile`, `atomicput`], [named results with `defer`, `bufio.Writer`, file modes, goleak],
  [6 #h(3pt) Locks], [`fsx.TryLock` and `fsx.Acquire` on `flock`], [error types with `Is`, `golang.org/x/sys/unix`, the helper-process test],
  [7 #h(3pt) Extraction], [`fsx.ExtractTar` with `os.Root`, archive limits], [`os.Root`, `archive/tar`, `filepath.IsLocal`],
  [8 #h(3pt) `/proc` and zombies], [`sysinfo.ReadStat` and `Processes`; zombies under PID 1], [`fs.FS` readers, parsing without allocating],
  [Lab 9 #h(3pt) Orphans], [`orphans`: a cancelled command leaves its child running], [`os/exec`, `exec.CommandContext`],
  [10 #h(3pt) Process groups], [`procx.Command`: no shell, a group, SIGTERM then SIGKILL], [struct embedding, `SysProcAttr`, `Cancel`, `WaitDelay`],
  [Lab 11 #h(3pt) Terminals], [`ttydemo`: the same child through a pipe and a PTY], [a third-party module, `ioctl`],
  [Lab 12 #h(3pt) Signals], [SIGPIPE in a pipeline; a service that reloads on SIGHUP], [`os/signal`, `atomic.Pointer[T]`],
  [13 #h(3pt) Container limits], [cgroup v2 readers and `limits`; the production code], [`runtime/debug`, `text/tabwriter`],
)

=== How to work through the steps

Every step lists the files to create or the functions to replace, in full.
Type them, run the checkpoint commands at the end of the step, and compare
your output with the book's. Timings, PIDs, hashes of things that contain
the time, and throughput figures will differ; everything else should match.
If it doesn't, the troubleshooting table under each checkpoint lists
failures produced on purpose by breaking a copy of that step, with the exact
message each one prints.

The repository has every step as a complete module under
`workbook/ch05/step1` to `step13`, and each passes `go vet`, `go test -race` and `golangci-lint`. Diff your directory against the step you are
on when you get stuck. The last step is the production code: the
repository's `pkg/fsx`, `pkg/procx`, `pkg/sysinfo` and `examples/ch05` are
the same files with longer import paths, and a check in CI keeps them
identical.

You need Go 1.27, the `golangci-lint` setup from Chapter 1, Docker (any
recent Docker Desktop, Colima or Docker Engine), and about 2.5 GB of free
disk for the big log in lab 2. The Linux parts run in Docker, so macOS,
Linux and Windows with WSL all work. Chapter 0 covers the language; the
boxes marked _Go concept_ in this chapter recap the pieces you need at the
moment you first need them.

#step(1, 13, "Lab 1: Readers and writers", label: <sec-os-lab1>)

Almost every program in this chapter moves bytes from somewhere to
somewhere else: a file into a parser, a child's output into a log, an
archive onto a disk. Go has one pair of interfaces for all of it, and this
lab builds both sides of the pair by hand. The program is `loggen`, which
writes a synthetic web-server access log of any length. The rest of the
chapter scans, copies and breaks that log.

Start with an empty module:

#session(
  ("mkdir oskit && cd oskit", none),
  ("go mod init oskit", "ch05/s1-modinit.txt"),
  ("go get go@1.27.0", "ch05/s1-goget.txt"),
)

`go mod init` records the toolchain you ran as the module's minimum Go
version; `go get go@1.27.0` lowers it to the first 1.27 release, so any Go
1.27 can build the module. Programs go under `cmd/`, one directory each, as
in Chapter 1, and packages the programs share go at the top level (`fsx`,
`procx`, `sysinfo`), imported as `oskit/fsx` and so on.

#goconcept(title: [Interfaces, satisfied implicitly])[
  An interface type lists methods. Any type that has those methods
  _satisfies_ the interface automatically: there is no `implements`
  keyword, unlike Java or C\#. That is why a type you write today works with
  a standard-library function written ten years ago, as long as the method
  set matches. A variable of interface type holds a value of some concrete
  type and calls that type's methods; `var r io.Reader = f` stores an
  `*os.File` and `r.Read(p)` calls the file's `Read`. Interfaces in Go are
  usually tiny, often one method, and named after it: `Reader`, `Writer`,
  `Closer`, `Stringer`. Chapter 0 covers them in full.
]

=== The `io.Reader` contract

`io.Reader` is the interface for anything you can read bytes from: a file,
a network connection, a pipe, an HTTP body, a decompressor, a string in a
test. It has one method.

#goconcept(title: [`io.Reader`])[
  ```go
  type Reader interface {
  	Read(p []byte) (n int, err error)
  }
  ```
  The _caller_ owns the buffer `p` and passes it in; `Read` copies up to
  `len(p)` bytes into it and returns how many it copied. When there is
  nothing more, `Read` returns `0, io.EOF`. Three rules trip people up.
  `Read` may return _fewer_ bytes than `len(p)` even when more are coming,
  which pipes and sockets do constantly, so never assume the buffer is
  full (`io.ReadFull` exists for exact counts). `Read` may return `n > 0`
  _and_ an error in the same call, so process the `n` bytes before you look
  at `err`. And `io.EOF` is not a failure: it is the normal end. Python's
  `f.read(n)` and Java's `InputStream.read(byte[])` work the same way, except
  that they signal the end with an empty result or `-1`.
]

The caller-owns-the-buffer design is what makes Go's I/O cheap. A loop that
reads a 2 GB file through a 32 KiB buffer allocates the buffer once and
reuses it about 65,000 times; nothing is copied into fresh memory on each
call. The price is that a `Reader` must never keep `p` after `Read` returns,
and a caller must not assume the bytes stay put after the next call.

`loggen` generates its log _as it is read_. The generator holds one line at
a time and hands out as many bytes of it as the caller's buffer has room
for, so a log of a billion lines costs no more memory than a log of three.
Create `cmd/loggen/gen.go` with the reader:

#src("workbook/ch05/step1/cmd/loggen/gen.go", region: "reader")

Read it as a loop that fills `p`. When the pending part of the current line
is used up, `appendLine` generates the next line into the same `line`
buffer (`r.line[:0]` keeps the memory and sets the length to zero), and
`copy` moves as much of it as fits. When `lines` lines have been generated,
the loop stops and the method reports what it copied; a call that copied
nothing returns `io.EOF`. The `len(p) > 0` check matters for one corner of
the contract: a `Read` with an empty buffer must return `0, nil`, not EOF.

#goconcept(title: [Slices are windows])[
  A slice (`[]byte`) is a view of an underlying array: a pointer, a
  length and a capacity. `p[n:]` is a new view starting at byte `n` of the
  same memory, and `r.pending = r.pending[c:]` moves the view forward without
  copying anything. `copy(dst, src)` copies `min(len(dst), len(src))` bytes
  and returns that number. `b[:0]` keeps the capacity and empties the view,
  so `append` reuses the memory instead of allocating. The trap is that
  views share memory: if you hand someone `r.line` and then generate the
  next line into it, their bytes change under them. Lab 3 runs into exactly
  that.
]

The rest of the file builds one line. The random numbers come from a PCG
generator with a fixed seed, so every run produces the same log, which is
what makes the hashes and line counts in this chapter reproducible. Line
`longAt`, if set, gets a URL of a megabyte: the kind of line a client
sending a huge query string produces, and the kind that breaks naive
readers in lab 2. Add the line generator to the end of `gen.go`:

#src("workbook/ch05/step1/cmd/loggen/gen.go", region: "line")

`fmt.Appendf` is `fmt.Sprintf` that appends to an existing byte slice
instead of returning a new string, so generating a line allocates almost
nothing. The format is the usual one: time, client address, method, path,
status, response size, latency.

=== The `io.Writer` side

#goconcept(title: [`io.Writer`])[
  ```go
  type Writer interface {
  	Write(p []byte) (n int, err error)
  }
  ```
  `Write` writes all of `p` or returns an error explaining why not: unlike
  `Read`, a short write without an error is a bug, and `io.Copy` reports it
  as `io.ErrShortWrite`. `Write` must not modify `p` or keep it after
  returning. Files, sockets, `bytes.Buffer`, `strings.Builder`, hashes,
  gzip compressors and HTTP response bodies are all writers, and
  `fmt.Fprintf(w, ...)` formats into any of them. The common mistake is
  ignoring the error, especially when writing to standard output; lab 12
  shows what that costs.
]

A writer does not have to store anything. `countWriter` keeps statistics
instead of bytes: the total, the number of newlines, and the size of the
largest single `Write`, which reveals the chunk size the caller used.
Create `cmd/loggen/count.go`:

#src("workbook/ch05/step1/cmd/loggen/count.go")

`Write` has a _pointer receiver_, `(c *countWriter)`, because it changes
the counter. That detail decides how you pass a `countWriter` to anything
that wants an `io.Writer`.

#goconcept(title: [Pointer receivers and interfaces])[
  A method declared on `*T` can modify the value; one declared on `T`
  works on a copy. The method set of `T` includes only the value-receiver
  methods, while `*T` has both. So when `Write` has a pointer receiver,
  `*countWriter` is an `io.Writer` and `countWriter` is not:
  `io.MultiWriter(&count)` compiles and `io.MultiWriter(count)` does not
  (the first troubleshooting row below shows the message). The rule of
  thumb: if any method needs a pointer receiver, give them all one, and
  pass `&v`.
]

=== Copying, and composing

With a reader and writers, the program is one call. Create
`cmd/loggen/main.go` with the package comment, the imports and `main`:

#src("workbook/ch05/step1/cmd/loggen/main.go", region: "imports")
#src("workbook/ch05/step1/cmd/loggen/main.go", region: "main")

`main` parses flags and hands everything to `run`, which takes its output
streams as parameters, so a test can pass buffers instead of `os.Stdout`
(the shape Chapter 1 recommended for every binary). Add `run`:

#src("workbook/ch05/step1/cmd/loggen/main.go", region: "run")

#goconcept(title: [`io.Copy`])[
  `io.Copy(dst, src)` reads from `src` into a 32 KiB buffer and writes each
  chunk to `dst`, until `src` returns `io.EOF`. It returns the number of
  bytes copied and the first error, and treats EOF as success, so `err == nil` means "everything arrived". It also takes shortcuts: if `src` has a
  `WriteTo` method or `dst` a `ReadFrom` method, `io.Copy` calls that
  instead, which lets a file copied to a socket move inside the kernel. The
  benchmark below shows the shortcut overriding a buffer you supplied.
]

Nothing in `run` knows what the bytes are or where they go, and three
wrappers do all the interesting work. Each one is itself a `Reader` or a
`Writer`, which is why they nest:

#goconcept(title: [Composing readers and writers])[
  `io.LimitReader(r, n)` returns a reader that reads from `r` and reports
  EOF after `n` bytes, however much more `r` has. `io.MultiWriter(a, b, c)`
  returns a writer that writes every chunk to `a`, then `b`, then `c`, and
  stops at the first error. `io.TeeReader(r, w)` returns a reader that
  writes everything read from `r` to `w` on the way through (lab 3 uses it).
  `io.MultiReader(r1, r2)` reads `r1` to its end, then `r2`. None of them
  buffer the whole stream, so they cost the same for a kilobyte and a
  terabyte. Unix pipes compose programs the same way; these compose values
  inside one program.
]

@fig-os-loggen shows the result when `-o` names a file: one pass over the
generated log feeds the file, a SHA-256 hash and the counter at the same
time. A hash is a writer too, so checksumming a stream while you save it
costs no second read.

#fig(caption: [`loggen -o access.log -bytes N`. Every box is an `io.Reader` or an `io.Writer`; `io.Copy` moves 32 KiB chunks from left to right, and no stage ever holds the whole log.])[
  #diagram(
    spacing: (16pt, 10pt),
    dnode((0, 1), [`logReader`\ one line at a time], kind: "accent"),
    dnode((1, 1), [`io.LimitReader`\ EOF after N bytes], kind: "accent"),
    dnode((2, 1), [`io.Copy`\ 32 KiB buffer], kind: "dark"),
    dnode((3, 1), [`io.MultiWriter`], kind: "accent"),
    dnode((4, 0), [`*os.File`], kind: "muted"),
    dnode((4, 1), [`sha256` hash], kind: "muted"),
    dnode((4, 2), [`countWriter`], kind: "muted"),
    dedge((0, 1), (1, 1), "-|>"),
    dedge((1, 1), (2, 1), "-|>"),
    dedge((2, 1), (3, 1), "-|>"),
    dedge((3, 1), (4, 0), "-|>"),
    dedge((3, 1), (4, 1), "-|>"),
    dedge((3, 1), (4, 2), "-|>"),
  )
] <fig-os-loggen>

One more line in `run` deserves attention. The error from `f.Close()` is
checked, not deferred and dropped. On many file systems, and on every
network file system, a write can be accepted into a cache and fail later;
`Close` is where that failure surfaces. A program that ignores it can
report success for a file that never reached the disk.

=== Testing a reader

A hand-written `Read` is easy to get subtly wrong, and the standard library
ships a checker for it. Create `cmd/loggen/gen_test.go`:

#src("workbook/ch05/step1/cmd/loggen/gen_test.go", region: "readertest")

`iotest.TestReader` reads the reader with buffers of many sizes, including
one byte and zero bytes, and fails if the bytes differ from `want` or if
`Read` breaks the contract at the end (for example by returning data after
EOF, or returning `0, nil` forever). The second test checks the shape of the
lines, including the 1 MiB one. Add the writer and `run` tests to the same
file:

#src("workbook/ch05/step1/cmd/loggen/gen_test.go", region: "writertest")

`TestCountWriter` uses `fmt.Fprint` with a `*countWriter`, the same way any
code would. `TestRunWritesFileAndSummary` checks the hash `run` prints
against one computed independently with `sha256.Sum256`, and
`TestRunLimitCutsAnEndlessLog` asks for an endless log (`lines` 0) cut to
300 bytes: without `io.LimitReader`, that test would never finish.

=== How big should a copy buffer be?

People tune `io.Copy` buffers, so it is worth measuring what a bigger one
buys. `io.CopyBuffer` is `io.Copy` with a buffer you supply. The benchmark
writes a 256 MiB log to a temporary file, then copies it, warm in the page
cache, into a `countWriter` through buffers from 512 bytes to 1 MiB, and
reports the largest write the counter saw. Create `cmd/loggen/copy_test.go`:

#src("workbook/ch05/step1/cmd/loggen/copy_test.go")

`b.Loop()` runs the body as many times as `-benchtime` asks, and
`b.SetBytes` makes the output report throughput. The last case is the
trap: it passes the `*os.File` directly instead of wrapping it in
`struct{ io.Reader }`.

#needspace(14em)
#checkpoint(step: 1, of: 13, title: [Readers and writers])[
  Your module should contain these Go files:
  #output("ch05/s1-tree.txt", cmd: "find . -name '*.go' | sort")
  Vet and test it:
  #output("ch05/s1-test.txt", cmd: "go vet ./... && go test ./...")
  Generate a few lines, and an endless log cut at 200 bytes (the `echo`
  adds the newline the cut removed):
  #output("ch05/s1-lines.txt", cmd: "go run ./cmd/loggen -lines 3")
  #output("ch05/s1-bytes.txt", cmd: "go run ./cmd/loggen -lines 0 -bytes 200; echo")
  Build every command into `bin/`, write a million lines to a file, and
  check the summary against independent tools. Your hash must match the
  book's exactly, because the log is deterministic:
  #output("ch05/s1-build.txt", cmd: "go build -o bin/ ./cmd/...")
  #output("ch05/s1-file.txt", cmd: "bin/loggen -lines 1000000 -o access.log")
  #output("ch05/s1-shasum.txt", cmd: "shasum -a 256 access.log; wc -lc access.log")
  Then run the benchmark. It takes a minute or two; the output here is
  condensed by a small script to the median of five runs:
  #output("ch05/s1-bench.txt", cmd: "go test -run '^$' -bench . -benchtime 20x -count 5 ./cmd/loggen",
    title: "condensed: median MB/s of five runs")
  #troubleshoot(
    ([#ts("s1-pointer.txt")], [`io.MultiWriter(f, sum, count)` passes the `countWriter` by value, and only `*countWriter` has the `Write` method.], [Pass `&count`. See "Pointer receivers and interfaces".]),
    ([#ts("s1-short.txt")], [`countWriter.Write` returns `0, nil` (here: `return 0, nil` instead of `len(p)`). A writer that consumes fewer bytes than it was given must say why; `io.Copy` reports the silent case as `io.ErrShortWrite`.], [Return `len(p), nil`. See "The `io.Writer` side".]),
    ([#ts("s1-noeof.txt")], [`Read` never returns `io.EOF`, so `io.ReadAll` keeps calling it, getting `0, nil` forever.], [Return `0, io.EOF` when nothing was copied into a non-empty `p`.]),
    ([#ts("s1-randv1.txt")], [The import is `math/rand` instead of `math/rand/v2`. Version 1 has no PCG generator and spells the method `Intn`.], [Import `math/rand/v2`.]),
  )
]

Read the benchmark from the top. Each `read` and `write` system call has a
fixed cost, so 512-byte chunks are about an order of magnitude slower than
32 KiB ones, on every run. Above 32 KiB the numbers
move from run to run: bigger buffers save system calls but stop fitting in
the CPU's fastest caches, and on some runs a megabyte is slower than 256
KiB. Those differences are tens of percent on a file that is already in
memory, and they vanish on a network or a cold disk, where the device is
the bottleneck. The default is right for almost everything.

The last line proves the trap. The largest write is 32 KiB, not the 1 MiB
buffer passed in: `io.CopyBuffer` uses your buffer only if neither side has
a shortcut. `*os.File` implements `io.WriterTo`, so `CopyBuffer` calls
`f.WriteTo`, which falls back to a plain `io.Copy` with its own 32 KiB
buffer and silently ignores the megabyte you allocated. On Linux the
shortcuts matter for real: `File.WriteTo` uses `sendfile(2)` when the
destination is a TCP or Unix socket, and `File.ReadFrom` uses
`copy_file_range(2)` or `splice(2)`, so the data moves inside the kernel
without passing through your process. A plain `io.Copy(conn, file)` is
often the fastest code you can write.

#include "05b-os.typ"
#include "05c-os.typ"
#include "05d-os.typ"
