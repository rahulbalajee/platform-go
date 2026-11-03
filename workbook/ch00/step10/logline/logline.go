// Package logline parses log lines of the form
//
//	TIME LEVEL SERVICE MESSAGE
//
// and keeps statistics about them.
package logline

import (
	"errors"
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

// START entry OMIT

// Entry is one parsed log line.
type Entry struct {
	Time    time.Time
	Level   Level
	Service string
	Message string
}

// Parse parses a line of the form "TIME LEVEL SERVICE MESSAGE". The
// message is the rest of the line and may contain spaces.
func Parse(line string) (Entry, error) {
	parts := strings.SplitN(line, " ", 4)
	if len(parts) < 4 {
		return Entry{}, errors.New("want TIME LEVEL SERVICE MESSAGE")
	}
	t, err := time.Parse(time.RFC3339, parts[0])
	if err != nil {
		return Entry{}, fmt.Errorf("bad time %q", parts[0])
	}
	level, err := ParseLevel(parts[1])
	if err != nil {
		return Entry{}, err
	}
	e := Entry{Time: t, Level: level, Service: parts[2], Message: parts[3]}
	return e, nil
}

// END entry OMIT
