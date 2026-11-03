// START head OMIT

package sweep_test

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"

	"sweep/internal/sweep"
)

// END head OMIT

// START helpers OMIT
// inventory returns an n-line inventory that mixes target kinds, comments
// and blank lines, like a real one.
func inventory(n int) string {
	var b strings.Builder
	for i := range n {
		switch i % 5 {
		case 0:
			fmt.Fprintf(&b, "https://svc-%d.staging.example.com/healthz\n", i)
		case 1:
			fmt.Fprintf(&b, "tcp://db-%d.staging.internal:5432\n", i)
		case 2:
			fmt.Fprintf(&b, "tls://edge-%d.example.com:443\n", i)
		case 3:
			fmt.Fprintf(&b, "dns://api-%d.example.com\n", i)
		default:
			fmt.Fprintf(&b, "# team %d\n\n", i)
		}
	}
	return b.String()
}

// results returns n results shaped like a real sweep's.
func results(n int) []sweep.Result {
	rs := make([]sweep.Result, n)
	for i := range rs {
		rs[i] = sweep.Result{
			Index: i, Target: fmt.Sprintf("https://svc-%d.example.com/healthz", i),
			Kind: sweep.KindHTTP, Status: sweep.StatusUp, Attempts: 1,
			Latency: time.Duration(i) * time.Millisecond, Detail: "200 OK",
		}
		if i%10 == 0 {
			rs[i].Status, rs[i].Attempts = sweep.StatusDown, 3
			rs[i].Error = "unhealthy status 503 Service Unavailable" +
				" (after 3 attempts)"
		}
	}
	return rs
}

// END helpers OMIT

// START parse OMIT
func BenchmarkParseTargets(b *testing.B) {
	inv := inventory(1000) // setup before b.Loop is not timed
	for b.Loop() {
		if _, err := sweep.ParseTargets(strings.NewReader(inv)); err != nil {
			b.Fatal(err)
		}
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N)/1000, "ns/line")
}

// END parse OMIT

// START benches OMIT
// START report OMIT
func BenchmarkReport(b *testing.B) {
	rs := results(1000)
	for _, format := range []string{"table", "json", "jsonl"} {
		b.Run(format, func(b *testing.B) {
			for b.Loop() {
				rep, _ := sweep.NewReporter(format, io.Discard)
				for _, r := range rs {
					_ = rep.Add(r)
				}
				_ = rep.Close(sweep.Summary{Total: len(rs)})
			}
		})
	}
}

// END report OMIT

// START decode OMIT
// BenchmarkDecodeJSONL measures the consumer's side: a deploy gate reading
// 1,000 lines of sweep -o jsonl.
func BenchmarkDecodeJSONL(b *testing.B) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	for _, r := range results(1000) {
		_ = enc.Encode(r)
	}
	for b.Loop() {
		sc := bufio.NewScanner(bytes.NewReader(buf.Bytes()))
		for sc.Scan() {
			var r sweep.Result
			if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
				b.Fatal(err)
			}
		}
	}
}

// END decode OMIT
// END benches OMIT
