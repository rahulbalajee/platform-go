#!/usr/bin/env bash
# Regenerates the real terminal output shown in Chapter 5.
# Usage: book/scripts/capture-ch05.sh [section...]   (from the repository root)
# Sections: logs files locks processes signals limits tests (default: all).
#
# Host runs use binaries built for this machine. Linux runs cross-compile
# the examples (CGO_ENABLED=0 GOOS=linux) into a FROM scratch image, so no
# base image is pulled, and run them with `docker run`.
# Needs: go, docker, ~2.5 GB of free disk for the generated access log.
set -euo pipefail
root=$(pwd)
out=$root/book/output/ch05
mkdir -p "$out"
work=$(mktemp -d "${TMPDIR:-/tmp}/ch05.XXXXXX")
trap 'rm -rf "$work"' EXIT
bin=$work/bin
mkdir -p "$bin" "$work/image/bin" "$work/test/bin"
export PATH="$bin:$PATH"
goarch=$(go env GOARCH)

# scrub: hide machine-specific paths and the host name.
scrub() {
  sed -e "s#${root}/##g" -e "s#${work}#/tmp/ch05#g" \
      -e "s#host=$(hostname)#host=devbox#g" \
      -E -e 's#^.*line [0-9]+: +[0-9]+ (Killed.*)$#\1#'
}
only=" ${*:-all} "
want() { [[ $only == *" all "* || $only == *" $1 "* ]]; }

# run: echo a command the way a shell prompt would, then run it. Failures
# are part of what the chapter shows, so they do not stop the script.
run() { printf '$ %s\n' "$1"; set +e; eval "$1"; set -e; }

echo "building"
for p in loggen logscan torn lockdemo untar sigpipe reload atomicput limits ttydemo; do
  go build -o "$bin/$p" "./examples/ch05/$p"
done
for p in limits logscan orphans zombies ttydemo; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" go build -o "$work/image/bin/$p" "./examples/ch05/$p"
done
docker build -q -f examples/ch05/scratch.Dockerfile -t pgo-ch05 "$work/image" > /dev/null

# --- Streaming I/O -------------------------------------------------------------
if want logs; then
echo "logs"
data=$work/data
mkdir -p "$data"
( cd "$data"
  run 'loggen -lines 30000000 -long-at 1000000 > access.log'
  run 'wc -lc access.log'
) > "$out/loggen.txt" 2>&1
( cd "$data"; logscan access.log ) > "$out/logscan-stream.txt"
( cd "$data"; run 'logscan -mode scanner access.log; echo "exit=$?"' ) > "$out/logscan-scanner.txt"
( cd "$data"; logscan -mode readall access.log ) > "$out/logscan-readall.txt"
( cd "$data"
  run 'docker run --rm --memory=64m -v $PWD:/data:ro pgo-ch05 /logscan /data/access.log'
) > "$out/logscan-docker.txt" 2>&1
( cd "$data"
  docker rm -f ch05-readall > /dev/null 2>&1 || true
  run 'docker run --name ch05-readall --memory=1g -v $PWD:/data:ro pgo-ch05 \
    /logscan -mode readall /data/access.log; echo "exit=$?"'
  run "docker inspect -f 'OOMKilled={{.State.OOMKilled}}' ch05-readall"
  docker rm ch05-readall > /dev/null
  run 'docker run --rm --memory=1g -e GOMEMLIMIT=900MiB -v $PWD:/data:ro pgo-ch05 \
    /logscan -mode readall /data/access.log; echo "exit=$?"'
) > "$out/logscan-oom.txt" 2>&1
rm -rf "$data"
# Benchmarks: five runs, reported as the median of each, because a shared
# laptop is noisy.
go test -run '^$' -bench . -benchtime 20x -count 5 ./examples/ch05/copybuf 2>&1 \
  | python3 -c '
import re, statistics, sys
runs, order = {}, []
for line in sys.stdin:
    if line.startswith("cpu:"):
        print(line.strip())
    m = re.match(r"BenchmarkCopy/(\S+?)-\d+\s+\d+\s+\d+ ns/op\s+([\d.]+) MB/s"
                 r"\s+([\d.]+) B/write", line)
    if m:
        name = m.group(1)
        if name not in runs:
            order.append(name)
        runs.setdefault(name, []).append((float(m.group(2)), int(float(m.group(3)))))
print("%-22s %8s %15s" % ("benchmark", "MB/s", "largest write"))
for name in order:
    mbs = statistics.median(r[0] for r in runs[name])
    print("%-22s %8.0f %13d B" % (name, mbs, runs[name][0][1]))
' > "$out/copybuf.txt"
go test -count=1 -v -run 'TestScannerBugIsSilent|TestScanFS' ./examples/ch05/logscan 2>&1 \
  | grep -E '^(=== RUN|--- |ok|PASS|FAIL)' | scrub > "$out/logscan-test.txt"

fi

