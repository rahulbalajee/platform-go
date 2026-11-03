// START untarhead OMIT

// Command untar extracts a tar archive two ways: naively, with
// filepath.Join, and safely, with fsx.ExtractTar and os.Root. It can also
// write a malicious sample archive to try them on.
//
//	untar -make-evil evil.tar
//	untar -naive evil.tar out/   # writes outside out/
//	untar evil.tar out/          # refuses
package main

import (
	"archive/tar"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/rahulbalajee/platform-go/pkg/fsx"
)

func main() {
	naive := flag.Bool("naive", false, "use the vulnerable extractor")
	makeEvil := flag.String("make-evil", "", "write a malicious sample archive here")
	flag.Parse()

	var err error
	switch {
	case *makeEvil != "":
		err = writeEvil(*makeEvil)
	case flag.NArg() != 2:
		err = errors.New("usage: untar [-naive] ARCHIVE DIR")
	default:
		err = extract(flag.Arg(0), flag.Arg(1), *naive)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "untar:", err)
		os.Exit(1)
	}
}

func extract(archive, dir string, naive bool) error {
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return err
	}
	if naive {
		return extractNaive(f, dir)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	defer root.Close()
	return fsx.ExtractTar(f, root, fsx.Limits{MaxBytes: 64 << 20})
}

// END untarhead OMIT

// START naive OMIT
// extractNaive is how "zip slip" happens: the entry name is trusted, and
// symlinks from the archive are followed by later writes.
func extractNaive(r io.Reader, dir string) error {
	tr := tar.NewReader(r)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		target := filepath.Join(dir, hdr.Name) //nolint:gosec // the bug on display
		switch hdr.Typeflag {
		case tar.TypeSymlink:
			err = os.Symlink(hdr.Linkname, target)
		case tar.TypeReg:
			err = writeFile(target, tr)
		}
		if err != nil {
			return err
		}
		fmt.Println("wrote", target)
	}
}

// END naive OMIT

// START evil OMIT
func writeFile(name string, r io.Reader) error {
	if err := os.MkdirAll(filepath.Dir(name), 0o750); err != nil {
		return err
	}
	f, err := os.Create(name)
	if err != nil {
		return err
	}
	_, err = io.Copy(f, io.LimitReader(r, 1<<20))
	return errors.Join(err, f.Close())
}

// writeEvil writes an archive with one honest entry and two escapes: a
// "../" path, and a symlink to the parent followed by a file written
// through it.
func writeEvil(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	tw := tar.NewWriter(f)
	add := func(hdr *tar.Header, body string) error {
		hdr.Size, hdr.Mode = int64(len(body)), 0o644
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		_, err := io.WriteString(tw, body)
		return err
	}
	err = errors.Join(
		add(&tar.Header{Name: "README.md", Typeflag: tar.TypeReg}, "hello\n"),
		add(&tar.Header{Name: "../escaped.txt", Typeflag: tar.TypeReg}, "owned\n"),
		add(&tar.Header{Name: "logs", Typeflag: tar.TypeSymlink, Linkname: ".."}, ""),
		add(&tar.Header{Name: "logs/via-symlink.txt", Typeflag: tar.TypeReg},
			"owned\n"),
		tw.Close(),
	)
	return errors.Join(err, f.Close())
}

// END evil OMIT
