package match

import (
	"testing"

	"logq/logline"
)

// START test OMIT
func TestMatchers(t *testing.T) {
	e := logline.Entry{
		Level:   logline.Error,
		Service: "api",
		Message: "GET /orders 500 timeout talking to db",
	}
	re, err := NewRegexp(`5\d\d`)
	if err != nil {
		t.Fatal(err)
	}
	isAPI := Func(func(e logline.Entry) bool { return e.Service == "api" })

	tests := []struct {
		m    Matcher
		want bool
	}{
		{MinLevel(logline.Warn), true},
		{MinLevel(logline.Error), true},
		{Contains("timeout"), true},
		{Contains("Timeout"), false},
		{re, true},
		{isAPI, true},
		{All{}, true},
		{All{MinLevel(logline.Warn), Contains("timeout")}, true},
		{All{MinLevel(logline.Warn), Contains("disk")}, false},
	}
	for _, tt := range tests {
		if got := tt.m.Match(e); got != tt.want {
			t.Errorf("%s: Match = %t, want %t", Describe(tt.m), got, tt.want)
		}
	}
}

// END test OMIT

func TestDescribe(t *testing.T) {
	re, err := NewRegexp(`5\d\d`)
	if err != nil {
		t.Fatal(err)
	}
	m := All{MinLevel(logline.Warn), Contains("timeout"), re}
	want := `level>=WARN and message contains "timeout" and message matches /5\d\d/`
	if got := Describe(m); got != want {
		t.Errorf("Describe = %s\nwant %s", got, want)
	}
}

func TestNewRegexpError(t *testing.T) {
	if _, err := NewRegexp("("); err == nil {
		t.Error(`NewRegexp("(") returned no error`)
	}
}
