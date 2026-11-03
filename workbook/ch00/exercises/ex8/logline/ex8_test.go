package logline

import (
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func TestParseJSON(t *testing.T) {
	line := `{"time":"2026-11-03T09:02:41Z","level":"error",` +
		`"service":"db","message":"connection reset"}`
	got, err := Parse(line)
	if err != nil {
		t.Fatal(err)
	}
	want := Entry{
		Time:    time.Date(2026, 11, 3, 9, 2, 41, 0, time.UTC),
		Level:   Error,
		Service: "db",
		Message: "connection reset",
	}
	if got != want {
		t.Errorf("Parse:\n got %+v\nwant %+v", got, want)
	}
}

func TestParseJSONErrors(t *testing.T) {
	tests := []struct {
		line  string
		field string
	}{
		{`{"time":"2026-11-03T09:02:41Z","level":"loud","service":"db"}`, "level"},
		{`{"time":"yesterday","level":"INFO","service":"db"}`, "time"},
		{`{"time":`, "json"},
	}
	for _, tt := range tests {
		_, err := Parse(tt.line)
		var perr *ParseError
		if !errors.As(err, &perr) || perr.Field != tt.field {
			t.Errorf("Parse(%s) error = %v, want a bad %s", tt.line, err, tt.field)
		}
	}
}

func TestLevelJSON(t *testing.T) {
	data, err := json.Marshal(Warn)
	if err != nil {
		t.Fatal(err)
	}
	var l Level
	if err := json.Unmarshal(data, &l); err != nil || l != Warn {
		t.Errorf("decoding %s gave %v, %v; want WARN, nil", data, l, err)
	}
	if err := json.Unmarshal([]byte(`"loud"`), &l); err == nil {
		t.Error(`decoding "loud" as a Level returned no error`)
	}
}
