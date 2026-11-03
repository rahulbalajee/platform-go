// This file is deliberately wrong: go vet in Go 1.27 reports the %w below.
// It lives in testdata so `go build ./...` and `go vet ./...` skip it.
package main

import (
	"errors"
	"fmt"
)

// START ptrwrap OMIT
// QuotaError has a value receiver, so callers match it as QuotaError.
type QuotaError struct{ Limit int }

func (e QuotaError) Error() string {
	return fmt.Sprintf("quota of %d deploys per hour exceeded", e.Limit)
}

func main() {
	err := fmt.Errorf("deploy: %w", &QuotaError{Limit: 10}) // a *QuotaError
	_, ok := errors.AsType[QuotaError](err)
	fmt.Println("found QuotaError:", ok) // false
}

// END ptrwrap OMIT
