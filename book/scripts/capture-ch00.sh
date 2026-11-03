#!/usr/bin/env bash
# Regenerates the real terminal output shown in Chapter 0 ("Go from Zero").
# Usage: book/scripts/capture-ch00.sh [section...]   (from the repository root)
# Sections: setup hello s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12 s13 s14 demo ex
# (default: all). Run it from a copy, since bash reads scripts as it goes:
#   cp book/scripts/capture-ch00.sh $TMPDIR/c0.sh && bash $TMPDIR/c0.sh
#
# The reader's machine is simulated: HOME is a fresh directory, the project
# lives in ~/logq, and Go 1.27 is on PATH as /usr/local/go/bin, the place the
# official installer puts it. Every listing the reader types comes from the
# snapshot modules in workbook/ch00/stepN; the mistakes in the troubleshooting
# tables are made by editing a copy of a snapshot, never by hand.
set -euo pipefail
root=$(pwd)
out=$root/book/output/ch00
wb=$root/workbook/ch00
mkdir -p "$out"
work=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ch00.XXXXXX")" && pwd -P)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

# The Go 1.27 toolchain: the one the repository's go.mod selects.
goroot=$(cd "$root" && env -u GOTOOLCHAIN -u GOFLAGS go env GOROOT)
mkdir -p "$work/usr/local"
ln -s "$goroot" "$work/usr/local/go"
lint=$(command -v golangci-lint || echo "$HOME/go/bin/golangci-lint")

export HOME=$work/home/you
mkdir -p "$HOME/go/bin"
ln -s "$lint" "$HOME/go/bin/golangci-lint"
export PATH="$work/usr/local/go/bin:$HOME/go/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset GOMODCACHE GOPROXY GOFLAGS GONOSUMDB GOTOOLCHAIN GOWORK GOPATH GOCACHE \
  GOROOT GOENV CGO_ENABLED GOOS GOARCH GODEBUG 2>/dev/null || true
export GOTOOLCHAIN=local

# scrub: hide machine-specific paths.
scrub() {
  sed -e "s#$HOME#/Users/you#g" -e "s#$goroot#/usr/local/go#g" \
      -e "s#$work/usr/local/go#/usr/local/go#g" -e "s#$work#/tmp#g" \
      -e "s#$(id -un)  staff#you  staff#g"
}
only=" ${*:-all} "
want() { [[ $only == *" all "* || $only == *" $1 "* ]]; }

# run: echo a command the way a shell prompt would, then run it. Failures
# are part of what the chapter shows, so they do not stop the script.
# $? inside a command is the status of the command before it, as in a shell.
last=0
run() { printf '$ %s\n' "$1"; set +e; (exit "$last"); eval "$1"; last=$?; set -e; }
# cap NAME CMD...: run each command in ~/logq and save the session as NAME.
cap() {
  local name=$1; shift
  ( cd "$HOME/logq"; for c in "$@"; do run "$c"; done ) > "$out/$name.txt" 2>&1 || true
  scrub < "$out/$name.txt" > "$out/$name.tmp" && mv "$out/$name.tmp" "$out/$name.txt"
}
# reset K: make ~/logq hold exactly the files of workbook/ch00/stepK, keeping
# the go.mod that `go mod init` wrote in Step 1, as a reader's would be.
reset() {
  if [[ ! -f $HOME/logq/go.mod ]]; then
    mkdir -p "$HOME/logq"
    ( cd "$HOME/logq" && go mod init logq > /dev/null 2>&1 )
  fi
  find "$HOME/logq" -mindepth 1 -maxdepth 1 ! -name go.mod -exec rm -rf {} +
  ( cd "$wb/step$1" && find . -type f ! -name go.mod | while read -r f; do
      mkdir -p "$HOME/logq/$(dirname "$f")"; cp "$f" "$HOME/logq/$f"; done )
}
# edit FILE: apply "@@@ old / @@@ new / @@@ end" blocks read from stdin to
# ~/logq/FILE. Each old text must occur exactly once.
cat > "$work/edit.py" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
for block in sys.stdin.read().split("@@@ old\n")[1:]:
    old, rest = block.split("@@@ new\n")
    new = rest.split("@@@ end\n")[0]
    n = src.count(old)
    if n != 1:
        sys.exit(f"edit {path}: {n} matches for {old!r}")
    src = src.replace(old, new)
