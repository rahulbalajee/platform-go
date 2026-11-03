// Command httppanic shows what net/http does when a handler panics: the
// server recovers, logs the panic with a stack trace to its ErrorLog, and
// drops the connection, so the client sees a transport error rather than a
// status code. Panicking with http.ErrAbortHandler does the same without
// the log entry.
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
)

// START httppanic OMIT
func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/boom", func(http.ResponseWriter, *http.Request) {
		replicas := lookup("eu-west-1") // nil for an unknown region
		replicas["canary"]++            // a bug: panics inside the handler
	})
	mux.HandleFunc("/abort", func(http.ResponseWriter, *http.Request) {
		panic(http.ErrAbortHandler) // abort quietly: no stack in the log
	})
	srv := httptest.NewUnstartedServer(mux)
	srv.Config.ErrorLog = log.New(&firstLine{os.Stdout}, "server: ", 0)
	srv.Start()
	defer srv.Close()

	for _, path := range []string{"/boom", "/abort"} {
		req, _ := http.NewRequestWithContext(context.Background(),
			http.MethodGet, srv.URL+path, nil)
		resp, err := srv.Client().Do(req)
		if err == nil {
			resp.Body.Close()
		}
		fmt.Printf("client: GET %s: response=%t err=%v\n", path, resp != nil,
			strings.ReplaceAll(fmt.Sprint(err), srv.URL, "URL"))
	}
}

// END httppanic OMIT

func lookup(string) map[string]int { return nil }

// firstLine prints the first line of each log entry and counts the rest,
// so the stack trace net/http logs doesn't fill the page.
type firstLine struct{ w *os.File }

func (f *firstLine) Write(p []byte) (int, error) {
	lines := strings.Split(strings.TrimSpace(string(p)), "\n")
	_, err := fmt.Fprintf(f.w, "%s\n  [%d more lines of stack trace]\n",
		lines[0], len(lines)-1)
	return len(p), err
}
