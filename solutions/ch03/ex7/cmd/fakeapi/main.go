// Command fakeapi serves the fake deployment API on a local address, so
// deployctl can be run by hand against it. It logs every request it gets.
package main

import (
	"flag"
	"log"
	"net/http"
	"time"

	"deployctl/internal/fakeapi"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8787", "listen address")
	flag.Parse()
	log.SetFlags(log.Ltime | log.Lmicroseconds)

	api := fakeapi.New(fakeapi.Options{})
	srv := &http.Server{
		Addr: *addr,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// %q escapes control characters, so a path can't forge a line.
			log.Printf("%s %q", r.Method, r.URL.Path) //nolint:gosec // see above
			api.ServeHTTP(w, r)
		}),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("fake deploy API on http://%s", *addr)
	log.Fatal(srv.ListenAndServe())
}
