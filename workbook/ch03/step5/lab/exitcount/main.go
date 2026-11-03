// Command exitcount shows why an exit status must be a small constant:
// the kernel keeps only the low 8 bits, so 256 failures look like success.
package main

import (
	"fmt"
	"os"
)

// START exitcount OMIT
func main() {
	failed := 256 // one per unhealthy pod in a large cluster
	fmt.Fprintf(os.Stderr, "%d health checks failed\n", failed)
	os.Exit(failed) // don't: the parent sees failed % 256
}

// END exitcount OMIT
