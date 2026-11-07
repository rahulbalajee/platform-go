package main_test

import (
	"net/http"
	"sync/atomic"

	"github.com/rahulbalajee/platform-go/internal/platformd"
)

// lateHandler serves the platform stored in it at request time, so a test
// can start the listener (and learn its URL, the issuer) before building
// the platform that needs that URL. The pointer is atomic because the
// listener's goroutines read it while the test goroutine sets it.
type lateHandler struct {
	srv atomic.Pointer[platformd.Server]
}

func (h *lateHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.srv.Load().ServeHTTP(w, r)
}
