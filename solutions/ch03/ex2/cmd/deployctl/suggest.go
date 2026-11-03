package main

import (
	"fmt"

	"deployctl/pkg/clierr"
)

// START unknown OMIT
// commands are the commands run knows, in the order usage lists them.
var commands = []string{"init", "deploy", "status"}

// unknownCommand is the usage error for a command that doesn't exist. When
// a real command is a typo away, the hint names it first.
func unknownCommand(cmd string) error {
	err := fmt.Errorf("unknown command %q", cmd)
	hint := `run "deployctl -h" for usage`
	if s := closest(cmd, commands, 2); s != "" {
		hint = fmt.Sprintf("did you mean %q? %s", s, hint)
	}
	return &clierr.Error{Code: clierr.ExitUsage, Message: err.Error(),
		Hint: hint, Err: err}
}

// END unknown OMIT
// START closest OMIT
// closest returns the candidate nearest to typed, if it is at most max
// edits away; on a tie, the first one wins. Otherwise it returns "".
func closest(typed string, candidates []string, maxEdits int) string {
	best, bestDist := "", maxEdits+1
	for _, c := range candidates {
		if d := distance(typed, c); d < bestDist {
			best, bestDist = c, d
		}
	}
	return best
}

// distance is the Levenshtein distance: the fewest one-byte insertions,
// deletions and substitutions that turn a into b. prev holds the
// distances from a[:i-1] to every prefix of b, cur those from a[:i].
func distance(a, b string) int {
	prev := make([]int, len(b)+1)
	for j := range prev {
		prev[j] = j // b[:j] from nothing: j insertions
	}
	for i := 1; i <= len(a); i++ {
		cur := make([]int, len(b)+1)
		cur[0] = i // nothing from a[:i]: i deletions
		for j := 1; j <= len(b); j++ {
			sub := prev[j-1]
			if a[i-1] != b[j-1] {
				sub++
			}
			cur[j] = min(prev[j]+1, cur[j-1]+1, sub)
		}
		prev = cur
	}
	return prev[len(b)]
}

// END closest OMIT
