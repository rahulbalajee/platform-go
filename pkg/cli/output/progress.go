package output

// START imports OMIT

import (
	"fmt"
	"strings"

	"github.com/rahulbalajee/platform-go/pkg/cli"
)

// END imports OMIT
// START progress OMIT

// Progress reports a long-running operation on stderr. On a terminal it
// redraws one line in place, with a bar; anywhere else (a CI log, a file,
// a pipe) it prints a line only when the message changes, because carriage
// returns and redraws turn a log into noise.
type Progress struct {
	io    *cli.IOStreams
	last  string
	drawn bool
}

// NewProgress returns a Progress writing to ios.ErrOut.
func NewProgress(ios *cli.IOStreams) *Progress { return &Progress{io: ios} }

// Update shows done of total steps and a message.
func (pr *Progress) Update(done, total int, msg string) {
	if !pr.io.IsStderrTTY() {
		if msg != pr.last {
			fmt.Fprintf(pr.io.ErrOut, "  %s\n", msg)
			pr.last = msg
		}
		return
	}
	// \r returns to the start of the line, \x1b[K erases to its end.
	fmt.Fprintf(pr.io.ErrOut, "\r\x1b[K  %s %s", bar(done, total, 20), msg)
	pr.drawn = true
}

// Done ends the progress line with a final message.
func (pr *Progress) Done(msg string) {
	if pr.drawn {
		fmt.Fprint(pr.io.ErrOut, "\r\x1b[K")
	}
	fmt.Fprintf(pr.io.ErrOut, "  %s\n", msg)
}

// bar draws a progress bar width cells wide: [██████░░░░].
func bar(done, total, width int) string {
	n := 0
	if total > 0 {
		n = min(width, max(0, done*width/total))
	}
	return "[" + strings.Repeat("█", n) + strings.Repeat("░", width-n) + "]"
}

// END progress OMIT
