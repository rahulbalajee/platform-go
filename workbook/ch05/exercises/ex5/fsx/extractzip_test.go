package fsx_test

import (
	"archive/zip"
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"testing/fstest"

	"oskit/fsx"
)

// zentry is one zip member: a file (Body), a directory (Dir) or a symlink.
type zentry struct {
	Name, Body, Link string
	Dir              bool
}

func makeZip(t *testing.T, entries ...zentry) *zip.Reader {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, e := range entries {
		hdr := &zip.FileHeader{Name: e.Name, Method: zip.Deflate}
		body := e.Body
		switch {
		case e.Dir:
			hdr.SetMode(fs.ModeDir | 0o755)
		case e.Link != "":
			hdr.SetMode(fs.ModeSymlink | 0o777)
			body = e.Link // a zip symlink stores its target as the contents
		default:
			hdr.SetMode(0o644)
		}
		w, err := zw.CreateHeader(hdr)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	zr, err := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatal(err)
	}
	return zr
}

func TestExtractZipGoodArchive(t *testing.T) {
	_, root := sandbox(t)
	archive := makeZip(t,
		zentry{Name: "etc/", Dir: true},
		zentry{Name: "etc/app.yaml", Body: "replicas: 3\n"},
		zentry{Name: "bin/run.sh", Body: "#!/bin/sh\n"},
		zentry{Name: "current", Link: "etc/app.yaml"},
	)
	if err := fsx.ExtractZip(archive, root, fsx.Limits{}); err != nil {
		t.Fatal(err)
	}
	if err := fstest.TestFS(root.FS(), "etc/app.yaml", "bin/run.sh"); err != nil {
		t.Fatal(err)
	}
	b, err := fs.ReadFile(root.FS(), "current")
	if err != nil || string(b) != "replicas: 3\n" {
		t.Fatalf("symlink current: %q, %v", b, err)
	}
}

func TestExtractZipRejectsEscapes(t *testing.T) {
	tests := []struct {
		name    string
		entries []zentry
	}{
		{"dot-dot", []zentry{{Name: "../escaped.txt", Body: "x"}}},
		{"absolute", []zentry{{Name: "/tmp/escaped.txt", Body: "x"}}},
		{"symlink out", []zentry{{Name: "logs", Link: "../"}}},
		{"absolute symlink", []zentry{{Name: "logs", Link: "/etc"}}},
		{"duplicate name", []zentry{
			{Name: "a.txt", Body: "1"}, {Name: "a.txt", Body: "2"}}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			parent, root := sandbox(t)
			err := fsx.ExtractZip(makeZip(t, tc.entries...), root, fsx.Limits{})
			if err == nil {
				t.Fatal("extraction succeeded, want an error")
			}
			if _, err := os.Lstat(filepath.Join(parent, "escaped.txt")); err == nil {
				t.Fatal("a file escaped the destination directory")
			}
		})
	}
}

// TestExtractZipLimits: a megabyte of zeros deflates to about a kilobyte,
// which is how a zip bomb hides its size. The limit applies to what comes
// out of the decompressor, not to what the archive claims.
func TestExtractZipLimits(t *testing.T) {
	_, root := sandbox(t)
	bomb := makeZip(t, zentry{Name: "zeros", Body: string(make([]byte, 1<<20))})
	err := fsx.ExtractZip(bomb, root, fsx.Limits{MaxBytes: 64 << 10})
	if !errors.Is(err, fsx.ErrArchiveTooLarge) {
		t.Fatalf("byte limit: err = %v, want ErrArchiveTooLarge", err)
	}

	_, root = sandbox(t)
	many := makeZip(t, zentry{Name: "a"}, zentry{Name: "b"}, zentry{Name: "c"})
	err = fsx.ExtractZip(many, root, fsx.Limits{MaxFiles: 2})
	if !errors.Is(err, fsx.ErrArchiveTooLarge) {
		t.Fatalf("file limit: err = %v, want ErrArchiveTooLarge", err)
	}
}
