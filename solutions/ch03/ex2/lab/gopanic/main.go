// Command gopanic shows that recover only stops a panic on its own
// goroutine. The deferred recover in main never runs: the worker's panic
// kills the process, and the exit status is 2.
package main

import (
	"fmt"
	"sync"
)

// START gopanic OMIT
func main() {
	defer func() {
		if v := recover(); v != nil {
			fmt.Println("recovered in main:", v) // never printed
		}
	}()

	var wg sync.WaitGroup
	wg.Go(func() {
		replicas := lookup("eu-west-1") // nil: the region isn't configured
		replicas["canary"]++            // panics on this goroutine, not main's
	})
	wg.Wait()
	fmt.Println("all workers done") // never printed either
}

// END gopanic OMIT

func lookup(string) map[string]int { return nil }
