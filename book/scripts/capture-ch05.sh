#!/usr/bin/env bash
# Regenerates every terminal block in Chapter 5 (book/output/ch05): the
# checkpoints of all thirteen steps and labs, and the troubleshooting rows,
# each made by breaking a copy of a snapshot and keeping what Go, the linter,
# the tests or the kernel said.
#
# Usage, from the repository root (bash reads a script while it runs it, so
# run a copy if you might edit this file meanwhile):
#   cp book/scripts/capture-ch05.sh "$TMPDIR/c5.sh" && bash "$TMPDIR/c5.sh"
#
# Needs go, docker (no image is pulled: the Linux programs run in a FROM
# scratch image built from cross-compiled binaries), golangci-lint, about
# 2.5 GB of free disk for the generated access log, and ten minutes.
set -euo pipefail
unset GOFLAGS GOPROXY GOMODCACHE GONOSUMDB GOTOOLCHAIN GOWORK
export PATH="$HOME/go/bin:$PATH" COLUMNS=80
root=$(pwd)
out=$root/book/output/ch05
wb=$root/workbook/ch05
# FROM=k reruns only steps k and later, keeping the earlier captures.
from=${FROM:-1}
want() { (( $1 >= from )); }
if (( from == 1 )); then rm -rf "$out"; fi
mkdir -p "$out/ts"
tmpbase=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmpbase%/}/ch05.XXXXXX")
mkdir -p "$work/tmp"
export TMPDIR=$work/tmp
cleanup() {
  docker rm -f ch05-readall > /dev/null 2>&1 || true
  rm -f /tmp/lockdemo.lock /tmp/lockdemo.pid
  rm -rf "$work"
}
trap cleanup EXIT

goroot=$(go env GOROOT)
# Absolute paths, image IDs and goroutine addresses change on every run;
# nothing else is edited. Tabs are expanded the way a terminal shows them.
scrub() {
  sed -E -e "s#${work}/tmp/#\$TMPDIR/#g" -e "s#${work}/#~/#g" -e "s#${goroot}#\$GOROOT#g" \
    -e "s#${HOME}#~#g" -e "s#host=$(hostname)#host=devbox#g" \
    -e 's#sha256:([0-9a-f]{12})[0-9a-f]{52}#sha256:\1…#g' \
    -e 's#0x[0-9a-f]{9,}#0x…#g' \
    -e 's#^.*line [0-9]+: +[0-9]+ (Killed|Hangup)(.*)$#\1\2#' | expand -t 8
}
# cap FILE CMD: run CMD (a shell string) in the current directory and save
# its scrubbed stdout and stderr. A failing command is expected, not fatal.
cap() {
  local f=$1; shift
  set +e; ( eval "$*" ) > "$out/$f.raw" 2>&1; set -e
  scrub < "$out/$f.raw" > "$out/$f"; rm -f "$out/$f.raw"
}
# run CMD: for multi-command sessions captured into one file. Prints the
# command the way a prompt would, then runs it.
run() { printf '$ %s\n' "$1"; set +e; eval "$1"; set -e; }
# key FILE PATTERN [N]: the first N (default 1) lines of a capture matching
# PATTERN, quoted in the troubleshooting tables.
key() {
  grep -E -m "${3:-1}" -e "$2" "$out/$1" > "$out/ts/$1" ||
    { echo "no match for '$2' in $1"; cat "$out/$1"; exit 1; }
}

