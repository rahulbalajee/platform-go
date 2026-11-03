package logline

// START imports OMIT
import (
	"errors"
	"testing"
	"time"
)

// END imports OMIT

// START parse OMIT
func TestParse(t *testing.T) {
	tests := []struct {
		name      string
		line      string
		want      Entry
		wantField string // if set, Parse must fail on this field
	}{
		{
			name: "info line",
			line: "2026-11-03T09:00:01Z INFO api listening on :8080",
			want: Entry{
				Time:    time.Date(2026, 11, 3, 9, 0, 1, 0, time.UTC),
				Level:   Info,
				Service: "api",
				Message: "listening on :8080",
			},
		},
		{
			name: "lowercase level",
			line: "2026-11-03T09:02:41Z error db connection reset",
			want: Entry{
				Time:    time.Date(2026, 11, 3, 9, 2, 41, 0, time.UTC),
				Level:   Error,
				Service: "db",
				Message: "connection reset",
			},
		},
		{name: "too few fields", line: "2026-11-03T09:04", wantField: "line"},
		{name: "bad time", line: "this is not a log entry", wantField: "time"},
		{name: "bad level", line: "2026-11-03T09:00:01Z HI x y", wantField: "level"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Parse(tt.line)
			if tt.wantField != "" {
				var perr *ParseError
				if !errors.As(err, &perr) || perr.Field != tt.wantField {
					t.Fatalf("Parse(%q) error = %v, want a bad %s",
						tt.line, err, tt.wantField)
				}
				return
			}
			if err != nil {
				t.Fatalf("Parse(%q) returned error: %v", tt.line, err)
			}
			if got != tt.want {
				t.Errorf("Parse(%q)\n got %v\nwant %v", tt.line, got, tt.want)
			}
		})
	}
}

// END parse OMIT

// START level OMIT
func TestParseLevel(t *testing.T) {
	tests := []struct {
		name string
		want Level
	}{
		{"DEBUG", Debug},
		{"info", Info},
		{"Warn", Warn},
		{"ERROR", Error},
	}
	for _, tt := range tests {
		got, err := ParseLevel(tt.name)
		if err != nil || got != tt.want {
			t.Errorf("ParseLevel(%q) = %v, %v; want %v, nil",
				tt.name, got, err, tt.want)
		}
	}
	if _, err := ParseLevel("NOTICE"); err == nil {
		t.Error(`ParseLevel("NOTICE") returned no error`)
	}
}

// END level OMIT
