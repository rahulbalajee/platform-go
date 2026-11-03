#import "../../template/book.typ": *

#solutions-for(5, "Talking to the Operating System: I/O, Files, Processes, and Signals")

Every code exercise in Chapter 5 starts from the finished step 13 module,
`oskit`. Copy the acceptance tests from `workbook/ch05/exercises/exK` into
your module, keeping their subdirectories, and watch them fail before you
start. When you are done, `go test -race ./...` and `golangci-lint run ./...` should both be clean, and the tests you had before must still pass.

#solution(5, 1, title: [A bounded `ReadFile`], code: "solutions/ch05/ex1")[
  The whole solution is one wrapper around a reader:

  #src("solutions/ch05/ex1/fsx/readlimit.go")

  `io.LimitReader(f, limit+1)` is the trick from lab 2 and from
  `atomicput`. If the file has at most `limit` bytes, `io.ReadAll` gets all
  of them and then EOF. If it has more, the limited reader stops after
  `limit + 1`, and that one extra byte is the proof that the file is too
  big. The function never learns the real size and never needs to, which
  is why `/dev/zero`, a file that never ends, costs a megabyte and not all
  of memory.

  The tempting alternative is to `Stat` the file and compare `Size()` with
  the limit before reading. It fails twice. A FIFO, a character device, or
  a file in `/proc` reports size 0 and then produces any amount of data.
  And a log that is being appended to can grow between the `Stat` and the
  read. A check that runs before the operation is a race; a limit applied
  _during_ the operation is not. (A `Stat` check is still a fine first step
  if you want to fail fast on obviously huge regular files, as long as the
  limited read stays.)

  The error wraps `ErrTooLarge` with `%w` and names the file, so callers
  can test for it with `errors.Is` and a person reading the log knows which
  file to look at. Errors from `os.Open` are returned unwrapped: they
  already name the file and already match `fs.ErrNotExist`. Returning `nil`
  rather than the first `limit` bytes is deliberate: a truncated config
  file that happens to parse is worse than an error.
]

#solution(5, 2, title: [Prefix a child's output], code: "solutions/ch05/ex2")[
  #src("solutions/ch05/ex2/procx/prefix.go")

  `Write` appends to a buffer and then emits every complete line it holds,
  so the chunking of the input does not matter: a line split across ten
  writes is emitted once, when its newline arrives. Returning `len(p)` for
  bytes that are only buffered is honest under the `io.Writer` contract,
  because the writer _has_ taken responsibility for them; `bufio.Writer`
  does the same. What the contract forbids is returning less than `len(p)`
  without an error, which would make `io.Copy` fail with `ErrShortWrite`.
  When the underlying writer fails, `Write` returns `0` and the error,
  which `io.Copy` and `os/exec` pass on.

  The mutex is what makes the type safe for `os/exec`. With
  `cmd.Stdout = pw` and `cmd.Stderr = pw`, two goroutines copy from two
  pipes into the same `PrefixWriter`, and without the lock they would race
  on `buf`; the race detector finds that in the concurrency test. The lock
  also gives the second guarantee the test checks: `emit` writes the prefix
  and the line in a single `Write` to the destination, so lines from
  stdout and stderr never interleave in the middle. Writing the prefix and
  the line with two calls would pass a single-goroutine test and fail
  under load.

  `Flush` exists because a child's last line may have no newline. It is a
  separate method rather than something `Write` guesses at, because only
  the caller knows when the stream has ended: after `cmd.Wait()` returns.
  The `nolint` comment on its `append` answers `gocritic`, which warns that
  appending to one slice and assigning the result to another can share
  memory; here `buf` is dropped on the next line, so the sharing is
  harmless.

  One trap the tests do not cover: `buf` has no size limit. A child that
  prints a gigabyte without a newline would make `PrefixWriter` hold a
  gigabyte, which is lab 2's bug in a new place. A production version
  would emit the buffer as a line once it passes some size, the way `Lines`
  in lab 3 truncates.
]

