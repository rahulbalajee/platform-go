package fsx

import (
	"errors"
	"fmt"
	"io"
	"os"
)

// ErrTooLarge is returned by ReadFileLimit for a file over its limit.
var ErrTooLarge = errors.New("file too large")

// START readlimit OMIT
// ReadFileLimit reads the whole file name, like os.ReadFile, but refuses a
// file with more than limit bytes. It reads at most limit+1 bytes, so an
// endless input (a FIFO, /dev/zero, a log being written) cannot exhaust
// memory.
func ReadFileLimit(name string, limit int64) ([]byte, error) {
	f, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, limit+1)) // one more byte: too big
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", name, err)
	}
	if int64(len(b)) > limit {
		return nil, fmt.Errorf("%s: %w (over %d bytes)", name, ErrTooLarge, limit)
	}
	return b, nil
}

// END readlimit OMIT
