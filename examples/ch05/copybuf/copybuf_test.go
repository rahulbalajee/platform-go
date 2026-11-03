package copybuf

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
)

const fileSize = 256 << 20

// lineCounter is a cheap io.Writer, so the benchmark measures the copy
// loop (syscalls and buffer handling) rather than the consumer. It also
// records the largest write, which is the buffer size io.Copy really used.
type lineCounter struct{ n, maxWrite int }

func (c *lineCounter) Write(p []byte) (int, error) {
	c.n += bytes.Count(p, []byte("\n"))
	c.maxWrite = max(c.maxWrite, len(p))
	return len(p), nil
}

func makeFile(b *testing.B) string {
	b.Helper()
	path := filepath.Join(b.TempDir(), "data.log")
	line := []byte("2026-11-03T10:15:42Z 10.0.3.17 GET /api/v1/orders/1234 200 1532 12ms\n")
	data := bytes.Repeat(line, fileSize/len(line))
	if err := os.WriteFile(path, data, 0o600); err != nil {
		b.Fatal(err)
	}
	return path
}

func BenchmarkCopy(b *testing.B) {
	path := makeFile(b)
	run := func(name string, copyFn func(io.Writer, *os.File) error) {
		b.Run(name, func(b *testing.B) {
			b.SetBytes(fileSize)
			var w lineCounter
			for b.Loop() {
				f, err := os.Open(path)
				if err != nil {
					b.Fatal(err)
				}
				if err := copyFn(&w, f); err != nil {
					b.Fatal(err)
				}
				_ = f.Close()
			}
			b.ReportMetric(float64(w.maxWrite), "B/write")
		})
	}
	// START bench OMIT
	for _, size := range []int{512, 4 << 10, 32 << 10, 256 << 10, 1 << 20} {
		run("buf="+human(size), func(w io.Writer, f *os.File) error {
			// Hide *os.File's WriteTo method, or CopyBuffer ignores buf.
			_, err := io.CopyBuffer(w, struct{ io.Reader }{f}, make([]byte, size))
			return err
		})
	}
	run("buf=1MiB-via-WriteTo", func(w io.Writer, f *os.File) error {
		_, err := io.CopyBuffer(w, f, make([]byte, 1<<20)) // f.WriteTo wins
		return err
	})
	// END bench OMIT
}

func human(n int) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%dMiB", n>>20)
	case n >= 1<<10:
		return fmt.Sprintf("%dKiB", n>>10)
	}
	return fmt.Sprintf("%dB", n)
}
