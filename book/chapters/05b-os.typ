#import "../template/book.typ": *
#import "05-lib.typ": ts

#step(2, 13, "Lab 2: What io.ReadAll costs", label: <sec-os-lab2>)

The simplest way to process a file is to read all of it into memory and
split it into lines. This lab builds that version of a log scanner, gives
it a 2.2 GB log, and watches it fail twice: once loudly in a container with
a memory limit, and once silently with the usual fix.

`logscan` reports what an on-call engineer asks of an access log first: how
many requests, how many failed, and how long the scan took. Start with the
type that holds the answer. Create `cmd/logscan/stats.go`:

#src("workbook/ch05/step2/cmd/logscan/stats.go")

`Status` is an array of six counters indexed by the first digit of the
status code, so `Status[5]` counts 5xx responses and a 503 costs one array
increment. `statusClass` finds the fifth field by counting spaces instead
of calling `strings.Fields`, which would allocate a slice of strings for
each of thirty million lines. Lines without a recognisable status are
counted as malformed rather than dropped: a scanner that silently ignores
input it does not understand will hide exactly the lines you are looking
for.

=== Two naive scanners

Create `cmd/logscan/naive.go` with the two implementations this lab is
about:

#src("workbook/ch05/step2/cmd/logscan/naive.go")

#goconcept(title: [`io.ReadAll`])[
  `io.ReadAll(r)` calls `Read` until EOF and returns everything in one
  `[]byte`. It starts with a 512-byte buffer and grows it as data arrives,
  roughly doubling, copying what it has so far each time; at the end the
  data may exist in two buffers at once. That makes it the right tool for
  inputs you know are small (a config file, a short HTTP response from a
  service you control, a test fixture) and a memory bomb for anything whose
  size someone else controls: a log, a request body, a subprocess's output,
  a file in an archive. `os.ReadFile` is the same thing for a named file.
  The fix is not a different function but a bound:
  `io.ReadAll(io.LimitReader(r, max+1))` reads at most one byte more than
  you accept, which tells you the input was too big without reading the
  rest of it. Exercise 5.1 builds that into `fsx`.
]

#goconcept(title: [`bufio.Scanner`])[
  `bufio.NewScanner(r)` splits a reader into tokens, lines by default,
  through an internal buffer. `for sc.Scan() { use(sc.Bytes()) }` is the
  idiomatic line loop, and it reads a file of any size in a fixed amount of
  memory. Two rules come with it. `sc.Bytes()` returns a view into the
  scanner's buffer that the next `Scan` overwrites, so copy it (or use
  `sc.Text()`) if you keep it. And `Scan` returns `false` both at the end of
  the input and on an error, so the loop must be followed by
  `if err := sc.Err(); err != nil`. A line longer than the buffer's maximum,
  64 KiB by default, is an error: `bufio.ErrTooLong`.
]

`scanScanner` has that bug on purpose. The comment says so, and the test
below pins it down, because the point of this lab is to watch it happen on
a realistic file.

=== The command

`logscan` reports its peak memory use, which needs one system call whose
result differs between operating systems: `getrusage(2)` reports the peak
resident set size (`ru_maxrss`) in bytes on macOS and in kilobytes on
Linux. Create three small files, one per platform:

#src("workbook/ch05/step2/cmd/logscan/rss_darwin.go")
#src("workbook/ch05/step2/cmd/logscan/rss_linux.go")
#src("workbook/ch05/step2/cmd/logscan/rss_other.go")

#goconcept(title: [Build constraints and file suffixes])[
  A file named `x_linux.go` is compiled only when `GOOS` is `linux`, and
  `x_darwin.go` only for macOS; the suffix _is_ the constraint. For
  anything more complex, a `//go:build` line before the `package` clause
  holds a boolean expression: `//go:build !linux && !darwin` above selects
  every other platform, so each `GOOS` compiles exactly one `peakRSS`. Get
  that wrong and the build fails for one platform only, which is easy to
  miss on a laptop (the third troubleshooting row below). `go vet` with
  `GOOS=linux` set checks the Linux files from a Mac.
]

Now `cmd/logscan/main.go`. It has the same shape as `loggen`: a small
`main`, a `run` that does the work, and a `report` that prints with
`text/tabwriter` so the columns line up:

#src("workbook/ch05/step2/cmd/logscan/main.go")

`run` reads from a file or, given `-`, from standard input. Either way the
scanners see only an `io.Reader`, so they cannot tell a file from a pipe,
and the same code will later read gzip streams and test strings.

