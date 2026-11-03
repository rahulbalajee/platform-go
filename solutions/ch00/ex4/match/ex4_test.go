package match

import (
	"testing"

	"logq/logline"
)

func TestService(t *testing.T) {
	e := logline.Entry{Level: logline.Info, Service: "db", Message: "ok"}
	if !Service("db").Match(e) {
		t.Error(`Service("db") does not match an entry from db`)
	}
	if !Service("DB").Match(e) {
		t.Error(`Service("DB") does not match an entry from db`)
	}
	if Service("api").Match(e) {
		t.Error(`Service("api") matches an entry from db`)
	}
	if got := Describe(Service("db")); got != "service=db" {
		t.Errorf("Describe = %q, want %q", got, "service=db")
	}
}
