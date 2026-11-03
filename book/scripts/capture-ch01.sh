#!/usr/bin/env bash
# Regenerates the real terminal output shown in Chapter 1.
# Usage: book/scripts/capture-ch01.sh   (from the repository root)
#
# Needs network access (module proxy, checksum database, vulnerability
# database), git, golangci-lint and shasum. The toolchain section assumes the
# go command on PATH is older than the go1.27.3 the repository asks for (the
# book's machine has go1.26.4 installed system-wide), so that switching is
# visible.
#
# Everything that writes (clones, workspaces, module caches, binaries)
# happens under $DEMO, a scratch directory deleted on exit. The script never
# creates a go.work file in the repository or above it.
set -euo pipefail

# The toolchain demos need a go command older than go1.27.3 first on PATH.
GO_OLD=${GO_OLD:-/usr/local/go/bin}
if [ -x "$GO_OLD/go" ]; then export PATH="$GO_OLD:$PATH"; fi

repo=$(pwd)
out=book/output/ch01
mkdir -p "$out"
export DEMO
DEMO=$(mktemp -d "${TMPDIR:-/tmp}/ch01.XXXXXX")
DEMO=$(cd "$DEMO" && pwd -P)
cleanup() { chmod -R u+w "$DEMO" 2>/dev/null || true; rm -rf "$DEMO"; }
trap cleanup EXIT

# scrub makes captured paths stable and short: the scratch directory prints
# as $DEMO, the repository as ., and the home directory as ~.
scrub() {
	sed -e "s#${DEMO}#\$DEMO#g" -e "s#${repo}/##g" -e "s#${repo}#.#g" \
		-e "s#${HOME}#~#g"
}

# cap FILE COMMAND: run COMMAND (a shell string, exactly as printed in the
# book) in the current directory and save its scrubbed stdout and stderr.
# Failures are captured, not fatal: several demos show error messages.
cap() {
	local file=$1
	shift
	(eval "$*") >"$repo/$out/$file.raw" 2>&1 || true
	scrub <"$repo/$out/$file.raw" >"$repo/$out/$file"
	rm "$repo/$out/$file.raw"
}

T127=$(go env GOROOT)/bin # the go1.27.3 toolchain selected by go.mod
export PATH="$PATH:$HOME/go/bin" # golangci-lint

# ---- Toolchains --------------------------------------------------------------
cap tc-version.txt 'go version'
cap tc-local.txt 'GOTOOLCHAIN=local go version'
cap tc-env.txt 'go env GOTOOLCHAIN GOVERSION GOROOT'
cap tc-local-build.txt 'GOTOOLCHAIN=local go build ./...'
cap tc-trace.txt 'GODEBUG=toolchaintrace=1 go version 2>&1 | fold -s -w 88'
cap tc-path.txt 'GOTOOLCHAIN=path go version'
(
	mkdir -p "$DEMO/svc" && cd "$DEMO/svc"
	cap tc-init.txt 'go mod init example.com/svc'
	cap tc-gomod1.txt 'cat go.mod'
	cap tc-get.txt 'go get go@1.27.0 toolchain@go1.27.3'
	cap tc-gomod2.txt 'cat go.mod'
	cap tc-none.txt 'go get toolchain@none'
	cap tc-none-version.txt 'go version'
)

# ---- The build list of this repository -----------------------------------------
cap mod-graph.txt 'go mod graph'
cap mod-list.txt 'go list -m all'
cap mod-go-graph.txt "go mod graph | grep ' go@'"
cap mod-go-list.txt 'go list -m go'
cap mod-count-root.txt 'go list -m all | wc -l'
(
	cd projects/watchtower
	cap mod-count-wt.txt 'go list -m all | wc -l'
	cap mod-xnet.txt "go mod graph | awk '\$2 ~ /^golang.org\\/x\\/net@/ {print \$2}' | sort -V | uniq -c"
	cap mod-xnet-list.txt 'go list -m golang.org/x/net'
)