# The reader's project directory. Each step replaces the source files and
# keeps everything else (the access log, bin/, linux/).
proj=$work/oskit
use_step() {
  mkdir -p "$proj"
  find "$proj" -name '*.go' -delete
  rm -f "$proj/go.mod" "$proj/go.sum" "$proj/scratch.Dockerfile"
  (cd "$wb/step$1" && tar cf - .) | (cd "$proj" && tar xf -)
  cd "$proj"
}
# broken STEP: a scratch copy of a snapshot, plus the repo's lint config.
broken() {
  rm -rf "$work/broken"; mkdir -p "$work/broken"
  (cd "$wb/step$1" && tar cf - .) | (cd "$work/broken" && tar xf -)
  cp "$root/.golangci.yml" "$work/broken/"
  cd "$work/broken"
}
# edit FILE PERL: apply a perl substitution and insist that it changed FILE.
edit() {
  local before; before=$(cksum < "$1")
  perl -0pi -e "$2" "$1"
  [[ $(cksum < "$1") != "$before" ]] || { echo "edit did not apply to $1: $2"; exit 1; }
}
# deps STEP MODULE@VERSION: the reader's `go get` and `go mod tidy` for STEP,
# run on the previous step's go.mod. The result must equal the snapshot's.
deps() {
  local k=$1; shift
  cp "$wb/step$((k - 1))/go.mod" go.mod
  if [[ -f $wb/step$((k - 1))/go.sum ]]; then cp "$wb/step$((k - 1))/go.sum" go.sum; else rm -f go.sum; fi
  cap "s$k-goget.txt" "go get $*"
  cap "s$k-tidy.txt" 'go mod tidy'
  cmp -s go.mod "$wb/step$k/go.mod" || { echo "go.mod differs from step$k"; exit 1; }
}
tree() { cap "s$1-tree.txt" "find . -name '*.go' | sort"; }
# lstree STEP DIR...: the commands and packages in columns, once the full
# file list gets too long to print.
lstree() { local k=$1; shift; cap "s$k-tree.txt" "ls -C $*"; }
# image [TAG]: the Linux build of every command, in an empty image.
image() {
  local tag=${1:-oskit}
  rm -rf linux
  CGO_ENABLED=0 GOOS=linux go build -o linux/ ./cmd/...
  docker build -q -f scratch.Dockerfile -t "$tag" linux > /dev/null
}

if want 1; then
echo "== lab 1: readers and writers"
mkdir -p "$proj" && cd "$proj"
cap s1-modinit.txt 'go mod init oskit'
cap s1-goget.txt 'go get go@1.27.0'
use_step 1
tree 1
cap s1-test.txt 'go vet ./... && go test ./...'
cap s1-lines.txt 'go run ./cmd/loggen -lines 3'
cap s1-bytes.txt 'go run ./cmd/loggen -lines 0 -bytes 200; echo'
cap s1-build.txt 'go build -o bin/ ./cmd/...'
cap s1-file.txt 'bin/loggen -lines 1000000 -o access.log'
cap s1-shasum.txt 'shasum -a 256 access.log; wc -lc access.log'
cat > "$work/median.py" <<'EOF'
import re, statistics, sys
runs, order = {}, []
for line in sys.stdin:
    if line.startswith("cpu:"):
        print(line.strip())
    m = re.match(r"BenchmarkCopy/(\S+?)-\d+\s+\d+\s+\d+ ns/op\s+([\d.]+) MB/s"
                 r"\s+([\d.]+) B/write", line)
    if m:
        if m.group(1) not in runs:
            order.append(m.group(1))
        runs.setdefault(m.group(1), []).append((float(m.group(2)), int(float(m.group(3)))))
print("%-22s %8s %15s" % ("benchmark", "MB/s", "largest write"))
for name in order:
    mbs = statistics.median(r[0] for r in runs[name])
    print("%-22s %8.0f %13d B" % (name, mbs, runs[name][0][1]))
EOF
go test -run '^$' -bench . -benchtime 20x -count 5 ./cmd/loggen 2>&1 \
  | python3 "$work/median.py" > "$out/s1-bench.txt"

