package procx

import (
	"bytes"
	"io"
	"sync"
)

// START prefix OMIT
// PrefixWriter writes everything written to it to an underlying writer,
// one complete line at a time, with a prefix in front of each line. Use it
// to label the output of child processes:
//
//	cmd.Stdout = procx.NewPrefixWriter(os.Stdout, "[terraform] ")
//
// It is safe for concurrent use. Call Flush after the last Write to emit a
// final line that has no newline.
type PrefixWriter struct {
	mu     sync.Mutex
	w      io.Writer
	prefix []byte
	buf    []byte // a line that has not ended yet
}

// NewPrefixWriter returns a PrefixWriter that writes to w.
func NewPrefixWriter(w io.Writer, prefix string) *PrefixWriter {
	return &PrefixWriter{w: w, prefix: []byte(prefix)}
}

// Write buffers p and writes every line it completes. It returns len(p)
// unless the underlying writer fails.
func (pw *PrefixWriter) Write(p []byte) (int, error) {
	pw.mu.Lock()
	defer pw.mu.Unlock()
	pw.buf = append(pw.buf, p...)
	for {
		i := bytes.IndexByte(pw.buf, '\n')
		if i < 0 {
			return len(p), nil
		}
		if err := pw.emit(pw.buf[:i+1]); err != nil {
			return 0, err
		}
		pw.buf = pw.buf[i+1:]
	}
}

// Flush writes a pending partial line, ending it with a newline.
func (pw *PrefixWriter) Flush() error {
	pw.mu.Lock()
	defer pw.mu.Unlock()
	if len(pw.buf) == 0 {
		return nil
	}
	line := append(pw.buf, '\n') //nolint:gocritic // buf is dropped next
	pw.buf = nil
	return pw.emit(line)
}

// emit writes prefix and line with a single Write, so lines from several
// PrefixWriters sharing one destination do not interleave mid-line.
func (pw *PrefixWriter) emit(line []byte) error {
	out := make([]byte, 0, len(pw.prefix)+len(line))
	out = append(append(out, pw.prefix...), line...)
	_, err := pw.w.Write(out)
	return err
}

// END prefix OMIT
