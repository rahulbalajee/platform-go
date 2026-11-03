// START doc OMIT

// Package platformapi is the Go client for the internal platform API:
// environments, services, and deployments.
//
// Create one [Client] per process with [New] and share it; it is safe for
// concurrent use. Every method takes a [context.Context] as its first
// argument, and the context bounds the call, including retries.
//
//	client, err := platformapi.New("https://platform.internal",
//		platformapi.WithTokenSource(tokens),
//		platformapi.WithUserAgent("ship/2.3.0"),
//	)
//
// List methods return iterators that fetch pages on demand. Creating a
// deployment returns an [Operation]; [Client.Wait] polls it to completion.
// Errors returned by the API are [*APIError] values, and [errors.Is]
// reports [ErrNotFound] and [ErrConflict] for the matching status codes.
//
// Package platformapifake provides an in-memory server for tests.
package platformapi

// END doc OMIT
