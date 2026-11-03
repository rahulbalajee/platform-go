// Package sweepscript holds the end-to-end tests for the sweep binary,
// written as testscript (txtar) scripts in testdata/script.
//
// It is a separate module so that testscript's dependencies stay out of the
// root module. TestMain asks the go command where cmd/sweep lives, builds it
// there (with -cover when GOCOVERDIR is set), and puts it on $PATH; each
// script then runs against a fake fleet started for that script:
//
//	go test ./...                       # run every script
//	go test -run 'TestScripts/^exit'    # run one script
//	go test -update                     # rewrite cmp files inside scripts
//	GOCOVERDIR=/tmp/cov go test ./...   # also collect coverage from sweep
package sweepscript
