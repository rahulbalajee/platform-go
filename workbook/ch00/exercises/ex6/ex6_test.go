package main

import (
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunGzip(t *testing.T) {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := io.WriteString(zw, testLog); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	name := filepath.Join(t.TempDir(), "app.log.gz")
	if err := os.WriteFile(name, buf.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	code := run([]string{"-level", "error", name}, nil, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("exit status = %d, want 0; stderr:\n%s", code, stderr.String())
	}
	want := "2026-11-03T09:02:40Z ERROR api GET /orders 500 timeout\n" +
		"2026-11-03T09:04:02Z ERROR worker job 1190 failed: timeout\n"
	if stdout.String() != want {
		t.Errorf("stdout:\n%s\nwant:\n%s", stdout.String(), want)
	}
}

func TestRunGzipCorrupt(t *testing.T) {
	name := filepath.Join(t.TempDir(), "broken.log.gz")
	if err := os.WriteFile(name, []byte("not gzip data\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if code := run([]string{name}, nil, &stdout, &stderr); code != 2 {
		t.Errorf("exit status = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "broken.log.gz") {
		t.Errorf("stderr does not name the file:\n%s", stderr.String())
	}
}
