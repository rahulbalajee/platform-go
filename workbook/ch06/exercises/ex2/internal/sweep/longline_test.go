package sweep_test

import (
	"strings"
	"testing"

	"sweep/internal/sweep"
)

// TestParseTargetsReportsLongLines feeds the parser a line longer than
// bufio.Scanner accepts. The error must say which line, like every other
// inventory error, instead of a bare "token too long".
func TestParseTargetsReportsLongLines(t *testing.T) {
	long := "https://example.com/" + strings.Repeat("a", 70<<10)
	in := "# staging\nhttps://ok.example.com/healthz\n" + long + "\n"
	_, err := sweep.ParseTargets(strings.NewReader(in))
	if err == nil {
		t.Fatal("ParseTargets accepted a 70 KiB line")
	}
	for _, want := range []string{"line 3", "too long"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not contain %q", err, want)
		}
	}
}
