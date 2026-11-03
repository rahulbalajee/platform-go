package buildinfo

import (
	"fmt"
	"io"
	"strings"
)

// START metric OMIT

// WriteMetric writes the build information as a Prometheus gauge in the
// text exposition format: a metric named <name>_build_info with the value
// 1 and the version, revision, Go version and platform as labels.
func (i Info) WriteMetric(w io.Writer) error {
	name := metricName(i.Name)
	_, err := fmt.Fprintf(w,
		"# HELP %[1]s Build information about the running binary.\n"+
			"# TYPE %[1]s gauge\n"+
			"%[1]s{goversion=%[2]s,platform=%[3]s,revision=%[4]s,version=%[5]s} 1\n",
		name, label(i.GoVersion), label(i.Platform), label(i.Revision),
		label(i.Version))
	return err
}

// metricName turns a program name into a valid metric name prefix:
// [a-zA-Z_:][a-zA-Z0-9_:]*, with every other character replaced by "_".
func metricName(program string) string {
	if program == "" {
		return "build_info"
	}
	var b strings.Builder
	for i, r := range program {
		switch {
		case r == '_' || r == ':' || 'a' <= r && r <= 'z' || 'A' <= r && r <= 'Z':
			b.WriteRune(r)
		case '0' <= r && r <= '9':
			if i == 0 {
				b.WriteByte('_') // a name cannot start with a digit
			}
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	return b.String() + "_build_info"
}

// labelEscaper escapes a label value as the exposition format requires.
var labelEscaper = strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`)

func label(v string) string { return `"` + labelEscaper.Replace(v) + `"` }

// END metric OMIT
