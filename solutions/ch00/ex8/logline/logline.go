// Package logline parses log lines of the form
//
//	TIME LEVEL SERVICE MESSAGE
//
// and keeps statistics about them.
package logline

import (
	"encoding/json"
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

// ParseLevel returns the level called name. It ignores case, so "warn"
// and "WARN" are the same level.
func ParseLevel(name string) (Level, error) {
	for l := Debug; l <= Error; l++ {
		if strings.EqualFold(name, l.String()) {
			return l, nil
		}
	}
	return 0, fmt.Errorf("unknown level %q", name)
}

// END level OMIT

// START marshal OMIT

// MarshalText returns the name of l. encoding/json calls it, so a Level
// appears in JSON as "WARN" rather than as the number 2.
func (l Level) MarshalText() ([]byte, error) {
	return []byte(l.String()), nil
}

// END marshal OMIT

// START unmarshal OMIT

// UnmarshalText sets l to the level named by text. encoding/json calls
// it when it decodes a Level, so "WARN" in JSON becomes Warn.
func (l *Level) UnmarshalText(text []byte) error {
	parsed, err := ParseLevel(string(text))
	if err != nil {
		return err
	}
	*l = parsed
	return nil
}

// END unmarshal OMIT

// START entry OMIT

// Entry is one parsed log line. The tags name the fields in JSON.
type Entry struct {
	Time    time.Time `json:"time"`
	Level   Level     `json:"level"`
	Service string    `json:"service"`
	Message string    `json:"message"`
}

// START parse OMIT

// Parse parses a line of the form "TIME LEVEL SERVICE MESSAGE", or a
// JSON object with the fields time, level, service and message. In the
// first form the message is the rest of the line and may contain spaces.
// If the line is not a valid entry, the error is a *ParseError.
func Parse(line string) (Entry, error) {
	if strings.HasPrefix(line, "{") {
		return parseJSON(line)
	}
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

// parseJSON parses an entry written as a JSON object. It decodes the
// fields as plain strings first, so that a bad time or level is reported
// as a ParseError for that field, as it is for text lines.
func parseJSON(line string) (Entry, error) {
	var raw struct {
		Time    string `json:"time"`
		Level   string `json:"level"`
		Service string `json:"service"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal([]byte(line), &raw); err != nil {
		return Entry{}, &ParseError{Field: "json", Value: line}
	}
	t, err := time.Parse(time.RFC3339, raw.Time)
	if err != nil {
		return Entry{}, &ParseError{Field: "time", Value: raw.Time}
	}
	level, err := ParseLevel(raw.Level)
	if err != nil {
		return Entry{}, &ParseError{Field: "level", Value: raw.Level}
	}
	e := Entry{Time: t, Level: level, Service: raw.Service, Message: raw.Message}
	return e, nil
}

// END parse OMIT

// END entry OMIT

// START parseerror OMIT

// A ParseError reports a line that is not a valid log entry.
type ParseError struct {
	Field string // the part that is wrong: "line", "json", "time" or "level"
	Value string // the text found where that part should be
}

// Error returns a message such as `bad time "yesterday"`. Having this
// method makes *ParseError satisfy the error interface.
func (e *ParseError) Error() string {
	return fmt.Sprintf("bad %s %q", e.Field, e.Value)
}

// END parseerror OMIT
