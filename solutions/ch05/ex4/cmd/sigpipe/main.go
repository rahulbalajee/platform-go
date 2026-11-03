// Command sigpipe writes numbered lines to stdout until something stops it.
// Pipe it into `head -n 3` to see how a Go program reacts when its reader
// goes away.
//
//	sigpipe | head -n 3                  # killed by SIGPIPE (status 141)
//	sigpipe -notify | head -n 3          # SIGPIPE becomes EPIPE errors...
//	sigpipe -notify -check | head -n 3   # ...which the program must check
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	notify := flag.Bool("notify", false,
		"subscribe to SIGPIPE, as some libraries do; writes then fail with EPIPE")
	check := flag.Bool("check", false, "stop quietly when a write fails with EPIPE")
	flag.Parse()
	if *notify {
		signal.Notify(make(chan os.Signal, 1), syscall.SIGPIPE)
	}
	// START loop OMIT
	failed := 0
	for i := 1; ; i++ {
		_, err := fmt.Println(i)
		if err == nil {
			continue
		}
		if *check && errors.Is(err, syscall.EPIPE) {
			os.Exit(0) // the reader is gone: not an error for a CLI
		}
		if failed++; failed == 1_000_000 { // without -check: spin forever
			fmt.Fprintf(os.Stderr, "%d writes failed (%v), still running\n",
				failed, err)
			os.Exit(1)
		}
	}
	// END loop OMIT
}
