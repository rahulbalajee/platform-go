// Command nodowngrade is a pre-deploy check for plat, built as a
// WebAssembly module:
//
//	GOOS=wasip1 GOARCH=wasm go build -o nodowngrade.wasm .
//
// It refuses a deployment that would replace the version live in an
// environment with an older one, unless the reason says it is a rollback.
// The same program runs natively, which is how it is tested:
//
//	go run . < deployment.json
package main

// START main OMIT

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// input is the part of plat's check input (policy.Input) this check reads.
// A check declares its own types: it is another team's program, in a
// module, or a language, of its own.
type input struct {
	Request struct {
		Environment string `json:"environment"`
		Version     string `json:"version"`
		Reason      string `json:"reason"`
	} `json:"request"`
	History []struct {
		Environment string `json:"environment"`
		Version     string `json:"version"`
		State       string `json:"state"`
	} `json:"history"`
}

func main() {
	var in input
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		fmt.Fprintln(os.Stderr, "nodowngrade:", err)
		os.Exit(2) // not 1: a broken input is an error, not a refusal
	}
	if msg := check(in); msg != "" {
		fmt.Println(msg)
		os.Exit(1)
	}
}

// check returns why the deployment is refused, or "" to allow it.
func check(in input) string {
	if strings.HasPrefix(strings.ToLower(in.Request.Reason), "rollback") {
		return ""
	}
	for _, d := range in.History { // newest first: the first success is live
		if d.Environment != in.Request.Environment || d.State != "succeeded" {
			continue
		}
		if older(in.Request.Version, d.Version) {
			return fmt.Sprintf("%s is older than %s, which is live in %s; "+
				"to roll back on purpose, give --reason \"rollback: ...\"",
				in.Request.Version, d.Version, d.Environment)
		}
		return ""
	}
	return ""
}

// older reports whether version a sorts before b, for versions of the
// form vMAJOR.MINOR.PATCH. Anything else is never "older": this check
// refuses downgrades, it does not police version names.
func older(a, b string) bool {
	x, okA := parse(a)
	y, okB := parse(b)
	if !okA || !okB {
		return false
	}
	for i := range x {
		if x[i] != y[i] {
			return x[i] < y[i]
		}
	}
	return false
}

func parse(v string) ([3]int, bool) {
	var n [3]int
	parts := strings.Split(strings.TrimPrefix(v, "v"), ".")
	if len(parts) != 3 || !strings.HasPrefix(v, "v") {
		return n, false
	}
	for i, p := range parts {
		x, err := strconv.Atoi(p)
		if err != nil || x < 0 {
			return n, false
		}
		n[i] = x
	}
	return n, true
}

// END main OMIT