broken 1; edit cmd/loggen/count.go 's/\treturn len\(p\), nil/\treturn 0, nil/'
cap s1-short.txt 'go run ./cmd/loggen -lines 3 -o x.log'; key s1-short.txt 'short write'
broken 1; edit cmd/loggen/main.go 's/io.MultiWriter\(f, sum, &count\)/io.MultiWriter(f, sum, count)/'
cap s1-pointer.txt 'go build ./...'; key s1-pointer.txt 'does not implement|pointer receiver' 2
broken 1; edit cmd/loggen/gen.go 's/\tif n == 0 && len\(p\) > 0 \{\n\t\treturn 0, io.EOF\n\t\}\n//'
edit cmd/loggen/gen.go 's/\t"io"\n//'
cap s1-noeof.txt 'go test -timeout 10s ./cmd/loggen'; key s1-noeof.txt 'test timed out|^ +TestLogReader|logReader\)\.Read' 3
broken 1; edit cmd/loggen/gen.go 's#"math/rand/v2"#"math/rand"#'
cap s1-randv1.txt 'go build ./...'; key s1-randv1.txt 'NewPCG|undefined' 1

fi

if want 2; then
echo "== lab 2: what io.ReadAll costs"
use_step 2
cap s2-tree.txt "find . -name '*.go' -o -name '*.Dockerfile' | sort"
cap s2-test.txt 'go vet ./... && go test ./...'
cap s2-build.txt 'go build -o bin/ ./cmd/...'
cap s2-gen.txt 'bin/loggen -lines 30000000 -long-at 1000000 -o access.log'
cap s2-readall.txt 'bin/logscan -mode readall access.log'
cap s2-scanner.txt 'bin/logscan -mode scanner access.log; echo "exit status $?"'
cap s2-linux.txt 'CGO_ENABLED=0 GOOS=linux go build -o linux/ ./cmd/...'
cap s2-image.txt 'docker build -q -f scratch.Dockerfile -t oskit linux'
docker rm -f readall > /dev/null 2>&1 || true
cap s2-oom.txt 'docker run --name readall --memory=1g -v "$PWD:/data:ro" oskit \
    /logscan -mode readall /data/access.log; echo "exit status $?"'
cap s2-inspect.txt "docker inspect -f '{{.State.OOMKilled}}' readall"
docker rm readall > /dev/null
cap s2-gomemlimit.txt 'docker run --rm --memory=1g -e GOMEMLIMIT=900MiB -v "$PWD:/data:ro" oskit \
    /logscan -mode readall /data/access.log; echo "exit status $?"'

broken 2; rm -rf linux
CGO_ENABLED=0 go build -o linux/ ./cmd/...   # forgot GOOS=linux: a macOS binary
docker build -q -f scratch.Dockerfile -t oskit-broken linux > /dev/null
cap s2-execformat.txt 'docker run --rm oskit-broken /logscan'; key s2-execformat.txt 'exec format error'
cap s2-novolume.txt 'docker run --rm oskit /logscan /data/access.log'; key s2-novolume.txt 'no such file'
broken 2; rm cmd/logscan/rss_linux.go
cap s2-rss.txt 'CGO_ENABLED=0 GOOS=linux go build -o linux/ ./cmd/...'; key s2-rss.txt 'undefined: peakRSS'

fi

if want 3; then
echo "== lab 3: streaming"
use_step 3
tree 3
cap s3-test.txt 'go vet ./... && go test ./...'
cap s3-build.txt 'go build -o bin/ ./cmd/...'
[[ -f access.log ]] || bin/loggen -lines 30000000 -long-at 1000000 -o access.log 2> /dev/null
cap s3-stream.txt 'bin/logscan -sum access.log'
cap s3-scanner.txt 'bin/logscan -mode scanner -sum access.log'
mkdir -p logs
cap s3-logs.txt 'bin/loggen -lines 200000 -o logs/access.log'
cap s3-gzip.txt 'gzip -c logs/access.log > logs/access.log.1.gz'
cap s3-dir.txt "bin/logscan -dir logs -glob 'access.log*'"
image
cap s3-docker.txt 'docker run --rm --memory=64m -v "$PWD:/data:ro" oskit /logscan /data/access.log'

