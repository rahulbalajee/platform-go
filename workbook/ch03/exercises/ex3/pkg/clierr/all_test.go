package clierr_test

import (
	"errors"
	"fmt"
	"io/fs"
	"testing"

	"deployctl/pkg/clierr"
)

// Exercise 3.3: All returns every match in the tree, depth first, in the
// order errors.As would visit them.
func TestAllFindsEveryMatch(t *testing.T) {
	a := &fs.PathError{Op: "open", Path: "a", Err: fs.ErrNotExist}
	b := &fs.PathError{Op: "open", Path: "b", Err: fs.ErrPermission}
	c := &fs.PathError{Op: "stat", Path: "c", Err: fs.ErrNotExist}
	tree := errors.Join(
		&clierr.Error{Message: "first", Err: a},
		fmt.Errorf("second: %w; %w", b, errors.New("not a path error")),
		fmt.Errorf("third: %w", c),
	)
	got := clierr.All[*fs.PathError](tree)
	if len(got) != 3 || got[0] != a || got[1] != b || got[2] != c {
		t.Fatalf("All = %v, want [a b c] in that order", got)
	}
	if got := clierr.All[*fs.PathError](errors.New("flat")); len(got) != 0 {
		t.Errorf("All on a tree without matches = %v, want none", got)
	}
	if got := clierr.All[*fs.PathError](nil); len(got) != 0 {
		t.Errorf("All(nil) = %v, want none", got)
	}
	// Interface types work too, as with errors.AsType.
	type timeouter interface {
		error
		Timeout() bool
	}
	if got := clierr.All[timeouter](tree); len(got) != 3 {
		t.Errorf("All[timeouter] found %d, want 3 (*fs.PathError has Timeout)",
			len(got))
	}
}
