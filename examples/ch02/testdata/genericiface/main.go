// This package does not compile, on purpose: Chapter 2 shows the error
// the compiler reports when a generic method meets an interface. It lives
// under testdata so that ./... patterns skip it.
package main

import (
	"context"

	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

type waiter interface {
	Wait(ctx context.Context, op *platformapi.Operation[platformapi.Deployment],
		opts ...platformapi.CallOption) (*platformapi.Deployment, error)
}

var _ waiter = (*platformapi.Client)(nil)

func main() {}
