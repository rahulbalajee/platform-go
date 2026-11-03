package clierr

// START imports OMIT
import (
	"errors"
	"fmt"
	"log/slog"
)

// END imports OMIT
// START error OMIT
// Error is a failure the program can explain to the person who ran it.
// Message, Hint and Docs are written for that person. Err is the cause
// chain for operators, logs and errors.Is/As. A zero Code means "infer it
// from Err" (see CodeOf); ExitFailure if nothing more specific matches.
type Error struct {
	Code    Code   // exit status, or zero to infer it from Err
	ID      string // stable identifier users can search for: "DPL-AUTH"
	Message string // what went wrong, in the user's terms
	Hint    string // what to do next
	Docs    string // optional link to the longer explanation
	Err     error  // the cause chain
}

// Error returns the message followed by the cause, so an *Error that is
// logged or wrapped by fmt.Errorf still carries the full chain.
func (e *Error) Error() string {
	switch {
	case e.Err == nil:
		return e.Message
	case e.Message == "":
		return e.Err.Error()
	}
	return e.Message + ": " + e.Err.Error()
}

// Unwrap exposes the cause to errors.Is and errors.As.
func (e *Error) Unwrap() error { return e.Err }

// END error OMIT
// START usermsg OMIT
// UserMessage returns the text to show a person for err: the Message of the
// first *Error in the tree, or err.Error() when nobody wrote one.
func UserMessage(err error) string {
	if e, ok := errors.AsType[*Error](err); ok && e.Message != "" {
		return e.Message
	}
	return err.Error()
}

// details lists the user messages of the errors that cause wraps directly
// when it wraps several (errors.Join, or fmt.Errorf with several %w).
func details(cause error) []string {
	multi, ok := cause.(interface{ Unwrap() []error })
	if !ok {
		return nil
	}
	var out []string
	for _, err := range multi.Unwrap() {
		out = append(out, UserMessage(err))
	}
	return out
}

// END usermsg OMIT
// START chain OMIT
// Chain lists the dynamic types in err's tree in the order errors.Is visits
// them (depth first), for operator logs: "*url.Error" tells you which layer
// failed in a way that the message often doesn't.
func Chain(err error) []string {
	var out []string
	var walk func(error)
	walk = func(err error) {
		if err == nil {
			return
		}
		out = append(out, fmt.Sprintf("%T", err))
		switch x := err.(type) { //nolint:errorlint // this node, not one below it
		case interface{ Unwrap() error }:
			walk(x.Unwrap())
		case interface{ Unwrap() []error }:
			for _, e := range x.Unwrap() {
				walk(e)
			}
		}
	}
	walk(err)
	return out
}

// END chain OMIT
// START secret OMIT
// Secret is a string that fmt, log/slog and encoding/json print as
// "[REDACTED]". Code that needs the value writes string(s), visibly.
type Secret string

const redacted = "[REDACTED]"

// String, Format, LogValue and MarshalText all produce "[REDACTED]".
func (Secret) String() string               { return redacted }
func (Secret) Format(f fmt.State, _ rune)   { fmt.Fprint(f, redacted) }
func (Secret) LogValue() slog.Value         { return slog.StringValue(redacted) }
func (Secret) MarshalText() ([]byte, error) { return []byte(redacted), nil }

// END secret OMIT
