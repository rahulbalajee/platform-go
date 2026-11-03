// START reader OMIT

package main

import (
	"fmt"
	"io"
	"math/rand/v2"
	"strings"
	"time"
)

// logReader is an io.Reader that generates an access log as it is read.
// It holds one line at a time, so an endless log costs no more memory
// than a short one.
type logReader struct {
	rng     *rand.Rand
	lines   int    // how many lines to generate; 0 means no end
	longAt  int    // the line that gets a 1 MiB URL, or -1
	n       int    // lines generated so far
	line    []byte // the current line
	pending []byte // the part of line that Read has not returned yet
}

func newLogReader(lines, longAt int) *logReader {
	return &logReader{
		// Not for secrets, so math/rand is right; gosec flags it anyway.
		rng:   rand.New(rand.NewPCG(5, 2026)), //nolint:gosec
		lines: lines, longAt: longAt,
	}
}

// Read copies the next bytes of the log into p and returns how many it
// copied. When the log is over it returns 0 and io.EOF.
func (r *logReader) Read(p []byte) (int, error) {
	n := 0
	for n < len(p) {
		if len(r.pending) == 0 {
			if r.lines > 0 && r.n == r.lines {
				break // no more lines
			}
			r.line = r.appendLine(r.line[:0]) // reuse the buffer
			r.pending = r.line
			r.n++
		}
		c := copy(p[n:], r.pending) // copies min(len(dst), len(src)) bytes
		r.pending = r.pending[c:]
		n += c
	}
	if n == 0 && len(p) > 0 {
		return 0, io.EOF
	}
	return n, nil
}

// END reader OMIT

// START line OMIT
var (
	paths = []string{
		"/api/v1/orders", "/api/v1/users", "/healthz",
		"/api/v1/search", "/static/app.js",
	}
	methods = []string{"GET", "GET", "GET", "POST", "PUT"}
	epoch   = time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)
)

// appendLine appends line r.n to b: time, client address, method, path,
// status, response size and latency, separated by spaces.
func (r *logReader) appendLine(b []byte) []byte {
	path := fmt.Sprintf("%s/%d", paths[r.rng.IntN(len(paths))], r.rng.IntN(100_000))
	if r.n == r.longAt {
		path = "/api/v1/search?q=" + strings.Repeat("x", 1<<20)
	}
	status := 200
	switch x := r.rng.IntN(1000); {
	case x < 8:
		status = 503
	case x < 30:
		status = 404
	case x < 80:
		status = 304
	}
	ts := epoch.Add(time.Duration(r.n) * time.Millisecond)
	return fmt.Appendf(b, "%s 10.0.%d.%d %s %s %d %d %dms\n",
		ts.Format(time.RFC3339Nano), r.rng.IntN(256), r.rng.IntN(256),
		methods[r.rng.IntN(len(methods))], path, status,
		r.rng.IntN(64<<10), r.rng.IntN(900))
}

// END line OMIT
