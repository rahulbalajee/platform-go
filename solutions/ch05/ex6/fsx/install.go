package fsx

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// START install OMIT
// InstallDir installs the tree src at dst so that a reader going through
// dst sees a complete old tree or a complete new one, never a mix. dst is a
// symlink to a hidden version directory beside it. InstallDir copies src
// into a new version, flushes it to disk, renames a new symlink over dst
// (the atomic switch), and then removes all but the previous version. dst
// must not exist yet, or must be a symlink that InstallDir made. Callers
// that may install concurrently must serialize with a Lock.
func InstallDir(src fs.FS, dst string) error {
	dst = filepath.Clean(dst)
	parent, base := filepath.Dir(dst), filepath.Base(dst)
	old, err := os.Readlink(dst)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("install %s: not a symlink from InstallDir: %w", dst, err)
	}

	// 1. The new version, in a fresh hidden directory beside dst.
	version, err := os.MkdirTemp(parent, "."+base+"-")
	if err != nil {
		return fmt.Errorf("install %s: %w", dst, err)
	}
	link := version + ".link"
	done := false
	defer func() {
		if !done { // any failure: dst is untouched; remove our debris
			_ = os.Remove(link)
			_ = os.RemoveAll(version)
		}
	}()
	// MkdirTemp uses 0700; a release is meant to be read by its service.
	if err := os.Chmod(version, 0o755); err != nil { //nolint:gosec // see above
		return fmt.Errorf("install %s: %w", dst, err)
	}
	if err := os.CopyFS(version, src); err != nil {
		return fmt.Errorf("install %s: %w", dst, err)
	}
	if err := syncTree(version); err != nil {
		return fmt.Errorf("install %s: fsync: %w", dst, err)
	}

	// 2. The switch: a relative symlink, renamed over dst.
	if err := os.Symlink(filepath.Base(version), link); err != nil {
		return fmt.Errorf("install %s: %w", dst, err)
	}
	if err := os.Rename(link, dst); err != nil {
		return fmt.Errorf("install %s: %w", dst, err)
	}
	done = true
	if err := syncDir(parent); err != nil {
		return fmt.Errorf("install %s: fsync dir: %w", dst, err)
	}

	// 3. Remove older versions, but keep the previous one: a reader that
	// resolved dst just before the switch may still be opening files in it.
	return pruneVersions(parent, base, filepath.Base(version), old)
}

// pruneVersions removes the version directories of dst except keep.
func pruneVersions(parent, base string, keep ...string) error {
	entries, err := os.ReadDir(parent)
	if err != nil {
		return err
	}
	var errs []error
	for _, e := range entries {
		name := e.Name()
		mine := e.IsDir() && strings.HasPrefix(name, "."+base+"-")
		if mine && !slices.Contains(keep, name) {
			errs = append(errs, os.RemoveAll(filepath.Join(parent, name)))
		}
	}
	return errors.Join(errs...)
}

// syncTree flushes every file and directory under dir to stable storage.
func syncTree(dir string) error {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	defer root.Close()
	return fs.WalkDir(root.FS(), ".", func(p string, _ fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		f, err := root.Open(p)
		if err != nil {
			return err
		}
		if err := f.Sync(); err != nil {
			_ = f.Close()
			return err
		}
		return f.Close()
	})
}

// END install OMIT
