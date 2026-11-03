package buildinfo_test

import (
	"bytes"
	"testing"

	"stamp/buildinfo"
)

func TestWriteMetric(t *testing.T) {
	info := buildinfo.Info{
		Name: "sweep", Version: "v1.4.0",
		Revision:  "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345",
		GoVersion: "go1.27.3", Platform: "linux/amd64",
	}
	var b bytes.Buffer
	if err := info.WriteMetric(&b); err != nil {
		t.Fatal(err)
	}
	want := "# HELP sweep_build_info Build information about the running binary.\n" +
		"# TYPE sweep_build_info gauge\n" +
		`sweep_build_info{goversion="go1.27.3",platform="linux/amd64",` +
		`revision="3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345",` +
		`version="v1.4.0"} 1` + "\n"
	if got := b.String(); got != want {
		t.Errorf("WriteMetric wrote\n%s\nwant\n%s", got, want)
	}
}

func TestWriteMetricNamesAndEscaping(t *testing.T) {
	tests := []struct {
		name, version, wantLine string
	}{
		{"my-tool.v2", "v1.0.0",
			`my_tool_v2_build_info{goversion="go1.27.3",platform="linux/arm64",` +
				`revision="",version="v1.0.0"} 1`},
		{"9lives", `v1 "rc" \ x` + "\nnext",
			`_9lives_build_info{goversion="go1.27.3",platform="linux/arm64",` +
				`revision="",version="v1 \"rc\" \\ x\nnext"} 1`},
		{"", "devel",
			`build_info{goversion="go1.27.3",platform="linux/arm64",` +
				`revision="",version="devel"} 1`},
	}
	for _, tt := range tests {
		info := buildinfo.Info{Name: tt.name, Version: tt.version,
			GoVersion: "go1.27.3", Platform: "linux/arm64"}
		var b bytes.Buffer
		if err := info.WriteMetric(&b); err != nil {
			t.Fatal(err)
		}
		lines := bytes.Split(bytes.TrimSpace(b.Bytes()), []byte("\n"))
		if got := string(lines[len(lines)-1]); got != tt.wantLine {
			t.Errorf("name %q: sample line\n%s\nwant\n%s", tt.name, got, tt.wantLine)
		}
	}
}
