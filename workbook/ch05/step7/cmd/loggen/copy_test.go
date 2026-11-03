package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// START bench OMIT
// BenchmarkCopy copies a 256 MiB log into a countWriter through buffers of
// different sizes. MaxWrite reports the buffer size io.Copy really used.
func BenchmarkCopy(b *testing.B) {
	const size = 256 << 20
	path := filepath.Join(b.TempDir(), "access.log")
	if err := run(io.Discard, io.Discard, 0, -1, size, path); err != nil {
		b.Fatal(err)
	}
	bench := func(name string, copyFile func(io.Writer, *os.File) error) {
		b.Run(name, func(b *testing.B) {
			b.SetBytes(size)
			var w countWriter
			for b.Loop() {
				f, err := os.Open(path)
				if err != nil {
					b.Fatal(err)
				}
				if err := copyFile(&w, f); err != nil {
					b.Fatal(err)
				}
				_ = f.Close()
			}
			b.ReportMetric(float64(w.MaxWrite), "B/write")
		})
	}
	for _, n := range []int{512, 4 << 10, 32 << 10, 256 << 10, 1 << 20} {
		bench("buf="+human(n), func(w io.Writer, f *os.File) error {
			// Hide *os.File's WriteTo method, or CopyBuffer ignores buf.
			_, err := io.CopyBuffer(w, struct{ io.Reader }{f}, make([]byte, n))
			return err
		})
	}
	bench("buf=1MiB-via-WriteTo", func(w io.Writer, f *os.File) error {
		_, err := io.CopyBuffer(w, f, make([]byte, 1<<20)) // f.WriteTo wins
		return err
	})
}

// END bench OMIT

func human(n int) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%dMiB", n>>20)
	case n >= 1<<10:
		return fmt.Sprintf("%dKiB", n>>10)
	}
	return fmt.Sprintf("%dB", n)
}
