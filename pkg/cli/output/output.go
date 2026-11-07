// START head OMIT

// Package output prints a command's results for whoever reads them. People
// get aligned tables, colour and relative times, and only on a terminal;
// programs get JSON, YAML, JSONPath or a Go template, chosen with -o, in a
// shape that only ever grows: fields are added, never renamed or removed.
package output

// END head OMIT
// START imports OMIT

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"strings"
	"text/template"
	"time"

	"github.com/charmbracelet/x/ansi"
	"github.com/spf13/cobra"
	"k8s.io/client-go/util/jsonpath"
	"sigs.k8s.io/yaml"

	"github.com/rahulbalajee/platform-go/pkg/cli"
)

// END imports OMIT
// START format OMIT

// Format is a parsed -o value.
type Format struct {
	Kind string // "table", "wide", "json", "yaml", "jsonpath" or "template"
	Expr string // the expression of jsonpath= and template=
}

// Formats lists the -o values, for help text and shell completion.
var Formats = []string{"table", "wide", "json", "yaml", "jsonpath=", "template="}

// Parse parses an -o value. The empty string means a table.
func Parse(s string) (Format, error) {
	kind, expr, hasExpr := strings.Cut(s, "=")
	switch kind {
	case "", "table", "wide", "json", "yaml":
		if hasExpr {
			return Format{}, fmt.Errorf("-o %s takes no expression", kind)
		}
		if kind == "" {
			kind = "table"
		}
		return Format{Kind: kind}, nil
	case "jsonpath", "template", "go-template":
		if expr == "" {
			return Format{}, fmt.Errorf("-o %s needs an expression, "+
				"as in -o %s=EXPR", kind, kind)
		}
		if kind == "go-template" { // kubectl's name for it
			kind = "template"
		}
		return Format{Kind: kind, Expr: expr}, nil
	}
	return Format{}, fmt.Errorf("unknown output format %q; want one of %s",
		s, strings.Join(Formats, ", "))
}

// AddFlag registers -o/--output on cmd, storing the raw value in p.
func AddFlag(cmd *cobra.Command, p *string) {
	cmd.Flags().StringVarP(p, "output", "o", "", "output `FORMAT`: "+
		strings.Join(Formats, ", "))
	_ = cmd.RegisterFlagCompletionFunc("output", cobra.FixedCompletions(
		Formats, cobra.ShellCompDirectiveNoSpace|cobra.ShellCompDirectiveNoFileComp))
}

// END format OMIT
// START printer OMIT

// Printer prints in one Format to one set of streams.
type Printer struct {
	IO     *cli.IOStreams
	Format Format
	Now    func() time.Time // for relative times; default time.Now

	jp  *jsonpath.JSONPath
	tpl *template.Template
}

// New returns a Printer, compiling a JSONPath or template expression now
// so a typo fails before the command does any work. With -o json, errors
// are reported as JSON too, so a script parsing stdout can parse stderr.
func New(ios *cli.IOStreams, raw string) (*Printer, error) {
	f, err := Parse(raw)
	if err != nil {
		return nil, err
	}
	p := &Printer{IO: ios, Format: f, Now: time.Now}
	switch f.Kind {
	case "jsonpath":
		p.jp = jsonpath.New("output").AllowMissingKeys(true)
		if err := p.jp.Parse(f.Expr); err != nil {
			return nil, fmt.Errorf("bad JSONPath %q: %w", f.Expr, err)
		}
	case "template":
		p.tpl, err = template.New("output").Funcs(funcs).Parse(f.Expr)
		if err != nil {
			return nil, fmt.Errorf("bad template: %w", err)
		}
	case "json":
		ios.SetJSONErrors(true)
	}
	return p, nil
}

// Machine reports whether the output is for programs: anything but a table.
func (p *Printer) Machine() bool {
	return p.Format.Kind != "table" && p.Format.Kind != "wide"
}

// END printer OMIT
// START data OMIT

// Data writes v (an API object, or a slice of them) in the machine format.
// Field names are the API's JSON names in every format, so `-o json`,
// `-o jsonpath={.name}` and `-o template={{.name}}` all say "name".
func (p *Printer) Data(v any) error {
	switch p.Format.Kind {
	case "json":
		b, err := json.MarshalIndent(v, "", "  ")
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(p.IO.Out, "%s\n", b)
		return err
	case "yaml":
		b, err := yaml.Marshal(v)
		if err != nil {
			return err
		}
		_, err = p.IO.Out.Write(b)
		return err
	}
	doc, err := generic(v)
	if err != nil {
		return err
	}
	var buf bytes.Buffer
	if p.jp != nil {
		err = p.jp.Execute(&buf, doc)
	} else {
		err = p.tpl.Execute(&buf, doc)
	}
	if err != nil {
		return err
	}
	if !bytes.HasSuffix(buf.Bytes(), []byte("\n")) {
		buf.WriteByte('\n') // so the shell prompt starts on a new line
	}
	_, err = p.IO.Out.Write(buf.Bytes())
	return err
}