The tests fix the behaviour of both scanners on a small input with a
70,000-byte line in it. Create `cmd/logscan/scan_test.go`:

#src("workbook/ch05/step2/cmd/logscan/scan_test.go")

`TestScannerBugIsSilent` is unusual: it passes when the bug is present. It
documents the trap with two assertions. The naive function returns one line
and no error, and a `bufio.Scanner` on the same input really does have
`bufio.ErrTooLong` waiting in `Err()` for anyone who asks.

=== The big log

Build both programs and generate the log: thirty million lines, with a 1
MiB line at line one million. This takes about half a minute and 2.2 GB of
disk.

#output("ch05/s2-build.txt", cmd: "go build -o bin/ ./cmd/...")
#output("ch05/s2-gen.txt", cmd: "bin/loggen -lines 30000000 -long-at 1000000 -o access.log")

Run the `ReadAll` version. It is correct, and needs more than twice the
file's size in memory to be correct:

#output("ch05/s2-readall.txt", cmd: "bin/logscan -mode readall access.log")

The peak is the sum of two costs. `io.ReadAll` grows its buffer by copying,
so near the end the data briefly exists twice. Then `bytes.Split`
allocates a 24-byte slice header for each of the 30 million lines: another
720 MB that holds no data at all. On a laptop with 24 GB this is merely
wasteful. Most production tools run with far less.

=== The same program in a container

Containers make memory limits concrete, so the next experiment runs
`logscan` on Linux under one. You will reuse this setup in most labs, so it
is worth understanding once. Go cross-compiles by setting two environment
variables, and `CGO_ENABLED=0` makes the result a static binary that needs
no C library:

#output("ch05/s2-linux.txt", cmd: "CGO_ENABLED=0 GOOS=linux go build -o linux/ ./cmd/...")

#goconcept(title: [Cross-compiling])[
  `GOOS` and `GOARCH` choose the target operating system and CPU; the
  defaults are the machine you are on. `GOOS=linux go build` on an Apple
  silicon Mac produces a `linux/arm64` binary, which is what Docker Desktop
  runs natively there; on an Intel machine it produces `linux/amd64`. With
  `CGO_ENABLED=0` the binary contains everything it needs, including Go's
  own DNS resolver, so it runs in an image with no files at all. `go tool dist list` prints every supported pair.
]

The image is described by `scratch.Dockerfile` in the module root. `FROM scratch` is Docker's empty base image: nothing is downloaded, and the
container's file system contains only the binaries you copy in. It runs
them as an unprivileged user, as production images should. Create it:

#src("workbook/ch05/step2/scratch.Dockerfile")

#output("ch05/s2-image.txt", cmd: "docker build -q -f scratch.Dockerfile -t oskit linux")

Now run the `ReadAll` version with a 1 GiB memory limit, mounting the
current directory read-only at `/data` so the container can see the log.
The container is named so you can inspect it afterwards:

#output("ch05/s2-oom.txt", cmd: "docker run --name readall --memory=1g -v \"$PWD:/data:ro\" oskit \\\n    /logscan -mode readall /data/access.log; echo \"exit status $?\"")
#output("ch05/s2-inspect.txt", cmd: "docker inspect -f '{{.State.OOMKilled}}' readall")

Remove the container with `docker rm readall` when you have looked. The
program printed nothing at all: no partial result and no error message,
only exit status 137 (128 + 9, killed by signal 9) and the `OOMKilled`
flag. The kernel's OOM killer sent `SIGKILL` when the container's memory
reached the limit, and `SIGKILL` cannot be caught, so no Go code ran after
it. In Kubernetes this is a pod in `CrashLoopBackOff` with
`reason: OOMKilled` and nothing useful in its logs.

The obvious knob does not help:

#output("ch05/s2-gomemlimit.txt", cmd: "docker run --rm --memory=1g -e GOMEMLIMIT=900MiB -v \"$PWD:/data:ro\" oskit \\\n    /logscan -mode readall /data/access.log; echo \"exit status $?\"")

`GOMEMLIMIT` is a _soft_ limit: it tells the garbage collector to work
harder as the heap approaches it. The collector can free garbage, but every
byte here is live data that the program is still using. No collector can
free it. Step 13 comes back to what `GOMEMLIMIT` is for.

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

The usual fix is `bufio.Scanner`, which reads line by line in a fixed
buffer. On the same file:

