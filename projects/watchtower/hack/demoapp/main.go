// Command demoapp is a tiny HTTP service used as a probe target in the
// end-to-end demo. It needs no base image, so the demo runs offline.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	// /status/503 answers 503, like httpbin.org, for checks that must fail.
	mux.HandleFunc("GET /status/{code}", status)
	mux.HandleFunc("GET /", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "storefront")
	})
	srv := &http.Server{
		Addr: ":" + port, Handler: mux, ReadHeaderTimeout: 5 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

// status answers with the status code in the path.
func status(w http.ResponseWriter, r *http.Request) {
	code, err := strconv.Atoi(r.PathValue("code"))
	if err != nil || code < 200 || code > 599 {
		code = http.StatusBadRequest
	}
	w.WriteHeader(code)
}