broken 3; edit cmd/logscan/scan.go 's/Bytes: append\(long\[:0\], b...\), Truncated: true/Bytes: b, Truncated: true/'
edit cmd/logscan/scan.go 's/\t\tlong := make\(\[\]byte, 0, max\).*?\n//'
cap s3-alias.txt 'go test ./cmd/logscan'; key s3-alias.txt 'lines = |stream: ' 1
broken 3; edit cmd/logscan/scan.go 's/\t\t\tif err != nil && !errors.Is\(err, io.EOF\) \{/\t\t\tif err != nil {/'
cap s3-eof.txt 'go test ./cmd/logscan'; key s3-eof.txt '^--- FAIL|EOF' 2
broken 3; edit cmd/logscan/scan.go 's/\t\t\t\tif !yield\(line, nil\) \{\n\t\t\t\t\treturn\n\t\t\t\t\}/\t\t\t\tyield(line, nil)/'
cap s3-yield.txt 'go test ./cmd/logscan'; key s3-yield.txt '^panic'
cd "$proj"
cap s3-glob.txt "bin/logscan -dir logs -glob 'logs/access.log*'"; key s3-glob.txt '^lines'

fi

if want 4; then
echo "== lab 4: torn writes"
use_step 4
tree 4
cap s4-test.txt 'go vet ./... && go test ./...'
cap s4-build.txt 'go build -o bin/ ./cmd/...'
cap s4-torn.txt 'bin/torn'
cap s4-torn2.txt 'bin/torn -for 5s'

broken 4; edit cmd/torn/main.go 's/\tstop.Store\(true\)\n\twg.Wait\(\)\n\tfmt.Printf\((.*?)\n(.*?)\n/\tstop.Store(true)\n\tfmt.Printf($1\n$2\n\twg.Wait()\n/s'
cap s4-race.txt 'go run -race ./cmd/torn -for 200ms'; key s4-race.txt 'DATA RACE|by main goroutine|torn/main.go:9[0-9]' 3
broken 4; edit cmd/torn/main.go 's/\tdefer os.RemoveAll\(dir\)\n//'
cap s4-tmp.txt 'go run ./cmd/torn -for 100ms > /dev/null; go run ./cmd/torn -for 100ms > /dev/null; ls -d "$TMPDIR"/torn-*'
key s4-tmp.txt 'torn-' 2
broken 4; edit cmd/torn/main.go 's/perm fs.FileMode\) error/perm int) error/'
cap s4-functype.txt 'go build ./...'; key s4-functype.txt 'cannot use'

fi

if want 5; then
echo "== step 5: atomic replacement"
use_step 5
deps 5 go.uber.org/goleak@v1.3.0
lstree 5 cmd fsx
cap s5-test.txt 'go vet ./... && go test ./...'
cap s5-build.txt 'go build -o bin/ ./cmd/...'
cap s5-naive.txt 'bin/torn -mode naive'
cap s5-atomic.txt 'bin/torn -mode atomic'
cap s5-put.txt "echo '{\"replicas\": 3}' | bin/atomicput deploy.json && cat deploy.json"
cap s5-big.txt 'head -c 100 /dev/zero | bin/atomicput -max 10 deploy.json; echo "exit status $?"; cat deploy.json'
cap s5-debris.txt 'ls -a | grep deploy'

broken 5; edit fsx/atomic.go 's/\t\/\/ 3\. CreateTemp uses 0600; set the mode the caller asked for\.\n\tif err := f.Chmod\(perm\); err != nil \{\n\t\treturn fmt.Errorf\("atomic write %s: %w", name, err\)\n\t\}\n//'
cap s5-chmod.txt 'go test ./fsx'; key s5-chmod.txt 'mode = '
broken 5; edit fsx/atomic.go 's/\tdefer func\(\) \{\n\t\tif !renamed \{.*?\n\t\}\(\)\n//s'
edit fsx/atomic.go 's/\ttmp, renamed := f.Name\(\), false\n/\ttmp := f.Name()\n/'
edit fsx/atomic.go 's/\trenamed = true\n//'
cap s5-debris-test.txt 'go test ./fsx'; key s5-debris-test.txt 'directory has'
broken 5; edit fsx/atomic.go 's/os.CreateTemp\(dir, /os.CreateTemp("", /'
image oskit-broken
cap s5-exdev.txt "echo '{}' | docker run -i --rm --tmpfs /tmp --tmpfs /data:mode=1777 oskit-broken \\
    /atomicput /data/deploy.json"
