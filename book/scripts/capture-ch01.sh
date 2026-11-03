#!/usr/bin/env bash
# Regenerates every terminal block in Chapter 1 (book/output/ch01): the ten
# labs and their checkpoints, the troubleshooting tables (each made by
# breaking a copy of what the reader has at that point), and the exercise
# answers.
#
# Usage, from the repository root (bash reads a script while it runs it, so
# run a copy if you might edit this file meanwhile):
#   cp book/scripts/capture-ch01.sh "$TMPDIR/c1.sh" && bash "$TMPDIR/c1.sh"
#
# Needs network access (module proxy, checksum database, vulnerability
# database, example.com), git, curl, golangci-lint v2.15.0 and shasum, and an
# older Go (GO_OLD, default /usr/local/go/bin, go1.26.4 on the book's
# machine) for Lab 1, which plays the reader's "$HOME/sdk/go1.26.4/bin".
# About five minutes.
#
# The reader's lab directory is $LAB, a scratch directory deleted on exit;
# every clone, workspace and module cache the labs create lives there. The
# labs clone the repository's HEAD, so commit before capturing: outputs embed
# commit hashes and module counts.
set -euo pipefail
unset GOFLAGS GOPROXY GOMODCACHE GONOSUMDB GOTOOLCHAIN GOWORK GOPRIVATE GONOPROXY
root=$(pwd)
out=$root/book/output/ch01
wb=$root/workbook/ch01
GO_OLD=${GO_OLD:-/usr/local/go/bin}
[[ -x $GO_OLD/go ]] || { echo "need an older go in GO_OLD ($GO_OLD)"; exit 1; }
rm -rf "$out"; mkdir -p "$out/ts"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/ch01.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
export LAB
cleanup() {
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
export PATH="$PATH:$HOME/go/bin" # golangci-lint
goroot=$(go env GOROOT)

# Commits in the reader's stamp repository get fixed names and dates, so
# their hashes (and the pseudo-versions built from them) are stable.
export GIT_CONFIG_GLOBAL=$LAB/.gitconfig GIT_CONFIG_NOSYSTEM=1
git config --global user.name "Lab Reader"
git config --global user.email reader@example.com
git config --global init.defaultBranch main
commit_at() { export GIT_AUTHOR_DATE=$1 GIT_COMMITTER_DATE=$1; }

# Paths change on every run; nothing else is edited.
scrub() {
  sed -E -e "s#${LAB}#\$LAB#g" -e "s#${root}/##g" -e "s#${root}#.#g" -e "s#${HOME}#~#g" \
    -e 's#^[^ ]*(bash|\.sh): line [0-9]+: #bash: #'
}
# cap FILE CMD: run CMD (a shell string, exactly as printed in the book) in
# the current directory and save its scrubbed stdout and stderr. A failing
# command is expected, not fatal: many captures are error messages.
cap() {
  local f=$1; shift
  set +e; ( eval "$*" ) > "$out/$f.raw" 2>&1; set -e
  scrub < "$out/$f.raw" > "$out/$f"; rm -f "$out/$f.raw"
}
# key FILE PATTERN [N]: the first N (default 1) lines of a capture matching
# PATTERN, quoted in a troubleshooting table.
key() {
  grep -E -m "${3:-1}" -e "$2" "$out/$1" > "$out/ts/$1" ||
    { echo "no match for '$2' in $1"; exit 1; }
}
# edit FILE PERL: apply a perl substitution and insist that it changed FILE.
edit() {
  local before; before=$(cksum < "$1")
  perl -0pi -e "$2" "$1"
  [[ $(cksum < "$1") != "$before" ]] || { echo "edit did not apply to $1: $2"; exit 1; }
}
# reader_copy K DIR: put snapshot K's source files into DIR the way a reader
# typed them from the book: without OMIT marker lines, without go.mod and
# go.sum (the reader's commands make those) and without generated files.
reader_copy() {
  local k=$1 dir=$2 f
  mkdir -p "$dir"
  (cd "$wb/step$k" && find . -type f ! -name go.mod ! -name go.sum ! -name '*_string.go' |
    tar cf - -T -) | (cd "$dir" && tar xf -)
  while IFS= read -r f; do
    perl -0pi -e 's/^[^\n]*OMIT[^\n]*\n//mg; s/\n{3,}/\n\n/g; s/\A\n+//; s/\n+\z/\n/' "$f"
  done < <(grep -rl --include='*.go' OMIT "$dir" || true)
  [[ -z $("$goroot/bin/gofmt" -l "$dir") ]] || { echo "reader copy of step$k is not gofmt-clean"; exit 1; }
}
# same_mod K: the reader's go.mod (current directory) must equal snapshot K's.
same_mod() {
  cmp -s go.mod "$wb/step$1/go.mod" || { echo "go.mod differs from step$1"; diff go.mod "$wb/step$1/go.mod"; exit 1; }
}
# broken DIR: a scratch copy of the reader's module DIR (without .git and
# binaries), plus the lint configuration, to break on purpose.
broken() {
  rm -rf "$LAB/broken"; mkdir -p "$LAB/broken"
  cp -R "$1/." "$LAB/broken/"
  rm -rf "$LAB/broken/.git" "$LAB/broken/stamp" # the repository and the binary
  cp "$root/.golangci.yml" "$LAB/broken/"
  cd "$LAB/broken"
}

clone=$LAB/platform-go
git clone -q "$root" "$clone"

echo "== lab 1: which Go runs (the reader's PATH starts with go1.26.4)"
(
  export PATH="$GO_OLD:$PATH"
  cd "$LAB"
  cap tc-outside.txt 'go version'
  cd "$clone"
  cap tc-version.txt 'go version'
  cap tc-local.txt 'GOTOOLCHAIN=local go version'
  cap tc-env.txt 'go env GOTOOLCHAIN GOVERSION GOROOT'
  cap tc-trace.txt 'GODEBUG=toolchaintrace=1 go version 2>&1 | fold -s -w 88'
  cap tc-local-build.txt 'GOTOOLCHAIN=local go build ./...'
  key tc-local-build.txt 'requires go'
  cap tc-path.txt 'GOTOOLCHAIN=path go version'
  key tc-path.txt 'cannot find'
  mkdir "$LAB/svc" && cd "$LAB/svc"
  cap tc-init.txt 'go mod init example.com/svc'
  cap tc-gomod1.txt 'cat go.mod'
  cap tc-get.txt 'go get go@1.27.0 toolchain@go1.27.3'
  cap tc-gomod2.txt 'cat go.mod'
  cp go.mod "$LAB/svc.keep"
  edit go.mod 's/^toolchain go1\.27\.3$/toolchain 1.27.3/m'
  cap l1-invalid.txt 'go version'; key l1-invalid.txt 'invalid toolchain'
  cp "$LAB/svc.keep" go.mod
  # go1.27.1 is not in the module cache, so it would have to be downloaded.
  edit go.mod 's/^toolchain go1\.27\.3$/toolchain go1.27.1/m'
  cap l1-proxy.txt 'GOPROXY=off go version'; key l1-proxy.txt 'download' 2
  cap l1-sumdb.txt 'GOSUMDB=off go version'; key l1-sumdb.txt 'download' 2
  cp "$LAB/svc.keep" go.mod
  cap tc-none.txt 'go get toolchain@none'
  cap tc-none-version.txt 'go version'
  cap l1-cp-gomod.txt 'cat go.mod'
  cap l1-cp-lab.txt 'cd "$LAB" && go version'
  cap l1-cp-svc.txt 'cd "$LAB/svc" && go version'
  cap l1-cp-repo.txt 'cd "$LAB/platform-go" && go version'
)

echo "== lab 2: minimal version selection"
(
  cd "$clone"
  cap mod-graph.txt 'go mod graph'
  cap mod-go-graph.txt "go mod graph | grep ' go@'"
  cap mod-go-list.txt 'go list -m go'
  cd projects/watchtower
  cap mod-xnet.txt "go mod graph | awk '\$2 ~ /^golang.org\\/x\\/net@/ {print \$2}' | sort -V | uniq -c"
  cap mod-xnet-list.txt 'go list -m golang.org/x/net'
)
mvs=$LAB/mvs/app
(
  cd "$clone"
  go run ./examples/ch01/mkproxy -o "$LAB/mvs" examples/ch01/mkproxy/universe.txtar
  cd "$mvs"
  # A terminal without the lab's exports: the go command asks the internet.
  cap l2-noproxy.txt 'GOMODCACHE="$LAB/modcache-noproxy" go mod tidy'
  key l2-noproxy.txt 'unrecognized import path' 1
  export GOPROXY="file://$LAB/mvs/proxy" GONOSUMDB=example.com
  export GOMODCACHE="$LAB/modcache" GOFLAGS=-modcacherw
  cap l2-gosum.txt 'go run .'; key l2-gosum.txt 'missing go.sum entry' 1
  cap mvs-tidy.txt 'go mod tidy'
  cap mvs-list.txt 'go list -m all'
  cap mvs-run.txt 'go run .'
  cap mvs-graph.txt 'go mod graph'
  cap mvs-proxy.txt 'ls -C "$LAB/mvs/proxy/example.com/codec/@v"'
  cap mvs-why.txt 'go mod why -m example.com/codec'
  cp go.mod go.mod.orig && cp go.sum go.sum.orig
  reset() { cp go.mod.orig go.mod && cp go.sum.orig go.sum; }
  cap mvs-u.txt 'go list -m -u all'
  cap mvs-get.txt 'go get example.com/metrics@v1.3.0'
  cap mvs-run2.txt 'go run .'
  cap l2-cp-gomod.txt 'cat go.mod'
  cap l2-cp-graph.txt 'go mod graph'
  (cd .. && cap l2-nomod.txt 'go mod tidy'); key l2-nomod.txt 'go.mod file not found'

  echo "== lab 3: retract, exclude, replace"
  cap mvs-retract-mod.txt 'cat "$LAB/mvs/proxy/example.com/codec/@v/v1.5.1.mod"'
  cap mvs-u2.txt 'go list -m -u all'
  cap mvs-versions.txt 'go list -m -versions example.com/codec'
  cap mvs-retracted.txt 'go list -m -retracted -versions example.com/codec'
  cap mvs-latest.txt 'go get example.com/codec@latest'
  cap l3-retracted.txt 'go get example.com/codec@v1.5.0'; key l3-retracted.txt 'retracted by' 1
  reset
  cap mvs-exclude.txt 'go mod edit -exclude example.com/codec@v1.4.0'
  cap l3-notidy.txt 'go run .'; key l3-notidy.txt 'updates to go.mod needed' 1
  cap mvs-exclude-tidy.txt 'go mod tidy'
  cap mvs-exclude-run.txt 'go run .'
  reset
  cap mvs-replace.txt 'go mod edit -replace example.com/codec=../fork/codec'
  cap mvs-replace-list.txt 'go list -m example.com/codec'
  cap mvs-replace-run.txt 'go run .'
  cap l3-cp-tail.txt 'tail -2 go.mod'
  cap l3-cp-list.txt 'go list -m all'
  reset
  go mod edit -replace example.com/codec=../fork/codex
  cap l3-typo.txt 'go run .'; key l3-typo.txt 'does not exist' 1
  reset

  echo "== lab 4: go.sum, the checksum database, proxies"
  cap mvs-sum.txt 'cat go.sum'
  cap l4-verify.txt 'go mod verify'
  edit go.sum 's/^example\.com\/codec v1\.4\.0 h1:\S+/example.com\/codec v1.4.0 h1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=/m'
  cap l4-mismatch.txt 'go run .'; key l4-mismatch.txt 'checksum mismatch|SECURITY ERROR' 2
  reset
  chmod u+w "$LAB/modcache/example.com/codec@v1.4.0/codec.go"
  echo '// patched in place' >> "$LAB/modcache/example.com/codec@v1.4.0/codec.go"
  cap l4-tamper.txt 'go mod verify'; key l4-tamper.txt 'has been modified' 1
  cap l4-fix.txt 'rm -rf "$LAB/modcache/example.com/codec@v1.4.0" && go mod verify'
  cap l4-fix-run.txt 'go run .'
  rm go.sum
  cap l4-nosum.txt 'go build .'; key l4-nosum.txt 'missing go.sum entry' 1
  reset
  # The checksum database knows nothing about example.com/codec.
  cap l4-sumdb.txt 'GONOSUMDB= GOMODCACHE="$LAB/modcache-sumdb" go mod download example.com/codec@v1.3.0'
  key l4-sumdb.txt '404' 2
)
(
  cd "$clone"
  cap l4-cp-env.txt 'go env GOPROXY GONOSUMDB GOMODCACHE GOFLAGS'
  cap trust-sum.txt 'grep golang.org/x/sync go.sum'
  cap trust-verify.txt 'go mod verify'
  cap trust-sumdb.txt 'curl -s https://sum.golang.org/lookup/golang.org/x/sync@v0.24.0 | cut -c1-80'
  cap trust-private.txt "GOPRIVATE='github.com/acme/*' go env GOPRIVATE GONOPROXY GONOSUMDB"
  cd projects/watchtower
  cap vendor.txt 'go mod vendor && du -sh vendor && find vendor -name "*.go" | wc -l'
  rm -rf vendor
)

echo "== lab 5: a code generator pinned with the tool directive"
tools=$LAB/tools
(
  mkdir -p "$tools" && cd "$tools"
  cap l5-init.txt 'go mod init tools'
  cap l5-goget.txt 'go get go@1.27.0 toolchain@go1.27.3'
  cap tools-get.txt 'go get -tool golang.org/x/tools/cmd/stringer@v0.52.0'
  cap l5-gomod.txt 'cat go.mod'
  same_mod 1
  cmp -s go.sum "$wb/step1/go.sum" || { echo "go.sum differs from step1"; exit 1; }
  reader_copy 1 "$tools"
  cap l5-nogen.txt 'go build ./...'; key l5-nogen.txt 'String undefined' 1
  cap tools-list.txt "go tool | grep -F '('"
  cap tools-generate.txt 'go generate -x ./...'
  cmp -s rollout/phase_string.go "$wb/step1/rollout/phase_string.go" ||
    { echo "generated phase_string.go differs from step1"; exit 1; }
  cap tools-phase-string.txt "sed -n '/^func _/,/^}/p' rollout/phase_string.go"
  cap l5-tree.txt "find . -name '*.go' | sort"
  cap tools-test.txt 'go vet ./... && go test ./...'

  broken "$tools"; go mod edit -droptool golang.org/x/tools/cmd/stringer
  cap l5-notool.txt 'go generate ./...'; key l5-notool.txt 'no such tool|running' 2
  broken "$tools"; edit rollout/phase.go 's/(\tPhaseCanary +\/\/ canary\n)/$1\tPhaseVerifying \/\/ verifying\n/'
  "$goroot/bin/gofmt" -w rollout/phase.go
  cap l5-stale.txt 'go build ./...'; key l5-stale.txt 'invalid argument' 1
  broken "$tools"; edit rollout/phase.go 's/ -linecomment//'
  go generate ./...
  cap l5-linecomment.txt 'go test ./...'; key l5-linecomment.txt 'String\(\) =' 1
  # Labs 2-4 exported GOPROXY in this terminal; a fresh module shows it.
  rm -rf "$LAB/stale" && mkdir "$LAB/stale" && cd "$LAB/stale"
  printf 'module tools\n\ngo 1.27.0\n' > go.mod
  cap l5-goproxy.txt 'GOPROXY="file://$LAB/mvs/proxy" GOMODCACHE="$LAB/modcache" \
    go get -tool golang.org/x/tools/cmd/stringer@v0.52.0'
  key l5-goproxy.txt 'no such file' 1
)
(
  cd "$clone/projects/watchtower"
  cap tools-wt-get.txt 'go get -tool golang.org/x/vuln/cmd/govulncheck@v1.9.0'
  git checkout -q -- go.mod go.sum
  cd "$clone"
  cap tools-modfile.txt 'go tool -modfile=examples/ch01/tools/go.mod govulncheck -version'
  # Size of golangci-lint's build list, quoted in the text.
  mkdir -p "$LAB/gcl" && cd "$LAB/gcl"
  go mod init example.com/gcl >/dev/null 2>&1
  go get -tool github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 >/dev/null 2>&1
  cap gcl-count.txt 'go list -m all | wc -l'
)

echo "== lab 6: workspaces and repository layout"
(
  cd "$clone"
  cap ws-init.txt 'go work init . ./projects/watchtower'
  cap ws-cat.txt 'cat go.work'
  cap ws-list.txt 'go list -m'
  cap ws-env.txt 'go env GOWORK'
  cap l6-nodir.txt 'go work use ./project/watchtower'; key l6-nodir.txt 'does not exist' 1
  cd projects/watchtower
  cap ws-versions.txt 'go list -m golang.org/x/sync golang.org/x/sys golang.org/x/time'
  cap ws-versions-off.txt 'GOWORK=off go list -m golang.org/x/sync golang.org/x/sys golang.org/x/time'
  cap l6-modmod.txt 'GOFLAGS=-mod=mod go build ./...'; key l6-modmod.txt '-mod may only|Remove|GOWORK' 3
  mkdir -p hack/internaldemo
  cp "$root/examples/ch01/internaldemo/main.go.txt" hack/internaldemo/main.go
  cap internal-ws.txt 'go build -o /dev/null ./hack/internaldemo && echo ok'
  cap internal-off.txt 'GOWORK=off go build -o /dev/null ./hack/internaldemo'
  key internal-off.txt 'no required module' 1
  rm -rf hack/internaldemo
  mkdir -p "$LAB/ext" && cd "$LAB/ext"
  cap l6-ext-init.txt 'go mod init example.com/ext'
  cp "$root/examples/ch01/internaldemo/main.go.txt" main.go
  cap l6-ext-work.txt 'go work init . ../platform-go'
  cap internal-ext.txt 'go build -o /dev/null .'; key internal-ext.txt 'not allowed' 1
  rm -f go.work go.work.sum
  cd "$clone"
  rm -f go.work go.work.sum
  cap l6-cp-list.txt 'go list -m'
  cap l6-cp-status.txt 'git status --short | wc -l'
  cap mod-count-root.txt 'go list -m all | wc -l'
  cap mod-count-wt.txt 'cd projects/watchtower && go list -m all | wc -l'
)

echo "== lab 7: release builds and what they record"
(
  cd "$clone"
  TIMEFORMAT='real %2Rs   user %2Us   sys %2Ss'
  cap build-cold.txt 'time GOCACHE="$LAB/gocache" go build -o /dev/null ./cmd/sweep'
  cap build-warm.txt 'time GOCACHE="$LAB/gocache" go build -o /dev/null ./cmd/sweep'
  cap dist-count.txt 'go tool dist list | wc -l'
  # Size matrix, written as CSV for the table in the chapter.
  echo "target,default,stripped" > "$out/build-matrix.csv"
  for t in linux/amd64 linux/arm64 darwin/arm64 windows/amd64; do
    os=${t%/*} arch=${t#*/}
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -o "$LAB/m-full" ./cmd/sweep
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags="-s -w" -o "$LAB/m-strip" ./cmd/sweep
    echo "$t,$(wc -c < "$LAB/m-full" | tr -d ' '),$(wc -c < "$LAB/m-strip" | tr -d ' ')" >> "$out/build-matrix.csv"
  done
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v3 go build -trimpath -o "$LAB/m-full" ./cmd/sweep
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v3 go build -trimpath -ldflags="-s -w" -o "$LAB/m-strip" ./cmd/sweep
  echo "linux/amd64 (GOAMD64=v3),$(wc -c < "$LAB/m-full" | tr -d ' '),$(wc -c < "$LAB/m-strip" | tr -d ' ')" >> "$out/build-matrix.csv"
  rm -f "$LAB/m-full" "$LAB/m-strip"
  cap build-release.txt 'CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags="-s -w" -o "$LAB/sweep-linux-amd64" ./cmd/sweep'
  cap build-file.txt 'file -b "$LAB/sweep-linux-amd64" | tr , "\n" | grep -v BuildID'
  cap build-vm.txt 'go version -m "$LAB/sweep-linux-amd64"'
  cap l7-exec.txt '"$LAB/sweep-linux-amd64" -version'; key l7-exec.txt 'cannot execute' 1
  cap l7-cgo.txt 'CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -o /dev/null ./cmd/sweep'
  key l7-cgo.txt 'runtime/cgo|error' 2
)
(
  # Reproducibility: the same commit in two directories.
  git clone -q "$root" "$LAB/a" && git clone -q "$root" "$LAB/b"
  cd "$LAB/b"
  cap repro-plain-a.txt 'cd "$LAB/a" && GOOS=linux go build -o ../a.bin ./cmd/sweep'
  cap repro-plain-b.txt 'cd "$LAB/b" && GOOS=linux go build -o ../b.bin ./cmd/sweep'
  cap repro-plain-sum.txt 'shasum -a 256 ../a.bin ../b.bin'
  cp "$out/repro-plain-sum.txt" "$out/ts/repro-plain-sum.txt"
  cap repro-trim-a.txt 'cd "$LAB/a" && GOOS=linux go build -trimpath -o ../a.bin ./cmd/sweep'
  cap repro-trim-b.txt 'cd "$LAB/b" && GOOS=linux go build -trimpath -o ../b.bin ./cmd/sweep'
  cap repro-trim-sum.txt 'shasum -a 256 ../a.bin ../b.bin'
  rm -rf "$LAB/a" "$LAB/b" "$LAB/a.bin" "$LAB/b.bin"
)
stamp=$LAB/stamp
(
  mkdir -p "$stamp" && cd "$stamp"
  git init -q
  cap l7-init.txt 'go mod init stamp'
  cap l7-goget.txt 'go get go@1.27.0 toolchain@go1.27.3'
  same_mod 2
  reader_copy 2 "$stamp"
  cap l7-tree.txt "find . -name '*.go' | sort"
  cap l7-test.txt 'go vet ./... && go test ./...'
  cap l7-run.txt 'go run ./cmd/stamp'
  commit_at 2026-11-02T14:07:31Z
  git add . && git commit -q -m "stamp: print build settings"
  cap l7-build.txt 'go build -o stamp ./cmd/stamp && ./stamp'
  cap l7-dirty.txt "go build -o stamp ./cmd/stamp && ./stamp | grep -E '^(main|vcs)'"
  key l7-dirty.txt '\+dirty|vcs.modified' 2
  cap l7-status.txt 'git status --short'
  echo /stamp > .gitignore
  commit_at 2026-11-02T14:09:02Z
  git add .gitignore && git commit -q -m "Ignore the binary"
  cap l7-clean.txt "go build -o stamp ./cmd/stamp && ./stamp | grep -E '^(main|vcs)'"
  git tag v0.1.0
  cap l7-tag.txt "go build -o stamp ./cmd/stamp && ./stamp | grep -E '^(main|vcs)'"
  cap l7-flag.txt './stamp -version'; key l7-flag.txt 'not defined' 1
)

echo "== lab 8: a buildinfo package"
(
  cd "$stamp"
  reader_copy 3 "$stamp"
  cap l8-nocmp.txt 'go test ./...'; key l8-nocmp.txt 'no required module' 2
  cap l8-goget.txt 'go get github.com/google/go-cmp@v0.7.0'
  cap l8-tidy.txt 'go mod tidy'
  same_mod 3
  cap l8-tree.txt "find . -name '*.go' | sort"
  cap l8-test.txt 'go vet ./... && go test ./...'
  commit_at 2026-11-02T15:12:44Z
  git add . && git commit -q -m "buildinfo: read the toolchain's stamp"
  cap l8-pseudo.txt 'go build -o stamp ./cmd/stamp && ./stamp -version'
  git tag v0.2.0
  cap l8-tagged.txt 'go build -o stamp ./cmd/stamp && ./stamp -version'
  cap l8-run.txt 'go run ./cmd/stamp -version'
  echo '// work in progress' >> cmd/stamp/main.go
  cap l8-dirty.txt 'go build -o stamp ./cmd/stamp && ./stamp -version'
  git checkout -q -- cmd/stamp/main.go

  broken "$stamp"; edit buildinfo/buildinfo.go 's/^func \(i Info\) String\(\) string/func (i *Info) String() string/m'
  cap l8-pointer.txt 'go test ./...'; key l8-pointer.txt 'stdout =' 1
  broken "$stamp"; edit buildinfo/buildinfo.go 's/ && v != "\(devel\)"//'
  cap l8-devel.txt 'go test ./buildinfo'; key l8-devel.txt 'FAIL: TestFrom/|devel' 3
  # go-cmp pads its diff with tabs and no-break spaces; one space reads better
  perl -pi -e 's/(?:[ \t]|\xc2\xa0)+/ /g; s/^ //' "$out/ts/l8-devel.txt"
  broken "$stamp"; edit cmd/stamp/main.go 's/buildinfo\.Get\(\)\)/buildinfo.from(nil, false))/'
  cap l8-unexported.txt 'go build ./...'; key l8-unexported.txt 'undefined' 1
)

echo "== lab 9: release stamping with -X"
(
  cd "$stamp"
  reader_copy 4 "$stamp"
  same_mod 4
  cap l9-tree.txt "find . -name '*.go' | sort"
  cap l9-test.txt 'go vet ./... && go test ./...'
  commit_at 2026-11-02T16:20:05Z
  git add . && git commit -q -m "buildinfo: linker overrides, JSON and User-Agent"
  cap l9-build.txt 'go build -o stamp ./cmd/stamp && ./stamp -version -json'
  export PKG=stamp/buildinfo
  cap bi-release.txt 'go build -trimpath -buildvcs=false -o stamp -ldflags "-s -w \
  -X $PKG.version=v1.4.0 \
  -X $PKG.revision=$(git rev-parse HEAD) \
  -X $PKG.buildTime=$(git log -1 --format=%ct)" \
  ./cmd/stamp'
  cap bi-release-version.txt './stamp -version'
  cap bi-json.txt './stamp -version -json'
  cap bi-release-vm.txt 'go version -m ./stamp'

  broken "$stamp"
  cap l9-typo.txt 'go build -o stamp -ldflags "-X stamp/buildinfo.Version=v1.4.0" ./cmd/stamp && ./stamp -version'
  key l9-typo.txt 'devel' 1
  broken "$stamp"; edit buildinfo/buildinfo.go 's/\tversion   string \/\/ release version, e.g. v1.4.0\n/\tversion   = os.Getenv("STAMP_VERSION") \/\/ release version\n/'
  edit buildinfo/buildinfo.go 's/import \(\n/import (\n\t"os"\n/'
  "$goroot/bin/gofmt" -w buildinfo/buildinfo.go
  cap l9-func.txt 'go build -o stamp -ldflags "-X stamp/buildinfo.version=v1.4.0" ./cmd/stamp && ./stamp -version'
  key l9-func.txt 'devel' 1
  broken "$stamp"; edit buildinfo/buildinfo.go 's/json:"time,omitzero"/json:"time,omitempty"/'
  cap l9-omitempty.txt 'go test ./buildinfo'; key l9-omitempty.txt '"time" present' 1
  broken "$stamp"; edit buildinfo/buildinfo.go 's/`json:"goVersion"`/`json:goVersion`/'
  cap l9-tag.txt 'go vet ./...'; key l9-tag.txt 'struct field tag' 1
  # A reader whose module is github.com/you/stamp and who copied the test.
  broken "$stamp"; edit go.mod 's/^module stamp$/module github.com\/you\/stamp/m'
  edit cmd/stamp/main.go 's#"stamp/buildinfo"#"github.com/you/stamp/buildinfo"#'
  edit cmd/stamp/main_test.go 's#\n\t"stamp/buildinfo"\n#\n\t"github.com/you/stamp/buildinfo"\n#'
  cap l9-modpath.txt 'go test ./cmd/stamp'; key l9-modpath.txt 'got  |want prefix' 2
)

echo "== lab 10: quality gates"
(
  cd "$stamp"
  cp "$clone/.golangci.yml" .
  cap gates-vet.txt 'go vet ./...'
  cap gates-lint.txt 'golangci-lint run ./...'
  mkdir -p "$LAB/lintdemo" && cd "$LAB/lintdemo"
  cap l10-lint-init.txt 'go mod init lintdemo'
  cp "$root/examples/ch01/lintdemo/fetch.go.txt" fetch.go
  cp "$clone/.golangci.yml" .
  cap lint-demo.txt 'golangci-lint run ./... | tail -7'
  golangci-lint run --show-stats=false --output.json.path=stdout ./... \
    2> /dev/null > "$out/lint-demo.json" || true

  cd "$tools"
  cap l10-get.txt 'go get -tool golang.org/x/vuln/cmd/govulncheck@v1.9.0'
  cap l10-tidy.txt 'go mod tidy'
  sed 's#^module tools$#module github.com/rahulbalajee/platform-go/examples/ch01/tools#' go.mod |
    cmp -s - "$root/examples/ch01/tools/go.mod" || { echo "tools go.mod differs from examples/ch01/tools"; exit 1; }
  cmp -s go.sum "$root/examples/ch01/tools/go.sum" || { echo "tools go.sum differs from examples/ch01/tools"; exit 1; }
  cap l10-tools.txt "go tool | grep -F '('"
  cd "$stamp"
  cap l10-notool.txt 'go tool govulncheck ./...'; key l10-notool.txt 'no such tool' 1
  cap l10-vuln.txt 'go tool -modfile="$LAB/tools/go.mod" govulncheck ./...'
  cd "$clone"
  cap vuln-root.txt 'go tool -modfile="$LAB/tools/go.mod" govulncheck ./...'
  cap vuln-bin.txt 'go tool -modfile="$LAB/tools/go.mod" govulncheck -mode=binary -show verbose \
  "$LAB/sweep-linux-amd64"'
  # The first watchtower scan is pinned to b0977b0, the last commit before
  # its vulnerable dependencies were upgraded; the second scans HEAD.
  git worktree add -q --detach "$LAB/before" b0977b0
  cap vuln-wt.txt "go tool -modfile=\"\$LAB/tools/go.mod\" govulncheck \\
  -C \"\$LAB/before/projects/watchtower\" ./... | grep -E '^(Vuln|    Found|Your)'"
  key vuln-wt.txt '^Your code' 1
  git worktree remove --force "$LAB/before"
  cap vuln-wt-fixed.txt 'cd projects/watchtower && go tool -modfile="$LAB/tools/go.mod" govulncheck ./...'
  cap make-n.txt 'make -n'
  cap ci-jobs.txt "sed -n '/^jobs:/,\$p' .github/workflows/ci.yml | grep -E '^  [a-z0-9-]+:\$'"
  cap ci-go-job.txt "sed -n '/^  go:/,/^\$/p' .github/workflows/ci.yml"

  broken "$stamp"; edit cmd/stamp/main.go 's/fmt\.Fprintf\(stdout, "%-14s %s\\n", s\.Key, s\.Value\)/fmt.Fprintf(stdout, "%-14s %s\\n", s.Key)/'
  cap l10-printf.txt 'go vet ./...'; key l10-printf.txt 'reads arg' 1
  broken "$stamp"; edit cmd/stamp/main.go 's/\t\tif err := buildinfo\.Get\(\)\.Write\(stdout, format\); err != nil \{\n\t\t\tfmt\.Fprintln\(stderr, "stamp:", err\)\n\t\t\treturn 1\n\t\t\}\n/\t\tbuildinfo.Get().Write(stdout, format)\n/'
  cap l10-errcheck.txt 'golangci-lint run ./...'; key l10-errcheck.txt 'errcheck' 1
  broken "$stamp"; go get golang.org/x/sync@v0.24.0 > /dev/null 2>&1
  cap l10-tidy-diff.txt 'go mod tidy -diff'; key l10-tidy-diff.txt '^[-+]require|^diff' 2
)

echo "== exercise answers"
(
  # 1.2: how old a go line can the stamp module declare?
  broken "$stamp"
  go mod edit -go=1.23.0
  cap ex2-go123.txt 'go vet ./...'
  cap ex2-go123-test.txt 'go test ./... 2>&1 | tail -4'
  go mod edit -go=1.20
  cap ex2-go120.txt 'go vet ./...'
  # 1.7: the inventory command from the solution module.
  rm -rf "$LAB/ex7" && cp -R "$root/solutions/ch01/ex7" "$LAB/ex7" && cd "$LAB/ex7"
  mkdir -p "$LAB/dist/linux"
  go build -buildvcs=false -o "$LAB/dist/stamp" ./cmd/stamp
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false -o "$LAB/dist/linux/stamp" ./cmd/stamp
  go test -c -buildvcs=false -o "$LAB/dist/buildinfo.test" ./buildinfo
  cp "$LAB/sweep-linux-amd64" "$LAB/dist/linux/sweep"
  cap ex7-run.txt 'go run ./cmd/inventory -module golang.org/x/sync "$LAB/dist"'
  cap ex7-older.txt 'go run ./cmd/inventory -module github.com/google/go-cmp -older v0.8.0 "$LAB/dist"'
)

echo "captured into $out"