open(path, "w").write(src)
PY
edit() { python3 "$work/edit.py" "$HOME/logq/$1"; }
# restore K FILE: put back one file of stepK after an edit.
restore() { cp "$wb/step$1/$2" "$HOME/logq/$2"; }

# --- Setup and the terminal ----------------------------------------------------
if want setup; then
echo setup
( cd "$HOME"
  run 'go version'
  run 'which go'
) 2>&1 | scrub > "$out/setup-version.txt"
( cd "$HOME"
  run 'pwd'
  run 'mkdir code'
  run 'cd code'
  run 'pwd'
  run 'ls'
  run 'echo "hello" > note.txt'
  run 'ls'
  run 'cat note.txt'
  run 'cd ..'
  run 'pwd'
  rm -rf "$HOME/code"
) 2>&1 | scrub > "$out/setup-terminal.txt"
fi

# --- Hello, world --------------------------------------------------------------
if want hello; then
echo hello
h=$HOME/hello
rm -rf "$h"
( cd "$HOME"
  run 'mkdir hello'
  run 'cd hello'
  run 'go mod init hello'
  run 'cat go.mod'
) 2>&1 | scrub > "$out/hello-init.txt"
cp "$wb/hello/main.go" "$h/main.go"
( cd "$h"
  run 'go run .'
  run 'go build'
  run 'ls'
  run './hello'
) 2>&1 | scrub > "$out/hello-run.txt"
( cd "$h"
  run 'file hello'
  run 'GOOS=linux GOARCH=amd64 go build -o hello-linux'
  run 'GOOS=windows GOARCH=amd64 go build -o hello.exe'
  run 'file hello-linux hello.exe | cut -d, -f1-2'
) 2>&1 | scrub > "$out/hello-cross.txt"
sed -i '' 's/fmt.Println/fmt.Prinln/' "$h/main.go"
( cd "$h"; run 'go run .' ) 2>&1 | scrub > "$out/hello-err-undefined.txt"
cp "$wb/hello/main.go" "$h/main.go"
sed -i '' 's/engineer!")/engineer!)/' "$h/main.go"
( cd "$h"; run 'go run .' ) 2>&1 | scrub > "$out/hello-err-quote.txt"
printf 'package main\nimport "fmt"\nfunc main() {\nfmt.Println( "Hello, platform engineer!" )\n}\n' > "$h/main.go"
( cd "$h"
  run 'cat main.go'
  run 'go fmt'
  run 'cat main.go'
) 2>&1 | scrub > "$out/hello-fmt.txt"
rm -rf "$h"
fi

# --- Step 1: variables, types, constants ----------------------------------------
if want s1; then
echo s1
rm -rf "$HOME/logq"
( cd "$HOME"
  run 'mkdir logq'
  run 'cd logq'
  run 'go mod init logq'
) 2>&1 | scrub > "$out/s1-init.txt"
reset 1
cap s1-run 'go run .' 'go vet .'
edit main.go <<'EOF'
@@@ old
	tool := "logq"
@@@ new
	tool := "logq"
	debug := true
@@@ end
EOF
cap s1-unused-var 'go run .'
reset 1
edit main.go <<'EOF'
@@@ old
import "fmt"
@@@ new
import (
	"fmt"
	"os"
)
@@@ end
EOF
cap s1-unused-import 'go run .'
reset 1
edit main.go <<'EOF'
@@@ old
	size := len(line) // len counts the bytes in a string
@@@ new
	size = len(line) // len counts the bytes in a string
@@@ end
EOF
cap s1-assign 'go run .'
reset 1
edit main.go <<'EOF'
@@@ old
	share := float64(errorCount) / float64(total) * 100