key s5-exdev.txt 'cross-device'
broken 5; cp "$wb/step4/go.mod" go.mod; rm -f go.sum
cap s5-nogoleak.txt 'go vet ./...'; key s5-nogoleak.txt 'no required module'

fi

if want 6; then
echo "== step 6: locks"
use_step 6
deps 6 golang.org/x/sys@v0.49.0
lstree 6 cmd fsx
cap s6-test.txt 'go vet ./... && go test ./...'
cap s6-build.txt 'go build -o bin/ ./cmd/...'
rm -f /tmp/lockdemo.lock /tmp/lockdemo.pid
{
  run 'bin/lockdemo -pidfile -lock /tmp/lockdemo.pid -name F -hold 60s & sleep 1; kill -9 $!'
  sleep 0.5
  run 'bin/lockdemo -pidfile -lock /tmp/lockdemo.pid -name G; echo "exit status $?"'
} > "$out/s6-pidfile.raw" 2>&1
scrub < "$out/s6-pidfile.raw" > "$out/s6-pidfile.txt"; rm "$out/s6-pidfile.raw"
{
  run 'bin/lockdemo -name A -hold 3s &'
  sleep 1
  run 'bin/lockdemo -name B; echo "exit status $?"'
  run 'bin/lockdemo -name C -wait 5s'
  run 'bin/lockdemo -name D -hold 60s & sleep 1; kill -9 $!'
  sleep 0.5
  run 'bin/lockdemo -name E -hold 0s'
} > "$out/s6-flock.raw" 2>&1
scrub < "$out/s6-flock.raw" > "$out/s6-flock.txt"; rm "$out/s6-flock.raw"
rm -f /tmp/lockdemo.lock /tmp/lockdemo.pid
cap s6-crash.txt "go test -v -run 'TestLockReleasedWhenHolderIsKilled|TestAcquire' ./fsx 2>&1 | grep -E '^(--- |ok)'"

broken 6; cp "$wb/step5/go.mod" go.mod; cp "$wb/step5/go.sum" go.sum
cap s6-xsys.txt 'go build ./...'; key s6-xsys.txt 'no required module' 1
broken 6; edit fsx/lock_unix.go 's/flock\(f, unix.LOCK_EX\|unix.LOCK_NB\)/flock(f, unix.LOCK_EX)/'
cap s6-block.txt 'go test -timeout 10s -run TestTryLockIsExclusive ./fsx'
key s6-block.txt 'test timed out|unix.Flock\(' 2
broken 6; edit fsx/lock_unix.go 's/func lockFile\(f \*os.File\) error   \{ return flock\(f, unix.LOCK_EX\|unix.LOCK_NB\) \}/func lockFile(f *os.File) error {\n\tlk := unix.Flock_t{Type: unix.F_WRLCK} \/\/ whole file\n\treturn unix.FcntlFlock(f.Fd(), unix.F_SETLK, &lk)\n}/'
cap s6-fcntl.txt 'go test -run TestTryLockIsExclusive ./fsx'; key s6-fcntl.txt 'second TryLock'
broken 6; edit fsx/lock.go 's/if errors.Is\(err, errWouldBlock\) \{/if err == errWouldBlock {/'
cap s6-eq.txt 'go test -run TestTryLockIsExclusive ./fsx'; key s6-eq.txt 'second TryLock'

fi