#output("ch05/s2-scanner.txt", cmd: "bin/logscan -mode scanner access.log; echo \"exit status $?\"")

One million lines out of thirty, in a fraction of a second, with a tiny
memory footprint and exit status 0. The scan stopped at the 1 MiB line and
the program reported a partial result as if it were the whole file. This
is worse than the OOM kill, because nothing alerts: the dashboards that
consume this job's output just show a quiet night.

There are two fixes, and they answer different questions. If long lines are
legitimate and bounded, give the scanner a bigger ceiling and _always_
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
any ceiling can be exceeded, and one bad line should not stop the job.
That needs a reader that cuts an over-long line short and carries on, which
is what lab 3 builds.

#checkpoint(step: 2, of: 13, title: [What `io.ReadAll` costs])[
  Your module now has a second command and the Dockerfile:
  #output("ch05/s2-tree.txt", cmd: "find . -name '*.go' -o -name '*.Dockerfile' | sort")
  #output("ch05/s2-test.txt", cmd: "go vet ./... && go test ./...")
  You should have seen three things above: the `readall` mode reading all
  thirty million lines with a peak RSS of several gigabytes; the same mode
  killed in a 1 GiB container with status 137, `OOMKilled` true and no
  output, with or without `GOMEMLIMIT`; and the `scanner` mode stopping
  after one million lines with status 0. Your hash for `access.log` must
  match the one above.
  #troubleshoot(
    ([#ts("s2-execformat.txt")], [The binaries in `linux/` were built for your Mac (here `GOOS=linux` was left out), and the kernel in Docker's VM cannot run them.], [Rebuild with `CGO_ENABLED=0 GOOS=linux go build -o linux/ ./cmd/...` and rebuild the image.]),
    ([#ts("s2-novolume.txt")], [The container's file system has only the binaries: `-v "$PWD:/data:ro"` is missing, or the command was not run from the directory with `access.log`.], [Mount the directory, and run from where the log is.]),
    ([#ts("s2-rss.txt")], [No file provides `peakRSS` for Linux (here `rss_linux.go` was deleted); the Mac build still works, so only the cross-compile fails.], [Check the file names and `//go:build` lines: every `GOOS` needs exactly one `peakRSS`.]),
  )
]

#step(3, 13, "Lab 3: Streaming", label: <sec-os-lab3>)

The goal is a scanner that reads all thirty million lines, survives the 1
MiB line, and needs the same few megabytes for a 2 GB log as for a 200 GB
one. The tool is `bufio.Reader`, one level below `bufio.Scanner`.

#goconcept(title: [`bufio.Reader`])[
  `bufio.NewReaderSize(r, n)` wraps a reader in an `n`-byte buffer, so
  that many small reads by your code become a few large reads from `r`.
  Its methods find delimiters in the buffer: `ReadString('\n')` and
  `ReadBytes('\n')` return a fresh copy of the next line, however long it
  is (unbounded memory again), while `ReadSlice('\n')` returns a view into
  the buffer itself, with no copy, and if no newline fits in the buffer it
  returns what it has with `bufio.ErrBufferFull`. That last behaviour is the
  one this lab needs: it lets the caller decide what to do with an
  over-long line instead of growing without limit.
]

=== A line iterator

Lines are a sequence, and since Go 1.23 a function can produce a sequence
that a `for range` loop consumes. Chapter 4 used iterators for streaming
results; here one hides the buffering. Create `cmd/logscan/scan.go` with
the iterator:

#src("workbook/ch05/step3/cmd/logscan/scan.go", region: "lines")

#goconcept(title: [Iterators: `iter.Seq2`])[
  `iter.Seq2[K, V]` is a function type,
  `func(yield func(K, V) bool)`. The iterator calls `yield` once per
  element, and `for k, v := range seq { ... }` turns the loop body into that
  `yield` function. When the body executes `break` or `return`, `yield`
  returns `false`, and the iterator must stop calling it and return. Here
  each element is a line and an error, a common pairing: the loop checks
  `err` on every iteration, just as it would after `Read`. Python
  generators and C\# `yield return` express the same idea, with the
  difference that a Go iterator is an ordinary function you can call,
  store and test.
]

Walk through one iteration. `ReadSlice` returns the next line as a view
into `br`'s buffer, newline included. If the line did not fit,
`ErrBufferFull` comes back with a full buffer: the code copies that buffer
into `long`, a second fixed-size slice made once up front, marks the line
truncated, and calls `ReadSlice` again until the end of the line, throwing
the rest away. Then any real error is reported, EOF is not, a non-empty
line is yielded without its newline, and EOF ends the loop after the last
line, which may lack a trailing newline.

`Line.Bytes` is only valid until the next iteration, for the same reason as
`Scanner.Bytes`: it points into a buffer that the next read reuses. The
copy into `long` is not optional either. The skip loop's `ReadSlice` calls
overwrite the buffer that `b` points into, so yielding `b` itself would
hand the caller the _end_ of the long line, or the start of the next one.
The first troubleshooting row below shows exactly that.

Below `Lines`, add `scan`, which folds the lines into `Stats`:

#src("workbook/ch05/step3/cmd/logscan/scan.go", region: "scan")

=== Directories, gzip and `io/fs`

Real logs rotate. A directory holds `access.log`, `access.log.1.gz`,
`access.log.2.gz` and so on, and a scanner should read all of them, gzipped
or not. Add the last two functions to `scan.go`:

#src("workbook/ch05/step3/cmd/logscan/scan.go", region: "scanfs")

`scanFile` adds a `gzip.Reader` in front of `Lines` when the name ends in
`.gz`. The decompressor is just another `io.Reader`, so nothing after it
changes, and it decompresses as it is read, with a window of about 40 KiB.
@fig-os-pipeline shows the chain for one compressed file: each stage holds
a fixed-size buffer, so memory does not depend on the size of the input.

#fig(caption: [The streaming pipeline for `access.log.1.gz`. Each stage holds a fixed-size buffer, so memory use does not depend on the size of the input.])[
  #diagram(
    spacing: (16pt, 12pt),
    dnode((0, 0), [`fs.File`\ access.log.1.gz], kind: "muted"),
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

`scanFS` takes an `fs.FS`, not a directory name, and that choice pays off
in the tests.

#goconcept(title: [`io/fs` and `fstest.MapFS`])[
  `fs.FS` is a read-only file system as an interface with one method,
  `Open(name) (fs.File, error)`. Names are always slash-separated and
  unrooted (`logs/app.log`, never `/logs` or `../logs`), on every OS.
  Helper functions such as `fs.ReadFile`, `fs.Glob` and `fs.WalkDir` work
  on any implementation, using faster optional methods (`ReadFileFS`,
  `ReadDirFS`, `GlobFS`, `StatFS`, and since Go 1.25 `ReadLinkFS`) when
  they exist. Implementations include `os.DirFS(dir)` for a real
  directory, `embed.FS` for files compiled into the binary, `zip.Reader`,
  `os.Root.FS()` (step 7), and for tests `fstest.MapFS`: a map from path
  to contents, with directories implied. Code written against `fs.FS` can
  be tested without touching the disk.
]

Two more changes finish `Stats`. Add a `Sum` field, for an optional
SHA-256 of the input, to the struct in `stats.go`:

#src("workbook/ch05/step3/cmd/logscan/stats.go", region: "stats")

and `merge`, which adds one file's counts to a total, at the end of the
file:

#src("workbook/ch05/step3/cmd/logscan/stats.go", region: "merge")

=== The command, grown

`main.go` gets three new flags (`-max-line`, `-dir` and `-glob`, plus
`-sum`) and the streaming mode as the default. Replace the top of the file
(package comment and imports), `options` and `main`:

#src("workbook/ch05/step3/cmd/logscan/main.go", region: "imports")
#src("workbook/ch05/step3/cmd/logscan/main.go", region: "main")

Replace `run` and `scanWith`:

#src("workbook/ch05/step3/cmd/logscan/main.go", region: "run")

With `-dir`, `run` hands `os.DirFS` to `scanFS`. With `-sum`, it wraps the
input in an `io.TeeReader` that feeds every byte to a hash on the way to
the scanner, so the checksum costs no second pass over 2 GB. Last, add the
hash to the end of `report`:

#src("workbook/ch05/step3/cmd/logscan/main.go", region: "report")

=== Tests

The new tests go at the end of `scan_test.go`, after the naive ones, and
the import block grows. Replace it:

#src("workbook/ch05/step3/cmd/logscan/scan_test.go", region: "imports")

The first group tests `Lines` directly: truncation, short reads and an
early `break`:

#src("workbook/ch05/step3/cmd/logscan/scan_test.go", region: "lines")

`iotest.OneByteReader` and `iotest.HalfReader` wrap a reader so that every
`Read` returns one byte, or half of what was asked. Both are legal under
the `io.Reader` contract and both are common on pipes, and code that
assumes full reads fails them. `TestLinesStopsWhenTheLoopBreaks` checks the
iterator side of the contract: after `break`, `Lines` must stop.

The second group runs `scan` on the long-line sample, and adds a helper
that gzips a string in memory:

#src("workbook/ch05/step3/cmd/logscan/scan_test.go", region: "stream")

The last test builds a directory with a plain log, a gzipped rotation and a
file the glob must skip, as a map literal. No temporary directory, no
cleanup, and it runs the same on every OS:

#src("workbook/ch05/step3/cmd/logscan/scan_test.go", region: "fstest")

`pkg/sysinfo` in step 8 uses the same idea on a larger scale: it reads
`/proc` and `/sys/fs/cgroup` through an `fs.FS`, so a `MapFS` can play a
container with a 256 MiB memory limit on a Mac.

=== Constant memory

Rebuild and scan the big log with `-sum`; the hash proves every byte went
through the scanner:

#output("ch05/s3-build.txt", cmd: "go build -o bin/ ./cmd/...")
#output("ch05/s3-stream.txt", cmd: "bin/logscan -sum access.log")

All 30 million lines, read at several hundred megabytes a second with a
peak resident set of a few megabytes. The hash matches the one `loggen`
printed, so not a byte was skipped. One line was truncated, the 1 MiB one,
and it also counts as malformed, because its status field was in the part
that was cut off. The file could be 200 GB and the peak would be the same.
The naive scanner, given `-sum`, makes its bug visible: its hash differs,
because it stopped reading early.

#output("ch05/s3-scanner.txt", cmd: "bin/logscan -mode scanner -sum access.log")

Rotated logs work too. Write a small log into a directory, add a gzipped
copy as its rotation, and scan the directory:

#session(
  ("mkdir -p logs", none),
  ("bin/loggen -lines 200000 -o logs/access.log", "ch05/s3-logs.txt"),
  ("gzip -c logs/access.log > logs/access.log.1.gz", "ch05/s3-gzip.txt"),
  ("bin/logscan -dir logs -glob 'access.log*'", "ch05/s3-dir.txt"),
)