// generic converts v to the maps, slices and scalars that JSONPath and
// templates walk, through JSON so the field names match -o json. Whole
// numbers become int64: encoding/json decodes every number as float64, and
// JSONPath then rejects a filter like [?(@.replicas>3)] with "incompatible
// types for comparison", because the literal 3 is an integer.
func generic(v any) (any, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var doc any
	if err := json.Unmarshal(b, &doc); err != nil {
		return nil, err
	}
	return ints(doc), nil
}

func ints(v any) any {
	switch x := v.(type) {
	case float64:
		if x == math.Trunc(x) && math.Abs(x) < 1<<53 {
			return int64(x)
		}
	case []any:
		for i := range x {
			x[i] = ints(x[i])
		}
	case map[string]any:
		for k := range x {
			x[k] = ints(x[k])
		}
	}
	return v
}

// funcs are the template functions beyond text/template's own.
var funcs = template.FuncMap{
	"json": func(v any) (string, error) {
		b, err := json.Marshal(v)
		return string(b), err
	},
	"join":  func(sep string, v []any) string { return joinAny(v, sep) },
	"upper": strings.ToUpper,
	"lower": strings.ToLower,
}

func joinAny(v []any, sep string) string {
	s := make([]string, len(v))
	for i, x := range v {
		s[i] = fmt.Sprint(x)
	}
	return strings.Join(s, sep)
}

// END data OMIT
// START table OMIT

// Column is a table column. Wide columns appear only with -o wide.
type Column struct {
	Name string
	Wide bool
}

// Table collects rows and prints them aligned. It measures what a terminal
// shows, not bytes: text/tabwriter counts the bytes of colour escape codes,
// so a coloured cell would push the rest of its row out of line.
type Table struct {
	p    *Printer
	cols []Column
	rows [][]string
}

// Table starts a table with the given columns.
func (p *Printer) Table(cols ...Column) *Table {
	return &Table{p: p, cols: cols}
}

// Row adds a row; cells line up with the columns given to Table.
func (t *Table) Row(cells ...string) { t.rows = append(t.rows, cells) }

// Flush prints the table: two spaces between columns, header in upper case,
// and on a terminal the last column cut to the terminal's width.
func (t *Table) Flush() error {
	wide := t.p.Format.Kind == "wide"
	var keep []int
	for i, c := range t.cols {
		if wide || !c.Wide {
			keep = append(keep, i)
		}
	}
	all := append([][]string{t.header()}, t.rows...)
	widths := make([]int, len(t.cols))
	for _, r := range all {
		for _, i := range keep {
			widths[i] = max(widths[i], ansi.StringWidth(cell(r, i)))
		}
	}
	var b strings.Builder
	for _, r := range all {
		var line strings.Builder
		for n, i := range keep {
			c := cell(r, i)
			if n == len(keep)-1 {
				line.WriteString(c)
				break
			}
			line.WriteString(c)
			line.WriteString(strings.Repeat(" ", widths[i]-ansi.StringWidth(c)+2))
		}
		s := line.String()
		if t.p.IO.IsStdoutTTY() {
			s = ansi.Truncate(s, t.p.IO.TerminalWidth(), "…")
		}
		b.WriteString(s)
		b.WriteByte('\n')
	}
	_, err := io.WriteString(t.p.IO.Out, b.String())
	return err
}

func (t *Table) header() []string {
	h := make([]string, len(t.cols))
	for i, c := range t.cols {
		h[i] = strings.ToUpper(c.Name)
	}
	return h
}

func cell(r []string, i int) string {
	if i < len(r) {
		return r[i]
	}
	return ""
}

// END table OMIT
// START human OMIT

// Time formats t for a table. On a terminal a person reads "4m ago" faster
// than a timestamp; in a pipe, a timestamp in UTC is what sort and grep
// need, and it doesn't change from one run to the next.
func (p *Printer) Time(t time.Time) string {
	if !p.IO.IsStdoutTTY() {
		return t.UTC().Format(time.RFC3339)
	}
	return Ago(p.Now().Sub(t))
}

// Ago renders a duration as people say it: "45s ago", "4m ago", "3h ago",
// "12d ago".
func Ago(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	}
	return fmt.Sprintf("%dd ago", int(d.Hours()/24))
}

// Colour names the colours Paint knows.
type Colour int

// Colours for states: good, bad, in progress, and not important.
const (
	Green Colour = iota
	Red
	Yellow
	Dim
)

// Paint wraps s in the ANSI codes for c, if colour is enabled.
func (p *Printer) Paint(c Colour, s string) string {
	if !p.IO.ColorEnabled() {
		return s
	}
	code := [...]string{Green: "32", Red: "31", Yellow: "33", Dim: "2"}[c]
	return "\x1b[" + code + "m" + s + "\x1b[0m"
}

// END human OMIT
