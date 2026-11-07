package output_test

// START imports OMIT

import (
	"strings"
	"testing"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/output"
)

// END imports OMIT
// START data OMIT

type service struct {
	Name     string `json:"name"`
	Team     string `json:"team"`
	Replicas int    `json:"replicas"`
}

var services = []service{{"checkout", "payments", 4}, {"ledger", "payments", 2}}

func print(t *testing.T, format string, v any) string {
	t.Helper()
	ios, _, out, _ := cli.Test()
	p, err := output.New(ios, format)
	if err != nil {
		t.Fatalf("-o %s: %v", format, err)
	}
	if err := p.Data(v); err != nil {
		t.Fatalf("-o %s: %v", format, err)
	}
	return out.String()
}

func TestMachineFormats(t *testing.T) {
	for _, tc := range []struct{ format, want string }{
		{"json", "[\n  {\n    \"name\": \"checkout\",\n"},
		{"yaml", "- name: checkout\n  replicas: 4\n  team: payments\n"},
		{"jsonpath={[*].name}", "checkout ledger\n"},
		// Filters compare numbers: this needs whole numbers as int64.
		{"jsonpath={[?(@.replicas>3)].name}", "checkout\n"},
		{`jsonpath={range [*]}{.name}{"\t"}{.replicas}{"\n"}{end}`,
			"checkout\t4\nledger\t2\n"},
		{"jsonpath={[*].missing}", "\n"}, // like kubectl: missing is empty
		{`template={{range .}}{{.name | upper}} {{end}}`, "CHECKOUT LEDGER \n"},
		{`template={{json (index . 0)}}`,
			`{"name":"checkout","replicas":4,"team":"payments"}` + "\n"},
	} {
		got := print(t, tc.format, services)
		if !strings.HasPrefix(got, tc.want) {
			t.Errorf("-o %s:\n%q\nwant prefix\n%q", tc.format, got, tc.want)
		}
	}
}

func TestBadFormatsFailEarly(t *testing.T) {
	for _, format := range []string{"xml", "json=x", "jsonpath=",
		"jsonpath={.name", "template={{.name"} {
		ios, _, _, _ := cli.Test()
		if _, err := output.New(ios, format); err == nil {
			t.Errorf("-o %s: no error", format)
		}
	}
}

// END data OMIT
// START table OMIT

func TestTableAlignsColouredCells(t *testing.T) {
	ios, _, out, _ := cli.Test()
	ios.SetColorEnabled(true)
	p, _ := output.New(ios, "")
	tb := p.Table(output.Column{Name: "id"}, output.Column{Name: "state"},
		output.Column{Name: "version"})
	tb.Row("d-9", p.Paint(output.Green, "succeeded"), "v1.5.0")
	tb.Row("d-10", p.Paint(output.Red, "failed"), "v1.5.1")
	if err := tb.Flush(); err != nil {
		t.Fatal(err)
	}
	plain := stripANSI(out.String())
	want := "ID    STATE      VERSION\n" +
		"d-9   succeeded  v1.5.0\n" +
		"d-10  failed     v1.5.1\n"
	if plain != want {
		t.Errorf("table (escapes removed):\n%s\nwant:\n%s", plain, want)
	}
	if !strings.Contains(out.String(), "\x1b[31mfailed\x1b[0m") {
		t.Error("no colour on a colour-enabled stream")
	}
}

func TestWideColumns(t *testing.T) {
	for format, want := range map[string]string{
		"":     "NAME\ncheckout\n",
		"wide": "NAME      REPO\ncheckout  github.com/acme/checkout\n",
	} {
		ios, _, out, _ := cli.Test()
		p, _ := output.New(ios, format)
		tb := p.Table(output.Column{Name: "name"},
			output.Column{Name: "repo", Wide: true})
		tb.Row("checkout", "github.com/acme/checkout")
		_ = tb.Flush()
		if out.String() != want {
			t.Errorf("-o %q:\n%s\nwant:\n%s", format, out, want)
		}
	}
}

// On a terminal, long rows are cut at the terminal's edge instead of
// wrapping into the next line.
func TestTerminalTruncatesLongRows(t *testing.T) {
	ios, _, out, _ := cli.Test()
	ios.SetStdoutTTY(true)
	ios.SetTerminalWidth(20)
	p, _ := output.New(ios, "")
	tb := p.Table(output.Column{Name: "name"}, output.Column{Name: "reason"})
	tb.Row("checkout", "rollback after INC-412: 5xx above budget")
	_ = tb.Flush()
	for line := range strings.Lines(out.String()) {
		if w := len([]rune(strings.TrimSuffix(line, "\n"))); w > 20 {
			t.Errorf("line %q is %d columns wide", line, w)
		}
	}
}

// END table OMIT
// START time OMIT

func TestTimeDependsOnTheReader(t *testing.T) {
	ios, _, _, _ := cli.Test()
	p, _ := output.New(ios, "")
	at := time.Date(2026, 11, 6, 9, 0, 0, 0, time.UTC)
	p.Now = func() time.Time { return at.Add(4 * time.Minute) }
	if got := p.Time(at); got != "2026-11-06T09:00:00Z" {
		t.Errorf("in a pipe: %q", got)
	}
	ios.SetStdoutTTY(true)
	if got := p.Time(at); got != "4m ago" {
		t.Errorf("on a terminal: %q", got)
	}
}

// END time OMIT

func stripANSI(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == 0x1b {
			for i < len(s) && s[i] != 'm' {
				i++
			}
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
