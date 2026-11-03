// Command loggen writes a synthetic access log for the logscan examples:
// deterministic, roughly 80 bytes a line, with an optional pathological
// line (a 1 MiB URL) of the kind that breaks naive line readers.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"strings"
	"time"
)

func main() {
	n := flag.Int("lines", 1_000_000, "number of lines")
	longAt := flag.Int("long-at", -1, "write a 1 MiB line at this line number (-1: none)")
	flag.Parse()

	w := bufio.NewWriterSize(os.Stdout, 1<<20)
	rng := rand.New(rand.NewPCG(5, 2026)) //nolint:gosec // reproducible test data
	paths := []string{"/api/v1/orders", "/api/v1/users", "/healthz", "/api/v1/search", "/static/app.js"}
	methods := []string{"GET", "GET", "GET", "POST", "PUT"}
	ts := time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)
	for i := range *n {
		path := fmt.Sprintf("%s/%d", paths[rng.IntN(len(paths))], rng.IntN(100000))
		if i == *longAt {
			path = "/api/v1/search?q=" + strings.Repeat("x", 1<<20)
		}
		status := 200
		switch r := rng.IntN(1000); {
		case r < 8:
			status = 503
		case r < 30:
			status = 404
		case r < 80:
			status = 304
		}
		fmt.Fprintf(w, "%s 10.0.%d.%d %s %s %d %d %dms\n",
			ts.Add(time.Duration(i)*time.Millisecond).Format(time.RFC3339Nano),
			rng.IntN(256), rng.IntN(256), methods[rng.IntN(len(methods))], path,
			status, rng.IntN(64<<10), rng.IntN(900))
	}
	if err := w.Flush(); err != nil {
		fmt.Fprintln(os.Stderr, "loggen:", err)
		os.Exit(1)
	}
}
