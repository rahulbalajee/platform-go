// Package containers tests sweep's probers against real services running in
// Docker containers, with testcontainers-go. It is a separate module so the
// Docker client and its dependencies stay out of the root module.
//
// Every test skips when no Docker daemon is reachable, and in -short mode:
//
//	go test ./...          # needs Docker
//	go test -short ./...   # skips everything here
package containers
