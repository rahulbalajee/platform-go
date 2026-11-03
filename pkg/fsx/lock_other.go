//go:build !(darwin || dragonfly || freebsd || linux || netbsd || openbsd || windows)

package fsx

import (
	"errors"
	"os"
)

var errWouldBlock = errors.New("fsx: lock would block")

func lockFile(*os.File) error   { return errors.ErrUnsupported }
func unlockFile(*os.File) error { return errors.ErrUnsupported }
