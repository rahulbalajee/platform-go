// Package logline parses log lines of the form
//
//	TIME LEVEL SERVICE MESSAGE
//
// and keeps statistics about them.
package logline

import (
	"fmt"
	"strings"
	"time"
)

// START level OMIT

// Level is the severity of a log entry. A higher level is more severe,
// so levels can be compared with < and >.
type Level int

// The levels logline knows, from least to most severe. iota counts up
// from 0 inside a const block, so Debug is 0 and Error is 3.
const (
	Debug Level = iota
	Info
	Warn
	Error
)

// String returns the name of l as it appears in log files.
func (l Level) String() string {
	switch l {
	case Debug:
		return "DEBUG"
	case Info:
		return "INFO"
	case Warn:
		return "WARN"
	case Error:
		return "ERROR"
	}
	return fmt.Sprintf("Level(%d)", int(l))
}

// START solution OMIT

// aliases maps other names that programs use for a level, written in
// upper case, to the level.
var aliases = map[string]Level{
	"WARNING": Warn,
	"ERR":     Error,
}

// ParseLevel returns the level called name. It ignores case, so "warn"
// and "WARN" are the same level, and it accepts the names in aliases.
func ParseLevel(name string) (Level, error) {
	upper := strings.ToUpper(name)
	if l, ok := aliases[upper]; ok {
		return l, nil
	}
	for l := Debug; l <= Error; l++ {
		if upper == l.String() {
			return l, nil
		}
	}
	return 0, fmt.Errorf("unknown level %q", name)
}

// END solution OMIT

// END level OMIT

// START marshal OMIT

// MarshalText returns the name of l. encoding/json calls it, so a Level
// appears in JSON as "WARN" rather than as the number 2.
func (l Level) MarshalText() ([]byte, error) {
	return []byte(l.String()), nil
}

// END marshal OMIT

// START entry OMIT

// Entry is one parsed log line. The tags name the fields in JSON.
type Entry struct {
	Time    time.Time `json:"time"`
	Level   Level     `json:"level"`
	Service string    `json:"service"`
	Message string    `json:"message"`
}

// Parse parses a line of the form "TIME LEVEL SERVICE MESSAGE". The
// message is the rest of the line and may contain spaces. If the line
// is not a valid entry, the error is a *ParseError.
func Parse(line string) (Entry, error) {
	parts := strings.SplitN(line, " ", 4)
	if len(parts) < 4 {
		return Entry{}, &ParseError{Field: "line", Value: line}
	}
	t, err := time.Parse(time.RFC3339, parts[0])
	if err != nil {
		return Entry{}, &ParseError{Field: "time", Value: parts[0]}
	}
	level, err := ParseLevel(parts[1])
	if err != nil {
		return Entry{}, &ParseError{Field: "level", Value: parts[1]}
	}
	e := Entry{Time: t, Level: level, Service: parts[2], Message: parts[3]}
	return e, nil
}

// END entry OMIT

// START parseerror OMIT

// A ParseError reports a line that is not a valid log entry.
type ParseError struct {
	Field string // the part that is wrong: "line", "time" or "level"
	Value string // the text found where that part should be
}

// Error returns a message such as `bad time "yesterday"`. Having this
// method makes *ParseError satisfy the error interface.
func (e *ParseError) Error() string {
	return fmt.Sprintf("bad %s %q", e.Field, e.Value)
}

// END parseerror OMIT