# ---- Minimal version selection in a private module universe --------------------
# mkproxy serves examples/ch01/mkproxy/universe.txtar as a file:// proxy.
# The demo runs the go1.27.3 toolchain directly with its own module cache, so
# nothing is downloaded and the user's cache stays clean.
(
	export PATH="$T127:$PATH" GOTOOLCHAIN=local GOMODCACHE="$DEMO/modcache" \
		GOFLAGS=-modcacherw
	go run ./examples/ch01/mkproxy -o "$DEMO/mvs" examples/ch01/mkproxy/universe.txtar
	cd "$DEMO/mvs/app"
	export GOPROXY="file://$DEMO/mvs/proxy" GONOSUMDB=example.com
	cap mvs-tidy.txt 'go mod tidy'
	cap mvs-graph.txt 'go mod graph'
	cap mvs-list.txt 'go list -m all'
	cap mvs-run.txt 'go run .'
	cap mvs-sum.txt 'cat go.sum'
	cap mvs-why.txt 'go mod why -m example.com/codec'
	cp go.mod go.mod.orig && cp go.sum go.sum.orig
	reset() { cp go.mod.orig go.mod && cp go.sum.orig go.sum; }

	cap mvs-u.txt 'go list -m -u all'
	cap mvs-get.txt 'go get example.com/metrics@v1.3.0'
	cap mvs-run2.txt 'go run .'
	cap mvs-u2.txt 'go list -m -u all'
	cap mvs-versions.txt 'go list -m -versions example.com/codec'
	cap mvs-retracted.txt 'go list -m -retracted -versions example.com/codec'
	cap mvs-latest.txt 'go get example.com/codec@latest'
	reset

	cap mvs-proxy.txt 'ls -C "$DEMO/mvs/proxy/example.com/codec/@v"'
	cap mvs-retract-mod.txt 'cat "$DEMO/mvs/proxy/example.com/codec/@v/v1.5.1.mod"'
	cap mvs-replace.txt 'go mod edit -replace example.com/codec=../fork/codec'
	cap mvs-replace-list.txt 'go list -m example.com/codec'
	cap mvs-replace-run.txt 'go run .'
	reset

	cap mvs-exclude.txt 'go mod edit -exclude example.com/codec@v1.4.0'
	cap mvs-exclude-tidy.txt 'go mod tidy'
	cap mvs-exclude-run.txt 'go run .'
	reset
)

# ---- go.sum, the checksum database, private modules ------------------------------
cap trust-sum.txt 'grep golang.org/x/sync go.sum'
cap trust-verify.txt 'go mod verify'
cap trust-sumdb.txt 'curl -s https://sum.golang.org/lookup/golang.org/x/sync@v0.24.0 | cut -c1-80'
cap trust-private.txt "GOPRIVATE='github.com/acme/*' go env GOPRIVATE GONOPROXY GONOSUMDB"

# ---- A clean clone of HEAD for builds, workspaces and tool experiments ---------
git clone -q "$repo" "$DEMO/platform-go"
(
	cd "$DEMO/platform-go/projects/watchtower"
	cap tools-wt-get.txt 'go get -tool golang.org/x/vuln/cmd/govulncheck@v1.9.0'
	git checkout -q -- go.mod go.sum
	cap vendor.txt 'go mod vendor && du -sh vendor && find vendor -name "*.go" | wc -l'
	rm -rf vendor
)

# ---- The tool directive -------------------------------------------------------------
(
	mkdir -p "$DEMO/tools-demo" && cd "$DEMO/tools-demo"
	go mod init example.com/platform-tools >/dev/null 2>&1
	cap tools-get.txt 'go get -tool golang.org/x/tools/cmd/stringer@v0.52.0'
)
cap tools-modfile.txt 'go tool -modfile=examples/ch01/tools/go.mod govulncheck -version'
(
	# Size of golangci-lint's build list, quoted in the text.
	mkdir -p "$DEMO/gcl" && cd "$DEMO/gcl"
	go mod init example.com/gcl >/dev/null 2>&1
	go get -tool github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 >/dev/null 2>&1
	cap gcl-count.txt 'go list -m all | wc -l'
)

