// START helpers OMIT

package fsx_test

import (
	"archive/tar"
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"testing/fstest"

	"github.com/rahulbalajee/platform-go/pkg/fsx"
)

// entry is one tar member: a file (Body), a directory (Dir) or a symlink.
type entry struct {
	Name, Body, Link string
	Dir              bool
}

func makeTar(t *testing.T, entries ...entry) *bytes.Reader {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, e := range entries {
		hdr := &tar.Header{Name: e.Name, Mode: 0o644, Size: int64(len(e.Body))}
		switch {
		case e.Dir:
			hdr.Typeflag, hdr.Mode = tar.TypeDir, 0o755
		case e.Link != "":
			hdr.Typeflag, hdr.Linkname = tar.TypeSymlink, e.Link
		default:
			hdr.Typeflag = tar.TypeReg
		}
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(e.Body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return bytes.NewReader(buf.Bytes())
}

// sandbox returns a parent directory and an os.Root on parent/dst, so a test
// can check that nothing appeared next to dst.
func sandbox(t *testing.T) (string, *os.Root) {
	t.Helper()
	parent := t.TempDir()
	dst := filepath.Join(parent, "dst")
	if err := os.Mkdir(dst, 0o755); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dst)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = root.Close() })
	return parent, root
}

// END helpers OMIT

// START good OMIT

func TestExtractTarGoodArchive(t *testing.T) {
	_, root := sandbox(t)
	archive := makeTar(t,
		entry{Name: "etc/", Dir: true},
		entry{Name: "etc/app.yaml", Body: "replicas: 3\n"},
		entry{Name: "bin/run.sh", Body: "#!/bin/sh\n"},
		entry{Name: "current", Link: "etc/app.yaml"},
	)
	if err := fsx.ExtractTar(archive, root, fsx.Limits{}); err != nil {
		t.Fatal(err)
	}
	// fstest.TestFS checks the extracted tree behaves as a correct fs.FS
	// and contains the expected files.
	if err := fstest.TestFS(root.FS(), "etc/app.yaml", "bin/run.sh"); err != nil {
		t.Fatal(err)
	}
}

// END good OMIT

// START attacks OMIT

func TestExtractTarRejectsEscapes(t *testing.T) {
	tests := []struct {
		name    string
		entries []entry
	}{
		{"dot-dot", []entry{{Name: "../escaped.txt", Body: "x"}}},
		{"absolute", []entry{{Name: "/tmp/escaped.txt", Body: "x"}}},
		{"symlink out", []entry{{Name: "logs", Link: "../"}}},
		{"absolute symlink", []entry{{Name: "logs", Link: "/etc"}}},
		{"sneaky symlink", []entry{{Name: "a/logs", Link: "../b/../../etc"}}},
		{"duplicate name", []entry{
			{Name: "a.txt", Body: "1"}, {Name: "a.txt", Body: "2"}}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			parent, root := sandbox(t)
			err := fsx.ExtractTar(makeTar(t, tc.entries...), root, fsx.Limits{})
			if err == nil {
				t.Fatal("extraction succeeded, want an error")
			}
			t.Log(err)
			if _, err := os.Lstat(filepath.Join(parent, "escaped.txt")); err == nil {
				t.Fatal("a file escaped the destination directory")
			}
		})
	}
}

// END attacks OMIT

// START planted OMIT

// TestExtractTarRefusesPlantedSymlink covers a symlink that already exists
// in the destination (planted by an earlier step or another user): os.Root
// refuses to follow it outside the root.
func TestExtractTarRefusesPlantedSymlink(t *testing.T) {
	parent, root := sandbox(t)
	if err := os.Symlink(parent, filepath.Join(parent, "dst", "cache")); err != nil {
		t.Skip("symlinks unavailable:", err)
	}
	err := fsx.ExtractTar(makeTar(t, entry{Name: "cache/escaped.txt", Body: "x"}),
		root, fsx.Limits{})
	if err == nil {
		t.Fatal("write through planted symlink succeeded")
	}
	t.Log(err)
	if _, err := os.Lstat(filepath.Join(parent, "escaped.txt")); err == nil {
		t.Fatal("a file escaped the destination directory")
	}
}

func TestExtractTarLimits(t *testing.T) {
	_, root := sandbox(t)
	big := makeTar(t,
		entry{Name: "a", Body: "12345"}, entry{Name: "b", Body: "67890"})
	err := fsx.ExtractTar(big, root, fsx.Limits{MaxBytes: 8})
	if !errors.Is(err, fsx.ErrArchiveTooLarge) {
		t.Fatalf("byte limit: err = %v, want ErrArchiveTooLarge", err)
	}

	_, root = sandbox(t)
	many := makeTar(t, entry{Name: "a"}, entry{Name: "b"}, entry{Name: "c"})
	err = fsx.ExtractTar(many, root, fsx.Limits{MaxFiles: 2})
	if !errors.Is(err, fsx.ErrArchiveTooLarge) {
		t.Fatalf("file limit: err = %v, want ErrArchiveTooLarge", err)
	}
}

// END planted OMIT
