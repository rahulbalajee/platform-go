// Package flaky collects deliberately broken tests that show how tests go
// wrong: state shared between tests, cleanup that runs too early for
// parallel subtests, and process-wide settings in parallel tests. The tests
// only build with the flakydemo tag, so go test ./... never runs them:
//
//	go test -tags flakydemo -shuffle=on ./examples/ch06/flaky
package flaky
