// START head OMIT

// Package cli is the framework the command-line tools in this book share.
// It owns the process edges that every tool gets wrong in the same ways:
// where output goes and whether it is a terminal, how a cobra command tree
// is executed, and how a failure becomes one clear message and an exit code
// (via package clierr). Commands themselves stay plain functions that take
// their options and an *IOStreams, so tests call them directly.
package cli

// END head OMIT
// START imports OMIT

import (
	"bytes"
	"io"
	"os"
	"strconv"

	"golang.org/x/term"
)

// END imports OMIT
// START streams OMIT

// IOStreams are the three standard streams plus what a command needs to know
// about them: whether each is a terminal, and whether colour and prompts are
// allowed. Commands write data to Out and everything else (progress,
// warnings, prompts) to ErrOut, so `plat services list | jq` stays clean.
type IOStreams struct {
	In     io.Reader
	Out    io.Writer
	ErrOut io.Writer

	inTTY, outTTY, errTTY bool
	colour                bool
	neverPrompt           bool
	width                 func() int
}

// END streams OMIT
// START system OMIT

// System returns the process's real streams. Terminal detection and the
// colour decision happen once, here, from the file descriptors and the
// environment, so every command sees the same answer.
func System() *IOStreams {
	s := &IOStreams{
		In:     os.Stdin,
		Out:    os.Stdout,
		ErrOut: os.Stderr,
		inTTY:  isTerminal(os.Stdin),
		outTTY: isTerminal(os.Stdout),
		errTTY: isTerminal(os.Stderr),
		width:  func() int { return terminalWidth(os.Stdout) },
	}
	s.colour = colourAllowed(os.Getenv, s.outTTY)
	return s
}

func isTerminal(f *os.File) bool { return term.IsTerminal(int(f.Fd())) }

// terminalWidth asks the terminal behind f for its width. COLUMNS is the
// fallback for pipes (it is what `COLUMNS=120 plat ... | less` sets), and
// 80 is the fallback for that.
func terminalWidth(f *os.File) int {
	if w, _, err := term.GetSize(int(f.Fd())); err == nil && w > 0 {
		return w
	}
	if w, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && w > 0 {
		return w
	}
	return 80
}

// END system OMIT
// START colour OMIT

// colourAllowed implements the conventions people set in their shells:
// NO_COLOR (no-color.org) turns colour off, CLICOLOR_FORCE turns it on even
// into a pipe, and TERM=dumb terminals get none. Otherwise colour follows
// whether stdout is a terminal.
func colourAllowed(getenv func(string) string, outTTY bool) bool {
	switch {
	case getenv("NO_COLOR") != "":
		return false
	case getenv("CLICOLOR_FORCE") != "" && getenv("CLICOLOR_FORCE") != "0":
		return true
	case getenv("TERM") == "dumb":
		return false
	}
	return outTTY
}

// END colour OMIT
// START test OMIT

// Test returns streams backed by buffers, none of them terminals, for tests:
// stdin reads from in, and out and errOut collect what the command wrote.
// Use the Set methods to pretend a stream is a terminal.
func Test() (s *IOStreams, in, out, errOut *bytes.Buffer) {
	in, out, errOut = new(bytes.Buffer), new(bytes.Buffer), new(bytes.Buffer)
	s = &IOStreams{
		In: in, Out: out, ErrOut: errOut,
		width: func() int { return 80 },
	}
	return s, in, out, errOut
}

// END test OMIT
// START queries OMIT

// IsStdinTTY reports whether stdin is a terminal.
func (s *IOStreams) IsStdinTTY() bool { return s.inTTY }

// IsStdoutTTY reports whether stdout is a terminal: whether a person is
// reading the data, rather than a pipe, a file or a CI log.
func (s *IOStreams) IsStdoutTTY() bool { return s.outTTY }

// IsStderrTTY reports whether stderr is a terminal, which decides whether
// progress may redraw a line in place.
func (s *IOStreams) IsStderrTTY() bool { return s.errTTY }

// ColorEnabled reports whether output may contain ANSI colour codes.
func (s *IOStreams) ColorEnabled() bool { return s.colour }

// CanPrompt reports whether the command may ask a question: there must be a
// person at both ends (stdin and stdout are terminals) and prompting must
// not have been turned off with SetNeverPrompt (the --no-input flag).
func (s *IOStreams) CanPrompt() bool {
	return s.inTTY && s.outTTY && !s.neverPrompt
}

// TerminalWidth returns the width of the terminal stdout is attached to, or
// a sensible default when it is not one.
func (s *IOStreams) TerminalWidth() int { return s.width() }

// END queries OMIT
// START setters OMIT

// SetStdinTTY overrides terminal detection for stdin (for tests).
func (s *IOStreams) SetStdinTTY(v bool) { s.inTTY = v }

// SetStdoutTTY overrides terminal detection for stdout (for tests).
func (s *IOStreams) SetStdoutTTY(v bool) { s.outTTY = v }

// SetStderrTTY overrides terminal detection for stderr (for tests).
func (s *IOStreams) SetStderrTTY(v bool) { s.errTTY = v }

// SetColorEnabled overrides the colour decision.
func (s *IOStreams) SetColorEnabled(v bool) { s.colour = v }

// SetNeverPrompt forbids prompts even on a terminal (--no-input).
func (s *IOStreams) SetNeverPrompt(v bool) { s.neverPrompt = v }

// SetTerminalWidth fixes the width TerminalWidth reports (for tests).
func (s *IOStreams) SetTerminalWidth(w int) { s.width = func() int { return w } }

// END setters OMIT