# --- Filesystems ----------------------------------------------------------------
if want files; then
echo "files"
mkdir -p "$work/untar" && ( cd "$work/untar"
  run 'untar -make-evil evil.tar'
  run 'untar -naive evil.tar out'
  run 'find . -type f | sort'
  rm -rf out escaped.txt via-symlink.txt
  run 'untar evil.tar out; echo "exit=$?"'
  run 'find . -type f | sort'
) > "$out/untar.txt" 2>&1
go test -count=1 -v -run 'TestExtractTar(RejectsEscapes|RefusesPlantedSymlink)' ./pkg/fsx 2>&1 \
  | grep -E '(extract_test|^--- |^ok)' | grep -v '^    ---' \
  | sed -E 's/^ +extract_test.go:[0-9]+: /    /' | scrub > "$out/extract-test.txt"
torn -mode naive > "$out/torn-naive.txt"
torn -mode atomic > "$out/torn-atomic.txt"

fi

# --- Locks ----------------------------------------------------------------------
if want locks; then
echo "locks"
rm -f /tmp/lockdemo.lock /tmp/lockdemo.pid
{
  run 'lockdemo -name A -hold 3s &'
  sleep 1
  run 'lockdemo -name B; echo "exit=$?"'
  run 'lockdemo -name C -wait 5s'
  run 'lockdemo -name D -hold 60s & sleep 1; kill -9 $!'
  sleep 0.5
  run 'lockdemo -name E -hold 0s'
} > "$out/lock-flock.txt" 2>&1
scrub < "$out/lock-flock.txt" > "$out/lock-flock.tmp" && mv "$out/lock-flock.tmp" "$out/lock-flock.txt"
{
  run 'lockdemo -pidfile -lock /tmp/lockdemo.pid -name F -hold 60s & sleep 1; kill -9 $!'
  sleep 0.5
  run 'lockdemo -pidfile -lock /tmp/lockdemo.pid -name G; echo "exit=$?"'
} > "$out/lock-pidfile.txt" 2>&1
scrub < "$out/lock-pidfile.txt" > "$out/lock-pidfile.tmp" && mv "$out/lock-pidfile.tmp" "$out/lock-pidfile.txt"
rm -f /tmp/lockdemo.lock /tmp/lockdemo.pid

fi

# --- Processes ------------------------------------------------------------------
if want processes; then
echo "processes"
docker run --rm --init pgo-ch05 /orphans -kill exec > "$out/orphans-exec.txt"
docker run --rm --init pgo-ch05 /orphans -kill group > "$out/orphans-group.txt"
go test -count=1 -v ./pkg/procx 2>&1 | grep -E '^(--- |ok|FAIL)' | scrub > "$out/procx-test.txt"
docker run --rm pgo-ch05 /ttydemo > "$out/ttydemo.txt"

fi

# --- Signals --------------------------------------------------------------------
if want signals; then
echo "signals"
{
  run 'sigpipe | head -n 3; echo "exit=${PIPESTATUS[0]}"'
  run 'sigpipe -notify | head -n 3; echo "exit=${PIPESTATUS[0]}"'
  run 'sigpipe -notify -check | head -n 3; echo "exit=${PIPESTATUS[0]}"'
} > "$out/sigpipe.txt" 2>&1
mkdir -p "$work/reload" && ( cd "$work/reload"
  run "echo '{\"version\":1,\"workers\":4}' | atomicput app.json"
  run 'reload -config app.json &'
  for _ in $(seq 100); do grep -q serving "$out/reload.txt" && break; sleep 0.1; done
  run "echo '{\"version\":2,\"workers\":8}' | atomicput app.json"
  run 'kill -HUP %1'
  sleep 0.5
  run "echo '{\"version\":3,\"workers\":0}' | atomicput app.json"
  run 'kill -HUP %1'
  sleep 0.5
  run 'kill -TERM %1; wait'
) > "$out/reload.txt" 2>&1
docker run --rm pgo-ch05 /zombies > "$out/zombies.txt"
docker run --rm --init pgo-ch05 /zombies > "$out/zombies-init.txt"

fi

# --- Linux introspection --------------------------------------------------------
if want limits; then
echo "limits"
docker run --rm pgo-ch05 /limits > "$out/limits-none.txt"
docker run --rm --cpus=1.5 --memory=256m --pids-limit=100 --ulimit nofile=1024:4096 \
  pgo-ch05 /limits > "$out/limits-set.txt"
docker run --rm --cpus=1.5 --memory=256m pgo-ch05 /limits -set-memlimit \
  | grep -E '^(memory.max|GOMAXPROCS|GOMEMLIMIT)' > "$out/limits-memlimit.txt"
docker run --rm --ulimit nofile=256:256 pgo-ch05 /limits -exhaust-fds > "$out/limits-fds.txt"
limits > "$out/limits-darwin.txt"

fi

# --- Tests ----------------------------------------------------------------------
if want tests; then
echo "tests"
for p in fsx procx sysinfo; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" go test -c -o "$work/test/bin/$p.test" "./pkg/$p"
done
docker build -q -f examples/ch05/scratch.Dockerfile -t pgo-ch05-test "$work/test" > /dev/null
for p in fsx procx sysinfo; do
  printf '%-8s ' "$p"
  docker run --rm --init --tmpfs /tmp:rw,mode=1777 pgo-ch05-test "/$p.test" -test.count=1 2>&1 | tail -1
done > "$out/linux-tests.txt"
go test -race -count=1 ./pkg/fsx ./pkg/procx ./pkg/sysinfo ./examples/ch05/logscan 2>&1 \
  | scrub > "$out/test-race.txt"
fi
echo "captured into $out"
