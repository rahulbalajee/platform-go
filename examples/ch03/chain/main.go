// START head OMIT
// Command chain shows how errors.Is, errors.As and errors.AsType see a
// wrapped error, and how they walk the tree that errors.Join and multiple
// %w verbs build.
package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
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

	var pe *fs.PathError         // errors.As: declare a target, pass its address
	if errors.As(wrapped, &pe) { //nolint:modernize // the pre-1.26 form
		fmt.Println("As:     op =", pe.Op, " path =", pe.Path)
	}
	if pe, ok := errors.AsType[*fs.PathError](wrapped); ok { // Go 1.26
		fmt.Println("AsType: op =", pe.Op, " cause =", pe.Err)
	}
}

// END wrap OMIT
// START tree OMIT
func trees(cfgErr error) {
	tree := fmt.Errorf("deploy v1.4.2: %w", errors.Join(
		fmt.Errorf("us-east-1: %w", context.DeadlineExceeded),
		fmt.Errorf("eu-west-1: %w; %w", errors.ErrUnsupported, cfgErr),
	))
	walk(tree, 0)
	fmt.Println("Is(tree, DeadlineExceeded) =",
		errors.Is(tree, context.DeadlineExceeded))
	fmt.Println("Is(tree, fs.ErrNotExist)   =", errors.Is(tree, fs.ErrNotExist))
}

// END tree OMIT
// START walk OMIT
// walk prints the tree in the order errors.Is and errors.As visit it.
func walk(err error, depth int) {
	fmt.Printf("%s%T\n", strings.Repeat("  ", depth), err)
	switch x := err.(type) { //nolint:errorlint // walking the tree by hand
	case interface{ Unwrap() error }:
		walk(x.Unwrap(), depth+1)
	case interface{ Unwrap() []error }:
		for _, e := range x.Unwrap() {
			walk(e, depth+1)
		}
	}
}

// END walk OMIT
// START main OMIT
// main runs one part: "wrap" (the default) or "tree".
func main() {
	_, err := os.Open("/etc/deployctl/deployctl.json")
	cfgErr := fmt.Errorf("load config: %w", err)
	if len(os.Args) > 1 && os.Args[1] == "tree" {
		trees(cfgErr)
		return
	}
	wrapping()
}

// END main OMIT
