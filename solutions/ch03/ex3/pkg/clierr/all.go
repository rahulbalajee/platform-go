package clierr

// START all OMIT
// All returns every error in err's tree that has type E, depth first, in
// the order errors.As visits them. errors.AsType stops at the first match;
// All is for the questions a joined error raises, such as "which request
// IDs failed?".
func All[E error](err error) []E {
	var found []E
	var walk func(error)
	walk = func(err error) {
		if err == nil {
			return
		}
		if e, ok := err.(E); ok { //nolint:errorlint // walking the tree by hand
			found = append(found, e)
		}
		switch x := err.(type) { //nolint:errorlint // as above
		case interface{ Unwrap() error }:
			walk(x.Unwrap())
		case interface{ Unwrap() []error }:
			for _, e := range x.Unwrap() {
				walk(e)
			}
		}
	}
	walk(err)
	return found
}

// END all OMIT