@@@ new
	share := float64(errorCount) / total * 100
@@@ end
EOF
cap s1-mismatch 'go run .'
reset 1
edit main.go <<'EOF'
@@@ old
const version = "0.1.0"
@@@ new
version := "0.1.0"
@@@ end
EOF
cap s1-outside 'go run .'
reset 1
edit main.go <<'EOF'
@@@ old
	share := float64(errorCount) / float64(total) * 100
@@@ new
	share := errorCount / total * 100
@@@ end
EOF
cap s1-intdiv 'go run .' 'go vet .'
reset 1
fi

# --- Step 2: decisions and loops --------------------------------------------------
if want s2; then
echo s2
reset 2
cap s2-run 'go run .'
edit main.go <<'EOF'
@@@ old
		fields := strings.Fields(line)
		if len(fields) < 3 {
			fmt.Println("skipping line", i+1, "because it is too short")
			skipped++
			continue
		}
@@@ new
		fields := strings.Fields(line)
@@@ end
EOF
cap s2-index 'go run .'
reset 2
edit main.go <<'EOF'
@@@ old
	if errorCount > 0 {
@@@ new
	if errorCount {
@@@ end
EOF
cap s2-nonbool 'go run .'
reset 2
edit main.go <<'EOF'
@@@ old
		fmt.Println("status: errors found")
	} else {
@@@ new
		fmt.Println("status: errors found")
	}
	else {
@@@ end
EOF
cap s2-else 'go run .'
reset 2
edit main.go <<'EOF'
@@@ old
		case "DEBUG":
@@@ new
		case 'DEBUG':
@@@ end
EOF
cap s2-rune 'go run .'
reset 2
edit main.go <<'EOF'
@@@ old
	for i, line := range lines {
@@@ new
	for i := 0; i <= len(lines); i++ {
		line := lines[i]
@@@ end
EOF
cap s2-loop 'go run .'
reset 2
fi

# --- Step 3: functions and errors ------------------------------------------------
if want s3; then
echo s3
reset 3
cap s3-run 'go run .'
edit main.go <<'EOF'
@@@ old
		return level, nil
	}
	return "", fmt.Errorf("unknown level %q", level)
}
@@@ new
		return level, nil
	}
}
@@@ end
EOF
cap s3-missing 'go run .'
reset 3
edit main.go <<'EOF'
@@@ old
		level, err := parseLevel(line)
		if err != nil {
			fmt.Fprintf(os.Stderr, "line %d: %v\n", i+1, err)
			bad++
			continue
		}
@@@ new
		level := parseLevel(line)
@@@ end
EOF
cap s3-mismatch 'go run .'
reset 3
edit main.go <<'EOF'
@@@ old
		return level, nil
@@@ new
		return level
@@@ end
EOF
cap s3-notenough 'go run .'
reset 3
edit main.go <<'EOF'
@@@ old
		level, err := parseLevel(line)
		if err != nil {
			fmt.Fprintf(os.Stderr, "line %d: %v\n", i+1, err)
			bad++
			continue
		}
@@@ new
		level, err := parseLevel(line)
@@@ end
EOF
cap s3-unusederr 'go run .'
reset 3
fi

# --- Step 4: reading a file ------------------------------------------------------
if want s4; then
echo s4
reset 4
cap s4-run 'go run . app.log'
cap s4-errors 'go run .' 'go run . nope.log' 'cd ~' 'go run . app.log'
edit main.go <<'EOF'
@@@ old
	return string(data), nil
@@@ new
	return data, nil
@@@ end
EOF
cap s4-bytes 'go run . app.log'
reset 4
fi

# --- Step 5: streaming -------------------------------------------------------------
if want s5; then
echo s5
reset 4
( cd "$HOME/logq"; go build -o logq-step4 . )
cap s5-big \
  "yes '2026-11-03T09:02:40Z ERROR api GET /orders 500 timeout talking to db' | head -n 2000000 > big.log" \
  'ls -lh big.log' \
  "/usr/bin/time -l ./logq-step4 big.log 2>&1 | grep -E 'ERROR|real|maximum resident'"