if want 7; then
echo "== step 7: extraction"
use_step 7
lstree 7 cmd fsx
cap s7-test.txt 'go vet ./... && go test ./...'
cap s7-build.txt 'go build -o bin/ ./cmd/...'
mkdir -p evil && cd evil
{
  run '../bin/untar -make-evil evil.tar'
  run '../bin/untar -naive evil.tar out'
  run 'find . -type f | sort'
  rm -rf out escaped.txt via-symlink.txt
  run '../bin/untar evil.tar out; echo "exit status $?"'
  run 'find . -type f | sort'
} > "$out/s7-untar.txt" 2>&1
cd "$proj" && rm -rf evil
cap s7-attacks.txt "go test -v -run 'TestExtractTar(RejectsEscapes|RefusesPlantedSymlink)' ./fsx 2>&1 \\
    | grep -E 'extract_test|^(--- |ok)'"

broken 7; edit fsx/extract.go 's/if err := root.MkdirAll\(path.Dir\(hdr.Name\), 0o755\); err != nil \{/if err := os.MkdirAll(filepath.Join(root.Name(), path.Dir(hdr.Name)), 0o755); err != nil {/'
edit fsx/extract.go 's/f, err := root.OpenFile\(hdr.Name, /f, err := os.OpenFile(filepath.Join(root.Name(), hdr.Name), /'
cap s7-join.txt 'go test ./fsx'
key s7-join.txt '--- FAIL: TestExtractTarRejectsEscapes/|extraction succeeded' 2
broken 7; edit fsx/extract.go 's/os.O_WRONLY\|os.O_CREATE\|os.O_EXCL/os.O_WRONLY|os.O_CREATE|os.O_TRUNC/'
cap s7-excl.txt 'go test ./fsx'; key s7-excl.txt '--- FAIL: TestExtractTarRejectsEscapes/|extraction succeeded' 2
broken 7; edit fsx/extract.go 's/\t\ttarget := path.Join.*?\n\t\tif path.IsAbs.*?\n\t\t\}\n//s'
edit fsx/extract.go 's/\t"path\/filepath"\n//'
cap s7-symlink.txt 'go test ./fsx'; key s7-symlink.txt '--- FAIL: TestExtractTarRejectsEscapes/|extraction succeeded' 2
broken 7; edit fsx/extract.go 's/\t\tif err == nil && \*budget < 0 \{\n\t\t\terr = ErrArchiveTooLarge\n\t\t\}\n//'
cap s7-budget.txt 'go test ./fsx'; key s7-budget.txt 'byte limit'

fi

if want 8; then
echo "== step 8: /proc and zombies"
use_step 8
lstree 8 cmd fsx sysinfo
cap s8-test.txt 'go vet ./... && go test ./...'
cap s8-build.txt 'go build -o bin/ ./cmd/...'
cap s8-image.txt 'CGO_ENABLED=0 GOOS=linux go build -o linux/ ./cmd/... && docker build -q -f scratch.Dockerfile -t oskit linux'
cap s8-zombies.txt 'docker run --rm oskit /zombies'
cap s8-init.txt 'docker run --rm --init oskit /zombies'
cap s8-testc.txt 'CGO_ENABLED=0 GOOS=linux go test -c -o linux/ ./sysinfo && docker build -q -f scratch.Dockerfile -t oskit linux'
cap s8-linuxtest.txt "docker run --rm oskit /sysinfo.test -test.v | grep -E '^(---|PASS|FAIL)'"

broken 8; edit sysinfo/proc.go 's/bytes.LastIndexByte\(b, .\).\)/bytes.IndexByte(b, \x27)\x27)/'
cap s8-paren.txt 'go test ./sysinfo'; key s8-paren.txt 'stat field' 1
cd "$proj"; cap s8-mac.txt 'bin/zombies'; key s8-mac.txt '.' 3
broken 8; edit sysinfo/proc.go 's/ \/\/nolint:gosec \/\/ never negative//'
cap s8-gosec.txt 'golangci-lint run ./...'; key s8-gosec.txt 'G115'

fi

if want 9; then
echo "== lab 9: orphans"
use_step 9
lstree 9 cmd fsx sysinfo
cap s9-test.txt 'go vet ./... && go test ./...'
image
cap s9-orphans.txt 'docker run --rm --init oskit /orphans'

