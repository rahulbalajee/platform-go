//go:build windows

package fsx

// syncDir is a no-op on Windows. A directory opened with os.Open cannot be
// flushed there, so durability of the rename rests on NTFS's metadata
// journal rather than on an explicit flush.
func syncDir(string) error { return nil }
