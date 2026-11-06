package clierr

import (
	"fmt"
	"runtime/debug"
)

// START safe OMIT

// PanicError is a recovered panic carried as an error. Stack is the stack
// of the goroutine that panicked, captured before it unwound.
type PanicError struct {
	Value any    // the value passed to panic
	Stack []byte // debug.Stack() at the point of recovery
}

// Error reports the panic value.
func (e *PanicError) Error() string { return fmt.Sprintf("panic: %v", e.Value) }

// Unwrap returns the panic value if it is an error, such as a runtime.Error.
func (e *PanicError) Unwrap() error {
	err, _ := e.Value.(error)
	return err
}

// Safe calls fn and turns a panic into a *PanicError. Use it where work
// crosses onto another goroutine: Run's recover can't see panics there.
func Safe(fn func() error) (err error) {
	defer func() {
		if v := recover(); v != nil {
			err = &PanicError{Value: v, Stack: debug.Stack()}
		}
	}()
	return fn()
}

// END safe OMIT