#solution(5, 3, title: [Stale pid files, done properly])[
  *What goes in the file.* The PID and the process's start time from field
  22 of `/proc/<pid>/stat`, in clock ticks since boot, for example
  `4242 98765`. Add the boot ID from `/proc/sys/kernel/random/boot_id` if
  the file can outlive a reboot (it should not, if it lives in `/run`). The
  kernel can reuse a PID, but not a (PID, start time) pair within one boot,
  because a new process with the same PID necessarily started later.

  *Deciding staleness.* Read the file and call
  `sysinfo.ReadStat(fsys, pid)`. The file is live if that succeeds, the
  state is not `Z`, and `StartTime` matches. Anything else (no such
  process, a different start time, a zombie) means the holder is gone.

  *Replacing it without a race.* The naive sequence is "decide stale,
  delete, create with `O_EXCL`". Two processes, A and B, can both decide
  the file is stale; A deletes it and creates its own; B, a moment later,
  deletes _A's new file_ and creates its own; both proceed. The fix is to
  never delete a file you have not just verified, and to make each change
  of ownership a single atomic system call. Write your own record to a
  temporary file, then use `link(2)` (`os.Link`) to give it the lock
  file's name: `link` fails with `EEXIST` if the name exists, atomically,
  like `O_EXCL`. To take over a stale file, `rename` it to a name only you
  use (`lock.stale.<your-pid>`). Only one process can rename a given file
  away, so the loser's `rename` fails with `ENOENT` and it starts over.
  The winner re-reads what it renamed. If it is still the stale record it
  checked, the winner deletes it and links its own record into place
  (which fails with `EEXIST` if a third process got there first; then it
  starts over too).

  The scheme still has a hole, and finding it is the point of the
  exercise. If the record the winner renamed away is _fresh_, because
  another process completed a takeover between the check and the rename,
  the winner has just broken a live lock. It can link the file back, but
  in that moment a fourth process can see no lock file and create one.
  Closing that window needs a second lock around the whole takeover (a
  "breaker" file created with `O_EXCL`), and the breaker file can itself
  go stale if its creator crashes. Every fix moves the race instead of
  removing it, because a file system offers no compare-and-swap on what a
  name points to.

  *What this still cannot do.* It is far more code than `flock`, and every
  step is a place to get it wrong. It depends on `/proc`, so it is Linux
  only. It breaks when processes see different PID namespaces: two
  containers sharing a volume see different PIDs for the same process. It
  cannot detect a holder that is alive but stuck. And on NFS, `link` and
  `rename` are weaker than on a local disk. `flock` has none of these
  problems for processes on one machine, because the kernel ties the lock
  to the holder's open file and releases it on exit, whatever the cause.
  Use the pid in the file for what it is good at, telling an operator which
  process to look at, and use `flock` for the exclusion. That is exactly
  what `fsx.Lock` does with its holder record.
]

#solution(5, 4, title: [Container-aware memory limit], code: "solutions/ch05/ex4")[
  #src("solutions/ch05/ex4/sysinfo/memlimit.go")

  The order of the checks is the specification. An explicit `GOMEMLIMIT`
  wins over everything, because an operator who set it knows something
  the code does not. `os.Getenv` returns `""` both when the variable is
  unset and when it is set to the empty string, and the Go runtime treats
  both as "no limit", so the function does the same; the tests set it to
  `""` with `t.Setenv` to check exactly that. A ratio outside `(0, 1]` is
  a programming error, but returning 0 with a reason is kinder to a
  long-running service than a panic.

  `memory.high` replaces `memory.max` only when it is set and lower. Above
  `memory.high` the kernel throttles the group and reclaims aggressively,
  so a Go heap that grows past it slows the whole service down long before
  the OOM killer would act; aiming the collector at a fraction of
  `memory.high` avoids that. When `memory.high` is higher than
  `memory.max`, it can never be reached, and the test checks that it is
  ignored.

  The arithmetic is done in `float64` and converted once: 256 MiB times
  0.9 is 241,591,910.4 bytes, which truncates to the value the test
  expects. `limits` replaces `memLimitFor` with the new function and logs
  its decision:

  #src("solutions/ch05/ex4/cmd/limits/main.go", region: "setmem")

  Always returning a reason is the part that matters in production. A
  service that silently sets its own memory limit is a service whose
  behaviour nobody can explain six months later; one log line at startup
  settles it.
]