Twice 200,000 lines, from one plain and one compressed file. On Linux, in a
container with a 64 MiB limit (a sixteenth of what the `ReadAll` version
was killed at), rebuild the binaries and the image with the two commands
from lab 2 and scan the big log:

#output("ch05/s3-docker.txt", cmd: "docker run --rm --memory=64m -v \"$PWD:/data:ro\" oskit /logscan /data/access.log")

Linux reports a higher peak RSS than macOS for the same program, but it is
just as flat in the input size, and that is the property that matters.

#checkpoint(step: 3, of: 13, title: [Streaming])[
  #output("ch05/s3-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch05/s3-test.txt", cmd: "go vet ./... && go test ./...")
  The streaming scan should report 30,000,000 lines, one truncated and one
  malformed, the same SHA-256 as `loggen` printed in lab 2, and a peak RSS
  of a few megabytes on both macOS and Linux.
  #troubleshoot(
    ([#ts("s3-alias.txt")], [The truncated line was yielded as `b` itself (`Bytes: b`) instead of a copy in `long`. The skip loop's `ReadSlice` calls reused the buffer `b` points into.], [Copy into `long` before skipping. See "A line iterator" and "Slices are windows".]),
    ([#ts("s3-eof.txt")], [`io.EOF` is treated as a failure (`if err != nil` without `!errors.Is(err, io.EOF)`), so every input ends with an error.], [EOF is the normal end of a reader; report only other errors.]),
    ([#ts("s3-yield.txt")], [The iterator ignores `yield`'s result (`yield(line, nil)` on its own line) and keeps calling it after the loop body said stop.], [`if !yield(line, nil) { return }`. See "Iterators".]),
    ([#ts("s3-glob.txt")], [The `-glob` pattern included the directory (`-glob 'logs/access.log*'`). Names in an `fs.FS` are relative to its root, so nothing matched, and the scan quietly found zero files.], [Use `-glob 'access.log*'`.]),
  )
]

#step(4, 13, "Lab 4: Torn writes", label: <sec-os-lab4>)

Reading is half of I/O. This lab looks at writing, specifically at
rewriting a file that someone else is reading, which is what every config
deploy does. `os.WriteFile` opens the file with `O_TRUNC`, writes, and
closes. That is three separate moments when another process can look at
the file, and two of them show something that is neither the old version
nor the new one.

`torn` rewrites a 256 KiB config file in a loop while a goroutine reads it,
the way a service polls its config, and classifies every read: empty (it
caught the moment after truncation), short (it caught a partial write), or
mixed (it read the start of one version and the end of another). Create
`cmd/torn/main.go`, starting with the package comment, imports and `main`:

#src("workbook/ch05/step4/cmd/torn/main.go", region: "imports")
#src("workbook/ch05/step4/cmd/torn/main.go", region: "main")

The write strategy is a value, so step 5 can add a second one without
touching the loop. Add the type and the function that picks it:

#src("workbook/ch05/step4/cmd/torn/main.go", region: "writer")

#goconcept(title: [Function types])[
  Functions are values in Go: you can store them in variables, pass them
  and return them. `type writeFunc func(name string, data []byte, perm fs.FileMode) error` names a function _signature_, and any function with
  exactly that signature is a `writeFunc`, including `os.WriteFile`
  itself, which `writer` returns without calling. Parameter names do not
  matter, but every type does: change `perm` to `int` and `os.WriteFile` no
  longer fits (the last troubleshooting row). Function types are Go's
  lightweight alternative to a one-method interface; `http.HandlerFunc` is
  the best-known one.
]

Then the experiment and the payload:

#src("workbook/ch05/step4/cmd/torn/main.go", region: "run")
#src("workbook/ch05/step4/cmd/torn/main.go", region: "payload")

The counters `reads`, `empty`, `short` and `mixed` are plain `int`s written
by the reader goroutine and read by `main` only after `wg.Wait()`. That is
safe without atomics because `Wait` establishes the ordering: everything
the goroutine did happens before `Wait` returns. `stop` is different. Both
goroutines touch it while both are running, so it is an `atomic.Bool`.
Chapter 4 covers the rule; the second troubleshooting row shows the race
detector enforcing it.

`os.MkdirTemp` creates a fresh directory under the system's temporary
directory with a random suffix, and `defer os.RemoveAll(dir)` removes it
however `run` returns. The payload's every byte names its version, so a
mixed read is easy to detect.

#checkpoint(step: 4, of: 13, title: [Torn writes])[
  #output("ch05/s4-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch05/s4-test.txt", cmd: "go vet ./... && go test ./...")
  Build and run `torn` for the default two seconds, then for five:
  #output("ch05/s4-build.txt", cmd: "go build -o bin/ ./cmd/...")
  #output("ch05/s4-torn.txt", cmd: "bin/torn")
  #output("ch05/s4-torn2.txt", cmd: "bin/torn -for 5s")
  Your counts will differ, but `torn` should be well above zero, with most
  torn reads empty.
  #troubleshoot(
    ([#ts("s4-functype.txt")], [`writeFunc`'s `perm` parameter is an `int`, so `os.WriteFile` (whose `perm` is an `fs.FileMode`) is not a `writeFunc`. The now-unused `io/fs` import is reported first.], [Match the signature exactly. See "Function types".]),
    ([#ts("s4-race.txt")], [`main` reads the counters before `wg.Wait()` returns, while the reader goroutine still writes them. Run with `-race` to see it.], [Print after `wg.Wait()`.]),
    ([#ts("s4-tmp.txt")], [`defer os.RemoveAll(dir)` is missing, so every run leaves a `torn-*` directory with a 256 KiB file in your temporary directory.], [Remove what you create, with `defer` right after creating it.]),
  )
]

Read the numbers carefully: a large share of reads saw an empty or
truncated file, and some runs also catch a read that mixes both versions.
The exact rate depends on the machine and the file system, but it is never
zero. A service that treats "empty config" as "no routes" has an outage
measured in milliseconds, which is often enough to matter when a thousand
instances poll the same file.

Concurrent readers are the visible half of the problem. The other half is
crashes. File systems do not write your data to disk when `write` returns:
the data sits in the page cache and reaches the device later, often tens
of seconds later, in an order the file system chooses. After a power loss
or kernel panic, a file updated with truncate-and-write can come back
empty, or with its old size but new contents in some blocks. In 2009,
ext4's delayed allocation made zero-length files after crashes common
enough that the kernel added heuristics (the `auto_da_alloc` mount option)
to protect applications that replaced files without calling `fsync`. Do
not depend on heuristics. Step 5 builds the sequence that does not need
them.
