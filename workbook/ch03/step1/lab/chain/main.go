// START head OMIT
// Command chain shows how errors.Is and errors.As see a wrapped error.
package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
)

// END head OMIT
// START wrap OMIT
func wrapping() {
	// A real error from the OS: *fs.PathError wrapping syscall.ENOENT.
	_, err := os.Open("/etc/deployctl/deployctl.json")

	wrapped := fmt.Errorf("load config: %w", err)
	flattened := fmt.Errorf("load config: %v", err) //nolint:errorlint // on purpose

	fmt.Println(wrapped)
	fmt.Println("Is(wrapped, fs.ErrNotExist)   =", errors.Is(wrapped, fs.ErrNotExist))
	fmt.Println("Is(flattened, fs.ErrNotExist) =",
		errors.Is(flattened, fs.ErrNotExist))
}

// END wrap OMIT
// START main OMIT
func main() {
	wrapping()
}

// END main OMIT
