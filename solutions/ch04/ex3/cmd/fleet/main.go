// Command fleet serves a fake fleet of HTTP endpoints, so you can try sweep
// on your own machine. Each path behaves like a different kind of service:
//
//	/ok       200 OK
//	/slow     no answer for 10 seconds, or until the client gives up
//	/flaky    502 Bad Gateway twice, then 200 OK, then the same again
//	/down     503 Service Unavailable
//	/busy     429 Too Many Requests, with Retry-After: 1
//	anything else: 404 Not Found
//
// It logs every request it answers, so you can watch sweep's traffic.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"sync/atomic"
	"time"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8099", "address to listen on")
	flag.Parse()

	mux := http.NewServeMux()
	handle := func(pattern string, h http.HandlerFunc) {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			log.Print(pattern)
			h(w, r)
		})
	}
	handle("GET /ok", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	handle("GET /slow", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(10 * time.Second):
			fmt.Fprintln(w, "finally")
		case <-r.Context().Done(): // the client gave up and hung up
		}
	})
	var flakyCalls atomic.Int64
	handle("GET /flaky", func(w http.ResponseWriter, _ *http.Request) {
		if flakyCalls.Add(1)%3 != 0 {
			http.Error(w, "warming up", http.StatusBadGateway)
			return
		}
		fmt.Fprintln(w, "ok")
	})
	handle("GET /down", func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "maintenance", http.StatusServiceUnavailable)
	})
	handle("GET /busy", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "1")
		http.Error(w, "slow down", http.StatusTooManyRequests)
	})

	srv := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.Printf("fleet listening on http://%s", *addr)
	log.Fatal(srv.ListenAndServe())
}