reset 5
( cd "$HOME/logq"; yes '2026-11-03T09:02:40Z ERROR api GET /orders 500 timeout talking to db' | head -n 2000000 > big.log || true )
cap s5-run 'go run . app.log' 'go build -o logq .' \
  "/usr/bin/time -l ./logq big.log 2>&1 | grep -E 'ERROR|real|maximum resident'"
cap s5-long \
  "printf '2026-11-03T09:00:00Z INFO api ' > long.log" \
  "head -c 100000 /dev/zero | tr '\\0' x >> long.log" \
  'echo >> long.log' \
  'wc -c long.log' \
  'go run . long.log'
edit main.go <<'EOF'
@@@ old
	scanner.Buffer(make([]byte, 0, 64*1024), maxLine)
@@@ new
@@@ end
EOF
cap s5-toolong 'go run . long.log'
edit main.go <<'EOF'
@@@ old
	if err := scanner.Err(); err != nil {
		return err
	}
@@@ new
@@@ end
EOF
cap s5-noerr 'go run . long.log; echo "exit status: $?"'
reset 5
edit main.go <<'EOF'
@@@ old
		line := scanner.Text()
@@@ new
		line := scanner.Text
@@@ end
EOF
cap s5-text 'go run . app.log'
reset 5
fi

# --- Step 6: slices and maps --------------------------------------------------------
if want s6; then
echo s6
reset 6
cap s6-run 'go run . app.log'
edit main.go <<'EOF'
@@@ old
	counts := make(map[string]int)
@@@ new
	var counts map[string]int
@@@ end
EOF
cap s6-nilmap 'go run . app.log'
reset 6
edit main.go <<'EOF'
@@@ old
			bad = append(bad, lineNo)
@@@ new
			append(bad, lineNo)
@@@ end
EOF
cap s6-append 'go run . app.log'
reset 6
edit main.go <<'EOF'
@@@ old
	for _, level := range levels {
		fmt.Printf("%-6s %d\n", level, counts[level])
		total += counts[level]
	}
@@@ new
	for level, n := range counts {
		fmt.Printf("%-6s %d\n", level, n)
		total += n
	}
@@@ end
EOF
( cd "$HOME/logq"; go build -o logq . )
cap s6-order './logq app.log 2>/dev/null | head -4' './logq app.log 2>/dev/null | head -4'
reset 6
edit main.go <<'EOF'
@@@ old
	fmt.Printf("%-6s %d %v\n", "bad", len(bad), bad)
@@@ new
	fmt.Printf("%-6s %d, first on line %d\n", "bad", len(bad), bad[0])
@@@ end
EOF
cap s6-index 'grep -v format app.log > clean.log' 'go run . clean.log'
reset 6
fi

