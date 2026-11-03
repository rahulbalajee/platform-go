package fsx

import (
	"archive/zip"
	"fmt"
	"io"
	"io/fs"
	"os"
)

// START zip OMIT
// ExtractZip unpacks a zip archive into root with the rules ExtractTar
// follows: every operation goes through root, files are created with
// O_EXCL and permission bits only, symlinks must stay inside, and lim
// bounds the number of entries and the bytes that come out of the
// decompressor.
func ExtractZip(zr *zip.Reader, root *os.Root, lim Limits) error {
	lim = lim.withDefaults()
	if len(zr.File) > lim.MaxFiles { // the central directory lists them all
		return fmt.Errorf("%w: %d entries, over %d", ErrArchiveTooLarge,
			len(zr.File), lim.MaxFiles)
	}
	budget := lim.MaxBytes
	for _, f := range zr.File {
		if err := extractZipEntry(f, root, &budget); err != nil {
			return fmt.Errorf("extract %q: %w", f.Name, err)
		}
	}
	return nil
}

func extractZipEntry(f *zip.File, root *os.Root, budget *int64) error {
	mode := f.Mode()
	switch {
	case mode.IsDir():
		return root.MkdirAll(f.Name, mode.Perm()|0o700)
	case mode&fs.ModeSymlink != 0:
		target, err := readSmall(f, 4096) // the link target is the contents
		if err != nil {
			return err
		}
		return createSymlink(root, f.Name, target)
	case mode.IsRegular():
		rc, err := f.Open()
		if err != nil {
			return err
		}
		defer rc.Close()
		return createFile(root, f.Name, mode.Perm(), rc, budget)
	}
	return fmt.Errorf("unsupported entry type %v", mode.Type())
}

// readSmall returns the contents of f, which must be at most max bytes.
func readSmall(f *zip.File, max int64) (string, error) {
	rc, err := f.Open()
	if err != nil {
		return "", err
	}
	defer rc.Close()
	b, err := io.ReadAll(io.LimitReader(rc, max+1))
	if err == nil && int64(len(b)) > max {
		err = fmt.Errorf("symlink target over %d bytes", max)
	}
	return string(b), err
}

// END zip OMIT
