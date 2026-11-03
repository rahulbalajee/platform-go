// START lines OMIT

package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"iter"
	"strings"
)

// Line is one line of input, without its newline.
type Line struct {
	Bytes     []byte // only valid until the next iteration
	Truncated bool   // the line was longer than max; Bytes holds its start
}

// Lines yields the lines of r using fixed buffers of max bytes, however
// long the input or its lines are. A longer line is cut to max bytes and
// the rest of it is skipped, so one bad line cannot stop the scan.
func Lines(r io.Reader, max int) iter.Seq2[Line, error] {
	return func(yield func(Line, error) bool) {
		br := bufio.NewReaderSize(r, max)
		long := make([]byte, 0, max) // keeps the start of an over-long line
		for {
			b, err := br.ReadSlice('\n') // a view into br's buffer: no copy
			line := Line{Bytes: b}
			if errors.Is(err, bufio.ErrBufferFull) {
				line = Line{Bytes: append(long[:0], b...), Truncated: true}
				for errors.Is(err, bufio.ErrBufferFull) { // skip the rest
					_, err = br.ReadSlice('\n')
				}
			}
			if err != nil && !errors.Is(err, io.EOF) {
				yield(Line{}, err)
				return
			}
			if len(line.Bytes) > 0 {
				line.Bytes = bytes.TrimSuffix(line.Bytes, []byte("\n"))
				if !yield(line, nil) {
					return
				}
			}
			if err != nil { // io.EOF
				return
			}
		}
	}
}

// END lines OMIT

// START scan OMIT
// scan streams one log through Lines. Memory use is the line buffer plus
// whatever the reader needs, whatever the size of the input.
func scan(r io.Reader, maxLine int) (Stats, error) {
	var st Stats
	for line, err := range Lines(r, maxLine) {
		if err != nil {
			return st, err
		}
		if line.Truncated {
			st.Truncated++
		}
		st.add(line.Bytes)
	}
	return st, nil
}

// END scan OMIT

// START scanfs OMIT
// scanFS scans every file in fsys that matches pattern, decompressing
// names ending in .gz on the fly.
func scanFS(fsys fs.FS, pattern string, maxLine int) (Stats, error) {
	names, err := fs.Glob(fsys, pattern)
	if err != nil {
		return Stats{}, err
	}
	var total Stats
	for _, name := range names {
		st, err := scanFile(fsys, name, maxLine)
		if err != nil {
			return total, fmt.Errorf("%s: %w", name, err)
		}
		total.merge(st)
	}
	return total, nil
}

// scanFile scans one file, adding a gzip reader for names ending in .gz.
func scanFile(fsys fs.FS, name string, maxLine int) (Stats, error) {
	f, err := fsys.Open(name)
	if err != nil {
		return Stats{}, err
	}
	defer f.Close()
	var r io.Reader = f
	if strings.HasSuffix(name, ".gz") {
		zr, err := gzip.NewReader(bufio.NewReaderSize(f, 64<<10))
		if err != nil {
			return Stats{}, err
		}
		defer zr.Close()
		r = zr
	}
	return scan(r, maxLine)
}

// END scanfs OMIT