# --- Step 7: structs and methods ---------------------------------------------------
if want s7; then
echo s7
reset 7
cap s7-run 'go run . app.log'
edit main.go <<'EOF'
@@@ old
func (s *Stats) Add(e Entry) {
@@@ new
func (s Stats) Add(e Entry) {
@@@ end
EOF
cap s7-value 'go run . app.log'
reset 7
edit main.go <<'EOF'
@@@ old
	var st Stats
	scanner := bufio.NewScanner(r)
@@@ new
	var st *Stats
	scanner := bufio.NewScanner(r)
@@@ end
EOF
edit main.go <<'EOF'
@@@ old
	return st, scanner.Err()
@@@ new
	return *st, scanner.Err()
@@@ end
EOF
cap s7-nilptr 'go run . app.log 2>&1 | head -6 | cut -c1-80'
reset 7
edit main.go <<'EOF'
@@@ old
	e := Entry{Time: t, Level: parts[1], Service: parts[2], Message: parts[3]}
@@@ new
	e := Entry{t, parts[1], parts[2]}
@@@ end
EOF
cap s7-literal 'go run . app.log'
reset 7
edit main.go <<'EOF'
@@@ old
	t, err := time.Parse(time.RFC3339, parts[0])
	if err != nil {
		return Entry{}, fmt.Errorf("bad time %q", parts[0])
	}
@@@ new
	t, err := time.Parse("YYYY-MM-DDThh:mm:ssZ", parts[0])
	if err != nil {
		return Entry{}, err
	}
@@@ end
EOF
cap s7-layout 'go run . app.log 2>&1 | head -3'
reset 7
fi

# --- Step 8: packages ----------------------------------------------------------------
if want s8; then
echo s8
reset 8
cap s8-tree 'find . -name "*.go" | sort' 'go run . app.log' 'go vet ./...'
python3 - "$HOME/logq" <<'PY'
import sys, pathlib
d = pathlib.Path(sys.argv[1])
p = d / "logline/logline.go"; s = p.read_text()
p.write_text(s.replace("func Parse(line string)", "func parse(line string)"))
p = d / "main.go"; s = p.read_text()
p.write_text(s.replace("logline.Parse(line)", "logline.parse(line)"))
PY
cap s8-unexported 'go build .'
reset 8
edit main.go <<'EOF'
@@@ old
	"logq/logline"
@@@ new
	"logline"
@@@ end
EOF
cap s8-importpath 'go build .'
reset 8
sed -i '' 's/^package logline$/package main/' "$HOME/logq/logline/stats.go"
cap s8-pkgname 'go build .'
reset 8
sed -i '' 's/logline\.Stats/Stats/g' "$HOME/logq/main.go"
cap s8-prefix 'go build .'
reset 8
fi

# --- Step 9: tests ------------------------------------------------------------------
if want s9; then
echo s9
reset 9
cap s9-tree 'find . -type f -not -name app.log | sort'
cap s9-test 'go test ./...'
cap s9-verbose 'go test -v ./logline'
cap s9-cover 'go test -cover ./...' \
  'go test -coverprofile=cover.out ./logline' \
  'go tool cover -func=cover.out'
cap s9-run 'go test -v -run "TestParse/bad" ./logline'
cap s9-lint 'golangci-lint run ./...'
edit logline/logline.go <<'EOF'
@@@ old
	e := Entry{Time: t, Level: level, Service: parts[2], Message: parts[3]}
@@@ new
	e := Entry{Time: t, Level: level, Service: parts[2], Message: parts[2]}
@@@ end
EOF
cap s9-fail 'go test ./...'
reset 9
cap s9-root 'go test'
mv "$HOME/logq/logline/logline_test.go" "$HOME/logq/logline/logline_tests.go"
rm "$HOME/logq/logline/stats_test.go"
cap s9-misnamed 'go test ./...'
reset 9
fi

# --- Step 10: flags, stdin and exit codes ---------------------------------------------
if want s10; then
echo s10
reset 10
cap s10-build 'go build -o logq .' './logq -h'
cap s10-run './logq -level warn app.log' \
  './logq -level error -grep timeout app.log edge.log'
cap s10-stdin 'cat app.log | ./logq -count'
cap s10-exit './logq -grep "disk full" app.log' 'echo $?' \
  './logq -level loud app.log' 'echo $?'
cap s10-order './logq app.log -level error 2>&1 | tail -3'
cap s10-unknown './logq -lvl warn app.log'
cap s10-gorun 'go run . -level loud app.log' 'echo $?'
edit main.go <<'EOF'
@@@ old
		count:    *count,
@@@ new
		count:    count,
@@@ end
EOF
cap s10-pointer 'go build -o logq .'
reset 10
fi

# --- Step 11: interfaces ---------------------------------------------------------------
if want s11; then
echo s11
reset 11
cap s11-test 'go test ./...'
cap s11-run 'go build -o logq .' \
  './logq -count -level warn -grep timeout app.log edge.log' \
  "./logq -regexp 'job [0-9]+ (done|failed)' app.log" \
  "./logq -regexp 'job [0-9+' app.log"
edit main.go <<'EOF'
@@@ old
		all = append(all, re)
@@@ new
		all = append(all, *re)
@@@ end
EOF
cap s11-ptrrecv 'go build .'
reset 11
edit match/match.go <<'EOF'
@@@ old
func (m Contains) Match(e logline.Entry) bool {
	return strings.Contains(e.Message, string(m))
}
@@@ new
func (m Contains) Match(message string) bool {
	return strings.Contains(message, string(m))
}
@@@ end
EOF
cap s11-signature 'go build ./...'
reset 11
edit main.go <<'EOF'
@@@ old
	all := match.All{match.MinLevel(minLevel)}
@@@ new
	if grep == "" && expr == "" && minLevel == logline.Debug {
		return nil, nil // no filters, so nothing to match
	}
	all := match.All{match.MinLevel(minLevel)}
@@@ end
EOF
cap s11-nil 'go run . app.log 2>&1 | head -6 | cut -c1-80'
reset 11
edit main_test.go <<'EOF'
@@@ old
			code := run(tt.args, stdin, &stdout, &stderr)
@@@ new
			code := run(tt.args, stdin, stdout, &stderr)
@@@ end
EOF
cap s11-buffer 'go test .'
reset 11
fi

# --- Step 12: JSON and generics -----------------------------------------------------------
if want s12; then
echo s12
reset 12
cap s12-json 'go build -o logq .' './logq -json -level error -grep reset app.log'
cap s12-top './logq -top 3 app.log edge.log 2>/dev/null' 'go test ./...'
edit logline/logline.go <<'EOF'
@@@ old
func (l Level) MarshalText() ([]byte, error) {
	return []byte(l.String()), nil
}
@@@ new
@@@ end
EOF
cap s12-nomarshal 'go run . -json -level error -grep reset app.log'
reset 12
edit logline/logline.go <<'EOF'
@@@ old
	Service string    `json:"service"`
@@@ new
	service string    `json:"service"`
@@@ end
EOF
sed -i '' 's/Service: parts\[2\]/service: parts[2]/' "$HOME/logq/logline/logline.go"
sed -i '' 's/s\.Services\[e\.Service\]/s.Services[e.service]/' "$HOME/logq/logline/stats.go"
cap s12-lower 'go run . -json -level error -grep reset app.log'
reset 12
edit logline/logline.go <<'EOF'
@@@ old
	Service string    `json:"service"`
@@@ new
	Service string    `json:"service`
@@@ end
EOF
cap s12-tag 'go vet ./...'
reset 12
edit scan.go <<'EOF'
@@@ old
			if err := enc.Encode(e); err != nil {
				return err
			}
@@@ new
			enc.Encode(e)
@@@ end
EOF
cap s12-errcheck 'go vet ./...' 'golangci-lint run ./...'
reset 12
edit main.go <<'EOF'
@@@ old
	for _, sc := range rank.Top(st.Services, c.top) {
@@@ new
	minutes := map[time.Time]int{}
	for _, mc := range rank.Top(minutes, 3) {
		fmt.Fprintln(stdout, mc.Key, mc.N)
	}
	for _, sc := range rank.Top(st.Services, c.top) {
@@@ end
EOF
edit main.go <<'EOF'
@@@ old
	"os"
@@@ new
	"os"
	"time"
@@@ end
EOF
cap s12-constraint 'go build .'
reset 12
fi

# --- Step 13: errors ---------------------------------------------------------------------
if want s13; then
echo s13
reset 13
cap s13-run 'go build -o logq .' './logq -strict app.log' 'echo $?' \
  './logq -level error nope.log' 'echo $?'
( cd "$HOME/logq"
  printf '2026-11-03T09:00:00Z INFO api ' > huge.log
  head -c 2000000 /dev/zero | tr '\0' x >> huge.log
  echo >> huge.log )
cap s13-toolong './logq huge.log'
cap s13-test 'go test ./...'
edit main.go <<'EOF'
@@@ old
	case errors.Is(err, bufio.ErrTooLong):
@@@ new
	case err == bufio.ErrTooLong:
@@@ end
EOF
cap s13-equal 'go build -o logq . && ./logq huge.log' 'golangci-lint run ./...'
reset 13
edit scan.go <<'EOF'
@@@ old
			err = fmt.Errorf("%s:%d: %w", name, lineNo, err)
@@@ new
			err = fmt.Errorf("%s:%d: %v", name, lineNo, err)
@@@ end
EOF
cap s13-percentv 'go build -o logq . && ./logq -strict app.log > /dev/null' \
  'golangci-lint run ./...'
reset 13
edit main.go <<'EOF'
@@@ old
	case errors.As(err, &perr):
@@@ new
	case errors.As(err, perr):
@@@ end
EOF
cap s13-as 'go vet .'
reset 13
edit main.go <<'EOF'
@@@ old
	var perr *logline.ParseError
	switch {
	case errors.Is(err, fs.ErrNotExist):
		fmt.Fprintln(w, "logq: hint: check the path; with no files, logq reads stdin")
	case errors.Is(err, bufio.ErrTooLong):
		fmt.Fprintf(w, "logq: hint: lines can be at most %d bytes long\n", maxLine)
	case errors.As(err, &perr):
		fmt.Fprintln(w, "logq: hint:", parseHints[perr.Field])
	}
@@@ new
	switch e := err.(type) {
	case *logline.ParseError:
		fmt.Fprintln(w, "logq: hint:", parseHints[e.Field])
	}
@@@ end
EOF
sed -i '' -e '/^	"bufio"$/d' -e '/^	"io\/fs"$/d' "$HOME/logq/main.go"
cap s13-typeswitch 'go build -o logq . && ./logq -strict app.log > /dev/null' \
  'golangci-lint run ./...'
reset 13
edit main.go <<'EOF'
@@@ old
	var st logline.Stats
	for _, name := range files {
		if err := c.scanFile(name, &st); err != nil {
			explain(stderr, err)
			return 2
		}
	}
@@@ new
	var st logline.Stats
	for _, name := range files {
		err := c.scanFile(name, &st)
		if err != nil {
			break
		}
	}
	if err != nil {
		explain(stderr, err)
		return 2
	}
@@@ end
EOF
cap s13-shadow 'go build -o logq . && ./logq -level error nope.log' 'echo $?'
reset 13
fi

# --- Step 14: concurrency ------------------------------------------------------------------
if want s14; then
echo s14
reset 14
cap s14-test 'go test -race ./...'
cap s14-run 'go build -o logq .' './logq -level error app.log edge.log'
( cd "$HOME/logq"; mkdir -p logs
  for i in $(seq -w 1 8); do
    yes '2026-11-03T09:02:40Z ERROR api GET /orders 500 timeout talking to db' \
      | head -n 2000000 > "logs/app-$i.log" || true
  done )
cap s14-speed 'ls logs' \
  "/usr/bin/time ./logq -j 1 -count logs/*.log 2>&1 | grep -E 'ERROR|real'" \
  "/usr/bin/time ./logq -j 8 -count logs/*.log 2>&1 | grep -E 'ERROR|real'"
rm -rf "$HOME/logq/logs"
edit scan.go <<'EOF'
@@@ old
func (c config) scanAll(files []string) []*result {
	results := make(chan *result)
	slots := make(chan struct{}, c.jobs) // holds one token per running scan

	var wg sync.WaitGroup
	for i, name := range files {
		wg.Go(func() {
			slots <- struct{}{}        // take a slot; blocks while all are in use
			defer func() { <-slots }() // give the slot back when done
			r := c.scanOne(name)
			r.index = i
			results <- r
		})
	}
	go func() {
		wg.Wait()      // once every scan has sent its result,
		close(results) // tell the loop below that no more are coming
	}()

	ordered := make([]*result, len(files))
	for r := range results {
		ordered[r.index] = r
	}
	return ordered
}
@@@ new
func (c config) scanAll(files []string) []*result {
	var results []*result
	var wg sync.WaitGroup
	for i, name := range files {
		wg.Go(func() {
			r := c.scanOne(name)
			r.index = i
			results = append(results, r)
		})
	}
	wg.Wait()
	return results
}
@@@ end
EOF
cap s14-race 'go build -o logq . && ./logq -count app.log edge.log 2>/dev/null | head -3' \
  'go build -race -o logq . && ./logq -count app.log edge.log 2>&1 | head -26'
reset 14
edit scan.go <<'EOF'
@@@ old
	go func() {
		wg.Wait()      // once every scan has sent its result,
		close(results) // tell the loop below that no more are coming
	}()
@@@ new
@@@ end
EOF
cap s14-deadlock 'go run . app.log edge.log 2>&1 | head -6 | cut -c1-80'
reset 14
( cd "$HOME/logq"; mkdir -p many
  for i in $(seq -w 1 300); do
    yes '2026-11-03T09:02:40Z INFO api GET /healthz 200 2ms' | head -n 2000 > "many/$i.log" || true
  done )
edit scan.go <<'EOF'
@@@ old
	slots := make(chan struct{}, c.jobs) // holds one token per running scan
@@@ new
@@@ end
@@@ old
			slots <- struct{}{}        // take a slot; blocks while all are in use
			defer func() { <-slots }() // give the slot back when done
@@@ new
@@@ end
EOF
# Out of descriptors, the program fails in one of two ways, depending on
# timing: logq's own "too many open files" error, or a fatal error from the
# runtime when it needs a descriptor itself (the chapter quotes both). Retry
# until the run shows the first, which is the one the step explains.
for try in $(seq 1 30); do
  cap s14-fds 'ls many | wc -l' 'go build -o logq .' 'ulimit -SHn 64' \
    './logq -count many/*.log' 'echo $?'
  grep -q 'too many open files' "$out/s14-fds.txt" && break
done
restore 14 scan.go
cap s14-fds-ok 'go build -o logq .' 'ulimit -SHn 64' './logq -count many/*.log | head -4'
rm -rf "$HOME/logq/many"
fi

# --- The finished tool, for "What we're building" --------------------------------------------
if want demo; then
echo demo
reset 14
( cd "$HOME/logq"; go build -o logq . )
cap demo-1 './logq -level warn app.log edge.log 2>/dev/null'
cap demo-2 './logq -json -level error -grep reset app.log edge.log 2>/dev/null'
cap demo-3 'cat app.log edge.log | ./logq -count -top 3'
cap demo-4 './logq -strict app.log > /dev/null' 'echo $?'
fi

# --- Exercise 3: programs to predict -----------------------------------------------------------
if want ex; then
echo ex
for p in a b c d; do mkdir -p "$work/ex3/$p"; printf 'module ex3\n\ngo 1.27.0\n' > "$work/ex3/$p/go.mod"; done
cat > "$work/ex3/a/main.go" <<'EOF'
package main

import "fmt"

func main() {
	count := 0
	count := count + 1
	fmt.Println(count)
}
EOF
cat > "$work/ex3/b/main.go" <<'EOF'
package main

import "fmt"

func main() {
	var port int = "8080"
	fmt.Println(port)
}
EOF
cat > "$work/ex3/c/main.go" <<'EOF'
package main

import "fmt"

func main() {
	names := []string{"api", "db"}
	for i := range names {
		fmt.Println(names[i+1])
	}
}
EOF
cat > "$work/ex3/d/main.go" <<'EOF'
package main

import "fmt"

func main() {
	counts := map[string]int{"INFO": 3}
	counts["WARN"]++
	fmt.Println(counts["WARN"],
		counts["ERROR"], len(counts))
}
EOF
for p in a b c d; do
  ( cd "$work/ex3/$p"; run 'go run .' ) 2>&1 | sed -e "s#$work/ex3/$p#/Users/you/ex3#g" \
    -e "s#$goroot#/usr/local/go#g" > "$out/ex3-$p.txt"
done
fi
echo "done: $out"