cap s9-noshell.txt "docker run --rm oskit /bin/sh -c 'sleep 1'"; key s9-noshell.txt 'no such file'
broken 9; edit cmd/orphans/main.go 's/exec.CommandContext\(ctx, self, "-role=worker"\)/exec.CommandContext(ctx, "orphans", "-role=worker")/'
image oskit-broken
cap s9-path.txt 'docker run --rm --init oskit-broken /orphans'; key s9-path.txt 'executable file not found'
broken 9; edit cmd/orphans/main.go 's/ \/\/nolint:gosec,noctx \/\/ demo//'
cap s9-lint.txt 'golangci-lint run ./...'; key s9-lint.txt '\(noctx\)' 1

fi

if want 10; then
echo "== step 10: process groups"
use_step 10
lstree 10 cmd fsx procx sysinfo
cap s10-test.txt 'go vet ./... && go test ./...'
cap s10-procx.txt "go test -v ./procx 2>&1 | grep -E '^(--- |ok)'"
image
cap s10-orphans.txt 'docker run --rm --init oskit /orphans -kill group'

broken 10; edit procx/procx.go 's/\tsetGroup\(c.Cmd\) \/\/ Setpgid: the child leads a new process group\n//'
cap s10-nopgid.txt 'go test ./procx'; key s10-nopgid.txt '^--- FAIL: TestCancelKillsTheWholeGroup|still running' 3
broken 10; edit procx/procx.go 's/\t\treturn signalGroup\(c.Process, syscall.SIGTERM\)\n/\t\treturn c.Process.Kill()\n/'
cap s10-kill.txt 'go test -run TestCancelKillsTheWholeGroup ./procx'; key s10-kill.txt 'exit code|still running' 1
broken 10; edit procx/procx.go 's/\tif c.Process != nil \{\n\t\t_ = signalGroup\(c.Process, syscall.SIGKILL\).*?\n\t\}\n//'
cap s10-nowaitkill.txt 'go test -run TestWaitKillsAbandonedDescendants ./procx'; key s10-nowaitkill.txt 'still running'

fi

if want 11; then
echo "== lab 11: terminals"
use_step 11
deps 11 github.com/creack/pty@v1.1.24
lstree 11 cmd fsx procx sysinfo
cap s11-test.txt 'go vet ./... && go test ./...'
cap s11-build.txt 'go build -o bin/ ./cmd/...'
cap s11-mac.txt 'bin/ttydemo'
image
cap s11-docker.txt 'docker run --rm oskit /ttydemo'

broken 11; cp "$wb/step10/go.mod" go.mod; cp "$wb/step10/go.sum" go.sum
cap s11-nopty.txt 'go build ./...'; key s11-nopty.txt 'no required module'
broken 11; edit cmd/ttydemo/main.go 's/if err != nil && !errors.Is\(err, syscall.EIO\) \{/if err != nil {/'
edit cmd/ttydemo/main.go 's/\t"errors"\n//'
edit cmd/ttydemo/main.go 's/\t"syscall"\n//'
image oskit-broken
cap s11-eio.txt 'docker run --rm oskit-broken /ttydemo'; key s11-eio.txt 'input/output error'
broken 11; edit cmd/ttydemo/main.go 's/\tptmx, err := pty.StartWithSize/\tcmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}\n\tptmx, err := pty.StartWithSize/'
image oskit-broken
cap s11-setpgid.txt 'docker run --rm oskit-broken /ttydemo'; key s11-setpgid.txt 'not permitted'

fi

