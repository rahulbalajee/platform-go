package commands

// START imports OMIT

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START formats OMIT

func TestOutputFormats(t *testing.T) {
	p := newTestPlat(t)
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"services", "list", "--team", "payments", "-o", "wide"},
			"NAME      TEAM      REPLICAS  REPO\n" +
				"checkout  payments  4         github.com/acme/checkout\n"},
		{[]string{"services", "list", "-o", "jsonpath={[*].name}"},
			"checkout inventory ledger notifier search\n"},
		{[]string{"envs", "list",
			"-o", "jsonpath={[?(@.protected==true)].name}"}, "prod\n"},
		{[]string{"deployments", "list", "-L", "2", "-o",
			`template={{range .}}{{.id}} {{.version}}{{"\n"}}{{end}}`},
			"d-8 v1.4.1\nd-7 v1.4.1\n"},
		// sigs.k8s.io/yaml goes through JSON and a map: keys come out
		// sorted, not in struct order.
		{[]string{"services", "get", "ledger", "-o", "yaml"},
			"name: ledger\nreplicas: 2\n" +
				"repo: github.com/acme/ledger\nteam: payments\n"},
	} {
		if err := p.run(tc.args...); err != nil {
			t.Fatalf("plat %s: %v", strings.Join(tc.args, " "), err)
		}
		if !strings.HasPrefix(p.out.String(), tc.want) {
			t.Errorf("plat %s:\n%s\nwant prefix:\n%s",
				strings.Join(tc.args, " "), p.out, tc.want)
		}
	}
}

// An empty list is [] in JSON, never null: `jq length` must say 0.
func TestEmptyListIsAnEmptyArray(t *testing.T) {
	p := newTestPlat(t)
	err := p.run("services", "list", "--team", "nobody", "-o", "json")
	if err != nil {
		t.Fatal(err)
	}
	if p.out.String() != "[]\n" {
		t.Errorf("stdout = %q, want []", p.out)
	}
}

// A bad -o is a usage error, found before any request is made.
func TestBadOutputFailsBeforeCallingTheAPI(t *testing.T) {
	p := newTestPlat(t)
	before := len(p.api.Requests())
	e := wantCode(t, p.run("deploy", "checkout", "v1.5.0", "-e", "dev",
		"-o", "jsonpath={.state"), clierr.ExitUsage)
	if !strings.Contains(e.Message, "bad JSONPath") {
		t.Errorf("message = %q", e.Message)
	}
	if n := len(p.api.Requests()) - before; n != 0 {
		t.Errorf("%d request(s) made; a deploy may have started", n)
	}
}

// END formats OMIT
// START deployjson OMIT

// With -o json, deploy prints the finished deployment, so a pipeline can
// read its state without a second call.
func TestDeployPrintsTheDeploymentAsJSON(t *testing.T) {
	p := newTestPlat(t)
	if err := p.run("deploy", "checkout", "v1.5.0", "-e", "staging",
		"-o", "json"); err != nil {
		t.Fatal(err)
	}
	var d platformapi.Deployment
	if err := json.Unmarshal([]byte(p.out.String()), &d); err != nil {
		t.Fatalf("stdout is not a deployment: %v\n%s", err, p.out)
	}
	if d.ID != "d-9" || d.State != platformapi.StateSucceeded ||
		d.UpdatedReplicas != 4 {
		t.Errorf("deployment = %+v", d)
	}
	if !p.f.IO.JSONErrors() {
		t.Error("-o json did not switch errors to JSON")
	}
}

// END deployjson OMIT
// START progress OMIT

// On a terminal, progress redraws one line with a bar; in a log, each new
// message gets its own line and there are no control characters.
func TestDeployProgressDependsOnTheTerminal(t *testing.T) {
	for _, tty := range []bool{true, false} {
		p := newTestPlat(t)
		p.f.IO.SetStderrTTY(tty)
		if err := p.run("deploy", "checkout", "v1.5.0", "-e", "dev"); err != nil {
			t.Fatal(err)
		}
		got := p.errOut.String()
		redraws := strings.Count(got, "\r\x1b[K")
		switch {
		case tty && (redraws < 4 || !strings.Contains(got, "[██████████")):
			t.Errorf("terminal: %d redraws, want a redrawn bar:\n%q",
				redraws, got)
		case !tty && (redraws != 0 || strings.Count(got, "replicas updated\n") != 4):
			t.Errorf("log: want one line per change and no redraws:\n%q", got)
		}
		if !strings.Contains(got, "rolled out: 4/4 replicas") {
			t.Errorf("tty=%v: no final line:\n%q", tty, got)
		}
	}
}

// END progress OMIT