(
	cd examples/ch01/tools
	cap tools-list.txt "go tool | grep -F '('"
	cap tools-generate.txt 'go generate -x ./...'
	cap tools-phase-string.txt "sed -n '/^func _/,/^}/p' rollout/phase_string.go"
	cap tools-test.txt 'go test -count=1 ./...'
	cap vuln-root.txt 'go tool govulncheck -C "$DEMO/platform-go" ./...'
	# The first watchtower scan is pinned to b0977b0, the last commit before
	# its vulnerable dependencies were upgraded; the second scans HEAD.
	export BEFORE="$DEMO/before"
	git -C "$repo" worktree add -q --detach "$BEFORE" b0977b0
	cap vuln-wt.txt "go tool govulncheck -C \"\$BEFORE/projects/watchtower\" ./... | grep -E '^(Vuln|    F|Your)'"
	git -C "$repo" worktree remove --force "$BEFORE"
	cap vuln-wt-fixed.txt 'go tool govulncheck -C ../../../projects/watchtower ./...'
)

# ---- Workspaces ----------------------------------------------------------------------
(
	cd "$DEMO/platform-go"
	cap ws-init.txt 'go work init . ./projects/watchtower'
	cap ws-cat.txt 'cat go.work'
	cap ws-list.txt 'go list -m'
	cap ws-env.txt 'go env GOWORK'
	cd projects/watchtower
	cap ws-versions.txt 'go list -m golang.org/x/sync golang.org/x/sys golang.org/x/time'
	cap ws-versions-off.txt 'GOWORK=off go list -m golang.org/x/sync golang.org/x/sys golang.org/x/time'

	# internal/ is about import paths, not module boundaries.
	mkdir -p hack/internaldemo
	cp "$repo/examples/ch01/internaldemo/main.go.txt" hack/internaldemo/main.go
	cap internal-ws.txt 'go build -o /dev/null ./hack/internaldemo && echo ok'
	cap internal-off.txt 'GOWORK=off go build -o /dev/null ./hack/internaldemo'
	rm -rf hack/internaldemo
	mkdir -p "$DEMO/ext" && cd "$DEMO/ext"
	printf 'module example.com/ext\n\ngo 1.27.0\n' >go.mod
	cp "$repo/examples/ch01/internaldemo/main.go.txt" main.go
	go work init . ../platform-go >/dev/null 2>&1
	cap internal-ext.txt 'go build -o /dev/null .'
	rm "$DEMO/platform-go/go.work" "$DEMO/platform-go/go.work.sum" 2>/dev/null || true
)

