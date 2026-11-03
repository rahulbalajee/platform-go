package main

import "bytes"

// countWriter is an io.Writer that keeps statistics instead of bytes.
type countWriter struct {
	Bytes, Lines int64
	MaxWrite     int // the largest single Write: the chunk size the caller used
}

// Write counts p. A Writer returns len(p) and a nil error unless it failed;
// returning less makes io.Copy stop with io.ErrShortWrite.
func (c *countWriter) Write(p []byte) (int, error) {
	c.Bytes += int64(len(p))
	c.Lines += int64(bytes.Count(p, []byte("\n")))
	c.MaxWrite = max(c.MaxWrite, len(p))
	return len(p), nil
}
