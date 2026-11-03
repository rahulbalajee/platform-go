//go:build !(linux || darwin)

package sysinfo

import "errors"

// NoFile is not implemented on this platform.
func NoFile() (soft, hard uint64, err error) { return 0, 0, errors.ErrUnsupported }
