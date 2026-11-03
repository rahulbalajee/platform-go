package fsx

import (
	"archive/tar"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
)

// Limits bound what an archive may unpack. Zero fields take the defaults.
type Limits struct {
	MaxFiles int   // entries of any type; default 10,000
	MaxBytes int64 // total bytes of file contents; default 1 GiB
}

// ErrArchiveTooLarge is returned when an archive exceeds its Limits.
var ErrArchiveTooLarge = errors.New("archive exceeds limits")

// ExtractTar unpacks a tar stream into root. All file operations go through
// the os.Root, so an entry named "../../etc/cron.d/x", or a write through a
// symlink that leads outside root, fails instead of escaping. Symlinks whose
// target would leave root are rejected outright, because the program that
// later consumes the extracted tree will not be using an os.Root.
func ExtractTar(r io.Reader, root *os.Root, lim Limits) error {
	if lim.MaxFiles == 0 {
		lim.MaxFiles = 10_000
	}
	if lim.MaxBytes == 0 {
		lim.MaxBytes = 1 << 30
	}
	tr := tar.NewReader(r)
	budget := lim.MaxBytes
	for files := 1; ; files++ {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read tar: %w", err)
		}
		if files > lim.MaxFiles {
			return fmt.Errorf("%w: over %d entries", ErrArchiveTooLarge, lim.MaxFiles)
		}
		if err := extractEntry(tr, hdr, root, &budget); err != nil {
			return fmt.Errorf("extract %q: %w", hdr.Name, err)
		}
	}
}

// START extract OMIT
// extractEntry writes one archive entry through root. budget is the number
// of content bytes the archive may still write.
func extractEntry(
	tr *tar.Reader, hdr *tar.Header, root *os.Root, budget *int64,
) error {
	mode := hdr.FileInfo().Mode().Perm() // drops setuid, setgid and sticky
	switch hdr.Typeflag {
	case tar.TypeDir:
		return root.MkdirAll(hdr.Name, mode|0o700)
	case tar.TypeReg:
		if err := root.MkdirAll(path.Dir(hdr.Name), 0o755); err != nil {
			return err
		}
		// O_EXCL: never write through something already at this name.
		f, err := root.OpenFile(hdr.Name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
		if err != nil {
			return err
		}
		n, err := io.Copy(f, io.LimitReader(tr, *budget+1))
		*budget -= n
		if cerr := f.Close(); err == nil {
			err = cerr
		}
		if err == nil && *budget < 0 {
			err = ErrArchiveTooLarge
		}
		return err
	case tar.TypeSymlink:
		// Lexical check; os.Root guards everything else. (gosec's G305 flags
		// the join itself, which is the input to this very check.)
		target := path.Join(path.Dir(hdr.Name), hdr.Linkname) //nolint:gosec
		if path.IsAbs(hdr.Linkname) || !filepath.IsLocal(target) {
			return fmt.Errorf("symlink to %q leaves the destination", hdr.Linkname)
		}
		return root.Symlink(hdr.Linkname, hdr.Name)
	default:
		return fmt.Errorf("unsupported entry type %q", hdr.Typeflag)
	}
}

// END extract OMIT
