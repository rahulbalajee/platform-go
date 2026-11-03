// Package match decides which log entries a query selects.
package match

import (
	"fmt"
	"regexp"
	"strings"

	"logq/logline"
)

// START matcher OMIT

// A Matcher reports whether a log entry should be selected.
type Matcher interface {
	Match(e logline.Entry) bool
}

// END matcher OMIT

// START impls OMIT

// MinLevel selects entries at a level or above it.
type MinLevel logline.Level

// Match reports whether e is at least as severe as m.
func (m MinLevel) Match(e logline.Entry) bool {
	return e.Level >= logline.Level(m)
}

// Contains selects entries whose message contains a piece of text.
type Contains string

// Match reports whether the message of e contains m.
func (m Contains) Match(e logline.Entry) bool {
	return strings.Contains(e.Message, string(m))
}

// Regexp selects entries whose message matches a regular expression.
type Regexp struct {
	re *regexp.Regexp
}

// NewRegexp compiles expr. It returns an error if expr is not a valid
// regular expression.
func NewRegexp(expr string) (*Regexp, error) {
	re, err := regexp.Compile(expr)
	if err != nil {
		return nil, err
	}
	return &Regexp{re: re}, nil
}

// Match reports whether the message of e matches the expression.
func (m *Regexp) Match(e logline.Entry) bool {
	return m.re.MatchString(e.Message)
}

// END impls OMIT

// START all OMIT

// All selects the entries that every matcher in it selects. An empty
// All selects every entry.
type All []Matcher

// Match reports whether every matcher in a selects e.
func (a All) Match(e logline.Entry) bool {
	for _, m := range a {
		if !m.Match(e) {
			return false
		}
	}
	return true
}

// Func turns an ordinary function into a Matcher.
type Func func(e logline.Entry) bool

// Match calls f(e).
func (f Func) Match(e logline.Entry) bool {
	return f(e)
}

// END all OMIT

// START solution OMIT

// Not returns a Matcher that selects the entries m does not select.
func Not(m Matcher) Matcher {
	return not{m: m}
}

// not is the Matcher that Not returns. It wraps another Matcher and
// turns its answer around.
type not struct {
	m Matcher
}

// Match reports whether the wrapped matcher rejects e.
func (n not) Match(e logline.Entry) bool {
	return !n.m.Match(e)
}

// END solution OMIT

// START describe OMIT

// Describe returns a short description of m for people to read.
func Describe(m Matcher) string {
	switch m := m.(type) {
	case MinLevel:
		return "level>=" + logline.Level(m).String()
	case Contains:
		return fmt.Sprintf("message contains %q", string(m))
	case *Regexp:
		return fmt.Sprintf("message matches /%s/", m.re)
	case not:
		return "not (" + Describe(m.m) + ")"
	case All:
		if len(m) == 0 {
			return "everything"
		}
		parts := make([]string, len(m))
		for i, sub := range m {
			parts[i] = Describe(sub)
		}
		return strings.Join(parts, " and ")
	default:
		return fmt.Sprintf("%T", m)
	}
}

// END describe OMIT
