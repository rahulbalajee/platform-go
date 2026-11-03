package match

import (
	"testing"

	"logq/logline"
)

func TestNot(t *testing.T) {
	e := logline.Entry{Level: logline.Info, Message: "GET /healthz 200"}
	if Not(Contains("healthz")).Match(e) {
		t.Error(`Not(Contains("healthz")) matches a health check`)
	}
	if !Not(Contains("orders")).Match(e) {
		t.Error(`Not(Contains("orders")) does not match a health check`)
	}
	if !Not(Not(Contains("healthz"))).Match(e) {
		t.Error("two Nots do not cancel out")
	}
	got := Describe(Not(MinLevel(logline.Warn)))
	if want := "not (level>=WARN)"; got != want {
		t.Errorf("Describe = %q, want %q", got, want)
	}
}
