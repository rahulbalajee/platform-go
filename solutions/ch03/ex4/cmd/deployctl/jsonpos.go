package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
)

// START hint OMIT
// jsonHint says where in data the decoder gave up, the way a person looks
// for it in an editor: line and column, counted from 1. Errors other than
// the two the decoder reports with an offset keep the old hint.
func jsonHint(data []byte, err error) string {
	var offset int64
	var what string
	if se, ok := errors.AsType[*json.SyntaxError](err); ok {
		offset, what = se.Offset, se.Error()
	} else if te, ok := errors.AsType[*json.UnmarshalTypeError](err); ok {
		offset = te.Offset
		what = fmt.Sprintf("%q must be %s, not a %s", te.Field, jsonKind(te.Type),
			te.Value)
	} else {
		return "fix the syntax; the cause below says where"
	}
	line, col := position(data, offset)
	return fmt.Sprintf("line %d, column %d: %s", line, col, what)
}

// END hint OMIT
// START position OMIT
// position turns the decoder's offset into a line and a column. The offset
// counts the bytes read, so the byte it stopped at is data[offset-1].
func position(data []byte, offset int64) (line, col int) {
	before := data[:max(min(offset, int64(len(data)))-1, 0)]
	line = 1 + bytes.Count(before, []byte("\n"))
	col = len(before) - bytes.LastIndexByte(before, '\n') // -1: no newline
	return line, col
}

// jsonKind names a Go type the way the JSON in the file spells it.
func jsonKind(t reflect.Type) string {
	switch t.Kind() {
	case reflect.Slice, reflect.Array:
		return "a list"
	case reflect.Map, reflect.Struct:
		return "an object"
	case reflect.String:
		return "a string"
	case reflect.Bool:
		return "true or false"
	default:
		return "a number"
	}
}

// END position OMIT