#solution(5, 5, title: [Zip archives too], code: "solutions/ch05/ex5")[
  The way to share code with `ExtractTar` is to split its per-entry logic
  into pieces that do not depend on the archive format. In the solution,
  `extract.go` gains a `withDefaults` method for `Limits`, and
  `extractEntry` keeps only the `switch` on the tar entry type. Creating a
  file and creating a symlink move into two functions that take plain
  values:

  #src("solutions/ch05/ex5/fsx/extract.go", region: "shared")

  `ExtractZip` then mirrors `ExtractTar`:

  #src("solutions/ch05/ex5/fsx/extractzip.go", region: "zip")

  The file limit can be checked before anything is written, because a zip
  archive's central directory lists every entry; `len(zr.File)` is known
  up front in a way a tar stream's entry count is not, since a tar reader
  only learns about entries as it reaches them. The byte limit is the
  opposite. Each `zip.File` carries an `UncompressedSize64`, but that
  number comes from the archive, and a zip bomb lies about it. The test
  builds a megabyte of zeros, which deflates to about a kilobyte, and the
  solution counts what actually comes out of `f.Open()` through the same
  `LimitReader` budget as the tar code.

  Symlinks are the format difference that matters. Tar headers have a
  `Linkname` field; zip stores the target as the entry's contents, so the
  solution reads it through a small limit of its own (no symlink target
  needs more than 4 KiB) and passes it to the same `createSymlink`, with
  the same lexical check. Directories are entries whose mode has
  `fs.ModeDir`, and `mode.Perm()` drops setuid and setgid exactly as for
  tar.

  The duplicate-name case needs no code: `createFile` opens with `O_EXCL`,
  so the second `a.txt` fails as it does for tar. That is the payoff of
  sharing the code: each guarantee is implemented once, and the second
  format inherits all of them.
]

#solution(5, 6, title: [A staged directory install], code: "solutions/ch05/ex6")[
  #src("solutions/ch05/ex6/fsx/install.go", region: "install")

  The structure is step 5's atomic write, one level up. The new version is
  built completely in a fresh hidden directory beside `dst` (same
  directory, so the final rename is local), copied with `os.CopyFS` and
  flushed with `syncTree`, which opens and `fsync`s every file and
  directory in it through an `os.Root`. Only then does the switch happen,
  and the switch is a `rename` of a new symlink over `dst`, which POSIX
  makes atomic: a process that resolves `dst` gets the old target or the
  new one. The symlink is relative (`.current-123`, not an absolute path),
  so the tree can be moved or bind-mounted without breaking it. A deferred
  cleanup removes the new version and the temporary link on any failure
  before the switch, and `done` stops it from removing the version that
  `dst` now points to.

  Refusing a real directory at `dst` comes for free: `os.Readlink` fails
  with `EINVAL` on something that is not a symlink, and that error is
  returned before anything is created. Replacing a directory the caller
  made by hand would delete their files.

  Cleanup is where the subtle bug hides. Deleting the previous version
  right after the switch looks tidy and is wrong: a reader that resolved
  `dst` to the old version a moment before the switch may still be opening
  `config.yaml` inside it, and would get `ENOENT`. The solution keeps the
  previous version and deletes only older ones, which gives every reader a
  full install cycle to finish. A reader that holds files open for longer
  than that is safe anyway on Unix, because an open file survives the
  removal of its name; the risk is only in the window between resolving
  the path and opening the file.

  The guarantee is per open, which matters for readers that need several
  files. Two opens through `dst` can straddle a switch and get
  `config.yaml` from one version and `routes.yaml` from the next. A reader
  that needs a consistent set resolves `dst` once (`os.Readlink`, or
  `os.OpenRoot(dst)`, which holds the directory it resolved) and reads
  every file through that.

  The macOS allowance in the test is real behaviour, not a test bug. When
  a symlink is replaced while another thread is resolving a path through
  it, macOS can fail the lookup with `EINVAL`; a retry succeeds. In the
  book's runs the test logged a handful of these per run on macOS and
  none in the Linux container, where the lookup always finds the old link
  or the new one. Code that reads through a swapped symlink on macOS
  should retry an `EINVAL`.

  Two installs racing each other are not covered: both could create
  versions and rename links, and the prune of one could remove the
  version the other just installed. The doc comment says so, and the fix
  is step 6: hold an `fsx.Lock` on a file beside `dst` for the whole
  install.
]
