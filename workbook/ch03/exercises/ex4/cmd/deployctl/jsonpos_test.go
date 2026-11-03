package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"deployctl/pkg/clierr"
)

// Exercise 3.4: a config that isn't valid JSON, or has a value of the
// wrong type, gets a hint that says where: line and column (1-based) of
// the byte where the decoder stopped.
func TestConfigErrorsSayWhere(t *testing.T) {
	for _, tt := range []struct{ name, body, where, also string }{
		{"syntax", `{
  "api": "http://127.0.0.1:8787",
  "targets": ["us-east-1",]
}
`, "line 3, column 27", "invalid character"},
		{"type", `{
  "api": "http://127.0.0.1:8787",
  "service": "checkout",
  "targets": "us-east-1"
}
`, "line 4, column 24", `"targets"`},
	} {
		t.Run(tt.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "deployctl.json")
			if err := os.WriteFile(path, []byte(tt.body), 0o600); err != nil {
				t.Fatal(err)
			}
			_, err := loadConfig(path)
			e, ok := errors.AsType[*clierr.Error](err)
			if !ok || e.ID != "DPL-CONFIG" || clierr.CodeOf(err) != clierr.ExitUsage {
				t.Fatalf("err = %v, want a DPL-CONFIG usage error", err)
			}
			if !strings.Contains(e.Hint, tt.where) ||
				!strings.Contains(e.Hint, tt.also) {
				t.Errorf("hint = %q, want %q and %q in it", e.Hint, tt.where, tt.also)
			}
		})
	}
}
