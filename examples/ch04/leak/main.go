// Command leak demonstrates the goroutineleak profile (GA in Go 1.27): the
// classic "early return abandons senders on an unbuffered channel" bug.
package main

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"runtime/pprof"
	"time"
)

// START leak OMIT
// checkAll fans out one goroutine per host and returns on the first error.
// The bug: the remaining senders block forever on the unbuffered channel.
func checkAll(hosts []string) error {
	errc := make(chan error) // unbuffered
	for _, h := range hosts {
		go func() { errc <- check(h) }()
	}
	for range hosts {
		if err := <-errc; err != nil {
			return err // early return: len(hosts)-1 senders may now be stuck
		}
	}
	return nil
}

// END leak OMIT

func check(h string) error {
	time.Sleep(10 * time.Millisecond)
	if h == "db-1" {
		return errors.New(h + ": connection refused")
	}
	time.Sleep(50 * time.Millisecond) // the healthy hosts answer later
	return nil
}

func main() {
	fmt.Println("checkAll:", checkAll([]string{"db-1", "api-1", "api-2", "cache-1"}))
	time.Sleep(200 * time.Millisecond) // let the healthy checks finish (and block)
	runtime.GC()
	fmt.Println("goroutines:", runtime.NumGoroutine())
	if p := pprof.Lookup("goroutineleak"); p != nil {
		_ = p.WriteTo(os.Stdout, 1)
	} else {
		fmt.Println("goroutineleak profile not available")
	}
}