# ---- Building for distribution ------------------------------------------------------
(
	cd "$DEMO/platform-go"
	TIMEFORMAT='real %2Rs   user %2Us   sys %2Ss'
	cap build-cold.txt 'time GOCACHE="$DEMO/gocache" go build -o /dev/null ./cmd/sweep'
	cap build-warm.txt 'time GOCACHE="$DEMO/gocache" go build -o /dev/null ./cmd/sweep'
	cap dist-count.txt 'go tool dist list | wc -l'

	# Size matrix, written as CSV for the table in the chapter.
	echo "target,default,stripped" >"$repo/$out/build-matrix.csv"
	for t in linux/amd64 linux/arm64 darwin/arm64 windows/amd64; do
		os=${t%/*} arch=${t#*/}
		CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath \
			-o "$DEMO/m-full" ./cmd/sweep
		CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags="-s -w" \
			-o "$DEMO/m-strip" ./cmd/sweep
		echo "$t,$(wc -c <"$DEMO/m-full" | tr -d ' '),$(wc -c <"$DEMO/m-strip" | tr -d ' ')" \
			>>"$repo/$out/build-matrix.csv"
	done
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v3 go build -trimpath \
		-o "$DEMO/m-full" ./cmd/sweep
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v3 go build -trimpath -ldflags="-s -w" \
		-o "$DEMO/m-strip" ./cmd/sweep
	echo "linux/amd64 (GOAMD64=v3),$(wc -c <"$DEMO/m-full" | tr -d ' '),$(wc -c <"$DEMO/m-strip" | tr -d ' ')" \
		>>"$repo/$out/build-matrix.csv"

	cap build-release.txt 'CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags="-s -w" -o "$DEMO/sweep-linux-amd64" ./cmd/sweep'
	cap build-file.txt 'file -b "$DEMO/sweep-linux-amd64" | tr , "\n" | grep -v BuildID'
	cap build-vm.txt 'go version -m "$DEMO/sweep-linux-amd64"'
)
(
	cd examples/ch01/tools
	cap vuln-bin.txt 'go tool govulncheck -mode=binary -show verbose "$DEMO/sweep-linux-amd64"'
)
# Reproducibility: the same commit in two directories.
(
	git clone -q "$repo" "$DEMO/a" && git clone -q "$repo" "$DEMO/b"
	cd "$DEMO/b"
	cap repro-plain-a.txt 'cd "$DEMO/a" && GOOS=linux go build -o ../a.bin ./cmd/sweep'
	cap repro-plain-b.txt 'cd "$DEMO/b" && GOOS=linux go build -o ../b.bin ./cmd/sweep'
	cap repro-plain-sum.txt 'shasum -a 256 ../a.bin ../b.bin'
	cap repro-trim-a.txt 'cd "$DEMO/a" && GOOS=linux go build -trimpath -o ../a.bin ./cmd/sweep'
	cap repro-trim-b.txt 'cd "$DEMO/b" && GOOS=linux go build -trimpath -o ../b.bin ./cmd/sweep'
	cap repro-trim-sum.txt 'shasum -a 256 ../a.bin ../b.bin'
)

# ---- pkg/buildinfo in the real working tree -----------------------------------------
cap bi-build.txt 'go build -o "$DEMO/stamp" ./examples/ch01/stamp'
cap bi-version.txt '"$DEMO/stamp" -version'
cap bi-json.txt '"$DEMO/stamp" -version -json'
cap bi-settings.txt '"$DEMO/stamp"'
cap bi-run.txt 'go run ./examples/ch01/stamp -version'
export PKG=github.com/rahulbalajee/platform-go/pkg/buildinfo
cap bi-release.txt 'go build -trimpath -buildvcs=false -o "$DEMO/stamp" -ldflags "-s -w \
  -X $PKG.version=v1.4.0 \
  -X $PKG.revision=$(git rev-parse HEAD) \
  -X $PKG.buildTime=$(git log -1 --format=%ct)" \
  ./examples/ch01/stamp'
cap bi-release-version.txt '"$DEMO/stamp" -version'
cap bi-release-vm.txt 'go version -m "$DEMO/stamp"'
cap bi-test.txt 'go test -race -count=1 ./pkg/buildinfo/... ./examples/ch01/...'

# ---- Quality gates ---------------------------------------------------------------------
cap gates-vet.txt 'go vet ./pkg/buildinfo/... ./examples/ch01/...'
cap gates-lint.txt 'golangci-lint run ./pkg/buildinfo/... ./examples/ch01/...'
cap make-n.txt 'make -n'
cap ci-go-job.txt "sed -n '/^  go:/,/^\$/p' .github/workflows/ci.yml"
(
	mkdir -p "$DEMO/lintdemo" && cd "$DEMO/lintdemo"
	printf 'module example.com/lintdemo\n\ngo 1.27.0\n' >go.mod
	cp "$repo/examples/ch01/lintdemo/fetch.go.txt" fetch.go
	cp "$repo/.golangci.yml" .
	golangci-lint run --show-stats=false --output.json.path=stdout ./... \
		2>/dev/null >"$repo/$out/lint-demo.json" || true
)
echo "captured into $out"
