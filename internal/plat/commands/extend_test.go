package commands

// START imports OMIT

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/rahulbalajee/platform-go/pkg/clierr"
)

// END imports OMIT
// START policies OMIT

const prodRules = `policies:
  - name: prod-needs-ticket
    match: request.environment == "prod"
    rule: request.reason.matches('^[A-Z]+-[0-9]+')
    message: prod deploys need --reason with a ticket, such as INC-412
  - name: team-owns-service
    rule: service.team == "payments"
    messageExpression: "'only payments deploys here, not ' + service.team"
`

// withPolicies puts a policy file in the repository plat runs in.
func withPolicies(t *testing.T, p *testPlat, yaml string) {
	t.Helper()
	wd, _ := p.f.WorkDir()
	dir := filepath.Join(wd, ".plat", "policies")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	err := os.WriteFile(filepath.Join(dir, "prod.yaml"), []byte(yaml), 0o600)
	if err != nil {
		t.Fatal(err)
	}
}

// A refused deploy deploys nothing and says which check refused, and why.
func TestDeployRefusedByPolicy(t *testing.T) {
	p := newTestPlat(t)
	withPolicies(t, p, prodRules)
	e := wantCode(t, p.run("deploy", "checkout", "v1.5.0", "-e", "prod",
		"--reason", "quick fix"), clierr.ExitFailure)
	if e.ID != "PLAT-POLICY" || !strings.Contains(e.Error(),
		"prod-needs-ticket (cel): prod deploys need --reason with a ticket") {
		t.Errorf("error: %v", e)
	}
	for _, r := range p.api.Requests() {
		if r.Method == http.MethodPost {
			t.Errorf("a deployment was created: %s %s", r.Method, r.Path)
		}
	}

	if err := p.run("deploy", "checkout", "v1.5.0", "-e", "prod",
		"--reason", "INC-412 fix"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(p.errOut.String(), "Pre-deploy checks: 2 passed\n") {
		t.Errorf("stderr:\n%s", p.errOut)
	}
}

func TestPolicyCheck(t *testing.T) {
	p := newTestPlat(t)
	withPolicies(t, p, prodRules)
	err := p.run("policy", "check", "search", "v2.0.0", "-e", "dev")
	_ = wantCode(t, err, clierr.ExitFailure)
	want := "CHECK              KIND  RESULT  MESSAGE\n" +
		"prod-needs-ticket  cel   skip    \n" +
		"team-owns-service  cel   fail    only payments deploys here, not discovery\n"
	if p.out.String() != want {
		t.Errorf("stdout:\n%s\nwant:\n%s", p.out, want)
	}
}

// A broken policy stops every deploy, with the file and the position.
func TestBrokenPolicyStopsDeploys(t *testing.T) {
	p := newTestPlat(t)
	withPolicies(t, p,
		"policies:\n  - name: typo\n    rule: request.envronment == 'prod'\n")
	e := wantCode(t, p.run("deploy", "checkout", "v1.5.0", "-e", "dev"),
		clierr.ExitUsage)
	if e.ID != "PLAT-POLICY-LOAD" ||
		!strings.Contains(e.Error(),
			"prod.yaml: policy typo, rule:1:8: undefined field") {
		t.Errorf("error: %v", e)
	}
}

// A check that can't answer has not said yes: a rule that fails at run
// time (here, an index past the end of the history) blocks the deploy.
func TestFailingRuleBlocks(t *testing.T) {
	p := newTestPlat(t)
	withPolicies(t, p, "policies:\n  - name: tenth\n"+
		"    rule: history[9].state == 'succeeded'\n")
	e := wantCode(t, p.run("deploy", "search", "v2.0.0", "-e", "dev"),
		clierr.ExitFailure)
	if !strings.Contains(e.Error(),
		"tenth (cel): check failed to run: rule: index out of bounds: 9") {
		t.Errorf("error: %v", e)
	}
}

// END policies OMIT
// START notifiers OMIT

// webhookPlugin builds the example notifier plugin once.
var webhookPlugin = sync.OnceValues(func() (string, error) {
	dir, err := os.MkdirTemp("", "notifier")
	if err != nil {
		return "", err
	}
	bin := filepath.Join(dir, "platnotify-webhook")
	out, err := exec.Command("go", "build", "-o", bin,
		"../../../cmd/platnotify-webhook").CombinedOutput()
	if err != nil {
		return "", &exec.Error{Name: string(out), Err: err}
	}
	return bin, nil
})

// withNotifier configures the webhook plugin, posting to a test server
// that records the messages, and returns them.
func withNotifier(t *testing.T, p *testPlat, status int) *[]string {
	t.Helper()
	bin, err := webhookPlugin()
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var got []string
	hook := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,
		r *http.Request,
	) {
		var body struct{ Text string }
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &body)
		mu.Lock()
		got = append(got, body.Text)
		mu.Unlock()
		w.WriteHeader(status)
	}))
	t.Cleanup(hook.Close)
	t.Setenv("PLAT_WEBHOOK_URL", hook.URL) // the plugin inherits plat's environment
	dir, _ := p.f.ConfigDir()
	cfg := "notifiers:\n  - name: chat\n    command: [" + bin + "]\n"
	err = os.WriteFile(filepath.Join(dir, "notifiers.yaml"), []byte(cfg), 0o600)
	if err != nil {
		t.Fatal(err)
	}
	return &got
}

func TestDeployNotifies(t *testing.T) {
	p := newTestPlat(t)
	got := withNotifier(t, p, http.StatusOK)
	if err := p.run("deploy", "checkout", "v1.5.0", "-e", "staging",
		"--reason", "INC-412 fix"); err != nil {
		t.Fatal(err)
	}
	want := "✅ checkout v1.5.0 to staging: succeeded (d-9); INC-412 fix"
	if len(*got) != 1 || (*got)[0] != want {
		t.Errorf("webhook got %q, want %q", *got, want)
	}
	if !strings.Contains(p.errOut.String(), "  notified chat: posted to 127.0.0.1:") {
		t.Errorf("stderr:\n%s", p.errOut)
	}
}

// A notifier that fails is a warning: the deploy happened, and its exit
// status says so.
func TestFailingNotifierIsAWarning(t *testing.T) {
	p := newTestPlat(t)
	withNotifier(t, p, http.StatusInternalServerError)
	if err := p.run("deploy", "checkout", "v1.5.0", "-e", "staging"); err != nil {
		t.Fatalf("deploy failed because its notifier did: %v", err)
	}
	if !strings.Contains(p.errOut.String(),
		"  warning: notifier chat: rpc error: code = Unknown desc = "+
			"webhook answered 500 Internal Server Error") {
		t.Errorf("stderr:\n%s", p.errOut)
	}
}

// END notifiers OMIT
