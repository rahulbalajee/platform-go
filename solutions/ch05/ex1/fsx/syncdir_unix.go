//go:build !windows

package fsx

import "os"

// syncDir flushes a directory's entries (creates, renames, removes) to disk.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	if err := d.Sync(); err != nil {
		_ = d.Close()
		return err
	}
	return d.Close()
}
