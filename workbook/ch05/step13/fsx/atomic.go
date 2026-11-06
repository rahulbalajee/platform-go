// START atomichead OMIT

// Package fsx has file system helpers that hold up under crashes,
// concurrent access and hostile input.
package fsx

import (
	"bufio"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
)

// WriteFile atomically replaces name with data. Concurrent readers see
// either the complete old contents or the complete new contents, never a
// mix or an empty file, and once WriteFile returns nil the new contents
// survive a crash or power loss.
func WriteFile(name string, data []byte, perm fs.FileMode) error {
	return Write(name, perm, func(w io.Writer) error {
		_, err := w.Write(data)
		return err
	})
}

// END atomichead OMIT

// START atomic OMIT

// Write atomically replaces name with whatever fill writes. If fill or any
// step fails, name is left untouched and the temporary file is removed.
func Write(name string, perm fs.FileMode, fill func(io.Writer) error) (err error) {
	dir, base := filepath.Split(name)
	if dir == "" {
		dir = "."
	}
	// 1. Same directory, so the rename below never crosses a filesystem.
	f, err := os.CreateTemp(dir, "."+base+".tmp-*")
	if err != nil {
		return fmt.Errorf("atomic write %s: %w", name, err)
	}
	tmp, renamed := f.Name(), false
	defer func() {
		if !renamed { // any failure: leave the old file, remove our debris
			_ = f.Close()
			_ = os.Remove(tmp)
		}
	}()

	// 2. Write the new contents. Nobody can see this file under its name yet.
	bw := bufio.NewWriterSize(f, 64<<10)
	if err := fill(bw); err != nil {
		return fmt.Errorf("atomic write %s: %w", name, err)
	}
	if err := bw.Flush(); err != nil {
		return fmt.Errorf("atomic write %s: %w", name, err)
	}
	// 3. CreateTemp uses 0600; set the mode the caller asked for.
	if err := f.Chmod(perm); err != nil {
		return fmt.Errorf("atomic write %s: %w", name, err)
	}
	// 4. Force the data to stable storage before it becomes visible.
	if err := f.Sync(); err != nil {
		return fmt.Errorf("atomic write %s: fsync: %w", name, err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("atomic write %s: %w", name, err)
	}
	// 5. Atomically point the name at the new inode.
	if err := os.Rename(tmp, name); err != nil {
		return fmt.Errorf("atomic write %s: %w", name, err)
	}
	renamed = true
	// 6. Persist the directory entry, or a crash can undo the rename.
	if err := syncDir(dir); err != nil {
		return fmt.Errorf("atomic write %s: fsync dir: %w", name, err)
	}
	return nil
}

// END atomic OMIT
