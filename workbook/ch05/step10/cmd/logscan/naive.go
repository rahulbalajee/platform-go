package main

import (
	"bufio"
	"bytes"
	"io"
)

// START naive OMIT
// scanReadAll is the version that works on every test file and then pages
// someone: it holds the whole input in memory, plus a slice header for
// every line.
func scanReadAll(r io.Reader) (Stats, error) {
	var st Stats
	data, err := io.ReadAll(r)
	if err != nil {
		return st, err
	}
	data = bytes.TrimSuffix(data, []byte("\n"))
	//nolint:modernize // naive on purpose: SplitSeq would avoid the [][]byte
	for _, line := range bytes.Split(data, []byte("\n")) {
		st.add(line)
	}
	return st, nil
}

// scanScanner has the classic bufio.Scanner bug: a line longer than the
// 64 KiB default token size stops the loop, and nobody asks why.
func scanScanner(r io.Reader) (Stats, error) {
	var st Stats
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		st.add(sc.Bytes())
	}
	return st, nil // BUG: sc.Err() is bufio.ErrTooLong, and it is dropped
}

// END naive OMIT
