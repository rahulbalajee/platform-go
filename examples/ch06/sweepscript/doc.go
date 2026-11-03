// Package sweepscript holds the end-to-end tests for the sweep binary,
// written as testscript (txtar) scripts in testdata/script.
//
// It is a separate module so that testscript's dependencies stay out of the
// root module. The tests build cmd/sweep from the root module, put it on
// $PATH, and run each script against a fake fleet started for that script:
//
//	go test ./...                       # run every script
//	go test -run 'TestScripts/^exit'    # run one script
//	go test -update                     # rewrite cmp files inside scripts
//	GOCOVERDIR=/tmp/cov go test ./...   # also collect coverage from sweep
package sweepscript