if want 12; then
echo "== lab 12: signals"
use_step 12
lstree 12 cmd fsx procx sysinfo
cap s12-test.txt 'go vet ./... && go test ./...'
cap s12-build.txt 'go build -o bin/ ./cmd/...'
{
  run 'bin/sigpipe | head -n 3; echo "exit status ${PIPESTATUS[0]}"'
  run 'bin/sigpipe -notify | head -n 3; echo "exit status ${PIPESTATUS[0]}"'
  run 'bin/sigpipe -notify -check | head -n 3; echo "exit status ${PIPESTATUS[0]}"'
} > "$out/s12-sigpipe.raw" 2>&1
scrub < "$out/s12-sigpipe.raw" > "$out/s12-sigpipe.txt"; rm "$out/s12-sigpipe.raw"
{
  run "echo '{\"version\":1,\"workers\":4}' | bin/atomicput app.json"
  run 'bin/reload -config app.json &'
  for _ in $(seq 100); do grep -q serving "$out/s12-reload.raw" && break; sleep 0.1; done
  run "echo '{\"version\":2,\"workers\":8}' | bin/atomicput app.json"
  run 'kill -HUP $!'
  sleep 0.5
  run "echo '{\"version\":3,\"workers\":0}' | bin/atomicput app.json"
  run 'kill -HUP $!'
  sleep 0.5
  run 'kill -TERM $!; wait $!'
} > "$out/s12-reload.raw" 2>&1
scrub < "$out/s12-reload.raw" > "$out/s12-reload.txt"; rm "$out/s12-reload.raw"

{
  run 'bin/torn -for 5s & sleep 0.5; kill -HUP $!; wait $!; echo "exit status $?"'
} > "$out/s12-hup.raw" 2>&1
scrub < "$out/s12-hup.raw" > "$out/s12-hup.txt"; rm "$out/s12-hup.raw"
key s12-hup.txt '^Hangup|^exit status' 2
broken 12; edit cmd/reload/main.go 's/hup := make\(chan os.Signal, 1\)/hup := make(chan os.Signal)/'
cap s12-unbuffered.txt 'go vet ./...'; key s12-unbuffered.txt 'misuse'
cd "$proj"
cap s12-badstart.txt "echo '{\"version\":1,\"workers\":0}' | bin/atomicput bad.json; bin/reload -config bad.json; echo \"exit status \$?\""
key s12-badstart.txt 'workers|exit status' 2

fi

if want 13; then
echo "== step 13: container limits"
use_step 13
lstree 13 cmd fsx procx sysinfo
cap s13-test.txt 'go vet ./... && go test ./...'
cap s13-build.txt 'go build -o bin/ ./cmd/...'
cap s13-mac.txt 'bin/limits'
image
cap s13-none.txt 'docker run --rm oskit /limits'
cap s13-set.txt 'docker run --rm --cpus=1.5 --memory=256m --pids-limit=100 --ulimit nofile=1024:4096 \
    oskit /limits'
cap s13-memlimit.txt "docker run --rm --cpus=1.5 --memory=256m oskit /limits -set-memlimit \\
    | grep -E '^(memory.max|GOMAXPROCS|GOMEMLIMIT)'"
cap s13-fds.txt 'docker run --rm --ulimit nofile=256:256 oskit /limits -exhaust-fds'
cap s13-testc.txt 'CGO_ENABLED=0 GOOS=linux go test -c -o linux/ ./fsx ./procx ./sysinfo'
cap s13-image2.txt 'docker build -q -f scratch.Dockerfile -t oskit linux'
cap s13-linuxtests.txt "for p in fsx procx sysinfo; do printf '%-8s ' \$p; \\
    docker run --rm --init --tmpfs /tmp:rw,mode=1777 oskit /\$p.test | tail -1; done"
cap s13-race.txt 'go test -race ./...'

cap s13-soft.txt 'docker run --rm --ulimit nofile=64:4096 oskit /limits -exhaust-fds'; key s13-soft.txt 'RLIMIT_NOFILE'
cap s13-notmp.txt 'docker run --rm --init oskit /fsx.test -test.run TestWriteFileCreatesAndReplaces'
key s13-notmp.txt 'TempDir|no such file' 1
broken 13; edit sysinfo/cgroup.go 's/\t\tif d == cgroupRoot \{/\t\tif d == dir {/'
cap s13-nowalk.txt 'go test ./sysinfo'; key s13-nowalk.txt 'got ' 1

fi

docker rmi oskit-broken > /dev/null 2>&1 || true
echo "captured into $out"
