// START imports OMIT

// Command torn rewrites a config file in a loop while another goroutine
// reads it, and counts how often the reader sees something that is neither
// the old version nor the new one.
//
//	torn -mode naive    # os.WriteFile: truncate, then write in place
//	torn -mode atomic   # fsx.WriteFile: temp file, fsync, rename
package main

import (
	"bytes"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/fsx"
)

// END imports OMIT

// START main OMIT
func main() {
	mode := flag.String("mode", "naive", "how to write: naive or atomic")
	dur := flag.Duration("for", 2*time.Second, "how long to run")
	flag.Parse()
	if err := run(*mode, *dur); err != nil {
		fmt.Fprintln(os.Stderr, "torn:", err)
		os.Exit(1)
	}
}

// END main OMIT

// START writer OMIT
// writeFunc has the signature of os.WriteFile.
type writeFunc func(name string, data []byte, perm fs.FileMode) error

func writer(mode string) (writeFunc, error) {
	switch mode {
	case "naive":
		return os.WriteFile, nil // truncate, then write: readers see the gap
	case "atomic":
		return fsx.WriteFile, nil // a new file, renamed over the old one
	}
	return nil, fmt.Errorf("unknown -mode %q", mode)
}

// END writer OMIT

// START run OMIT
func run(mode string, dur time.Duration) error {
	write, err := writer(mode)
	if err != nil {
		return err
	}
	dir, err := os.MkdirTemp("", "torn-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	name := filepath.Join(dir, "routes.json")
	v1, v2 := payload('1'), payload('2')
	if err := write(name, v1, 0o600); err != nil {
		return err
	}

	var stop atomic.Bool
	var reads, empty, short, mixed int // owned by the reader until wg.Wait
	var wg sync.WaitGroup
	wg.Go(func() { // the reader: a service polling its config file
		for !stop.Load() {
			b, err := os.ReadFile(name)
			reads++
			switch {
			case err != nil || len(b) == 0:
				empty++
			case len(b) < len(v1):
				short++
			case !bytes.Equal(b, v1) && !bytes.Equal(b, v2):
				mixed++
			}
		}
	})
	writes := 0
	for deadline := time.Now().Add(dur); time.Now().Before(deadline); writes++ {
		if err := write(name, [][]byte{v1, v2}[writes%2], 0o600); err != nil {
			stop.Store(true)
			wg.Wait()
			return err
		}
	}
	stop.Store(true)
	wg.Wait()
	fmt.Printf("%-6s writes=%-6d reads=%-7d torn=%d (empty %d, short %d, mixed %d)\n",
		mode, writes, reads, empty+short+mixed, empty, short, mixed)
	return nil
}

// END run OMIT

// START payload OMIT
// payload is a 256 KiB JSON-ish document whose every byte names its version.
func payload(version byte) []byte {
	b := bytes.Repeat([]byte{version}, 256<<10)
	b[0], b[len(b)-1] = '{', '}'
	return b
}

// END payload OMIT
