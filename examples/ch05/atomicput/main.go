// Command atomicput copies standard input to a file atomically: readers of
// the file see the old contents or the new, never a partial write, and the
// new contents are on disk when it exits 0.
//
//	render-config | atomicput /etc/myapp/config.json
package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/rahulbalajee/platform-go/pkg/fsx"
)

// START put OMIT
func main() {
	limit := flag.Int64("max", 16<<20, "refuse input larger than this many bytes")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: atomicput [-max N] FILE < data")
		os.Exit(2)
	}
	err := fsx.Write(flag.Arg(0), 0o644, func(w io.Writer) error {
		// Read at most limit+1 bytes: one byte more tells us the input was
		// too big, without ever buffering an unbounded stream.
		n, err := io.Copy(w, io.LimitReader(os.Stdin, *limit+1))
		if err == nil && n > *limit {
			err = fmt.Errorf("input exceeds %d bytes", *limit)
		}
		return err
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "atomicput:", err)
		os.Exit(1)
	}
}

// END put OMIT
