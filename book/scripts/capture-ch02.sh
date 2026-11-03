#!/usr/bin/env bash
# Regenerates the real terminal output shown in Chapter 2.
# Usage: book/scripts/capture-ch02.sh   (from the repository root)
# Needs network access once, to fetch apidiff into the module cache.
set -euo pipefail
out=book/output/ch02
mkdir -p "$out"
root=$(pwd)
scrub() { sed -e "s#${root}/##g"; }

for s in pages deploy flaky errors; do
  go run ./examples/ch02/tour "$s" > "$out/tour-$s.txt" 2>&1
done

go doc ./pkg/platformapi > "$out/godoc-pkg.txt"
go doc ./pkg/platformapi.ExampleAPIError > "$out/godoc-example.txt"
go doc ./pkg/platformapi/platformapifake Server | tail -n +3 > "$out/godoc-fake.txt"

# A generic method cannot satisfy an interface method: the compiler's words.
go build ./examples/ch02/testdata/genericiface 2>&1 | fold -s -w 92 \
  > "$out/generic-iface.txt" || true

# stderr only carries "go: downloading" noise on the first run.
go run golang.org/x/exp/cmd/apidiff@latest \
    ./examples/ch02/evolve/before ./examples/ch02/evolve/after 2>/dev/null \
  | fold -s -w 92 > "$out/apidiff.txt"

go test -count=1 -v -run 'TestRetries|TestRetryAfter|TestWait|TestCancelling' \
  ./pkg/platformapi 2>&1 | grep -E '^(=== RUN|--- |ok|PASS|FAIL)' | scrub \
  > "$out/test-synctest.txt"
go test -race -count=1 ./pkg/platformapi/... ./examples/ch02/... 2>&1 | scrub \
  > "$out/test-all.txt"
echo "captured into $out"
