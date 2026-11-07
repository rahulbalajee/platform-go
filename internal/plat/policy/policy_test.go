package policy_test

// START imports OMIT

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rahulbalajee/platform-go/internal/plat/policy"
)

// END imports OMIT
// START fixtures OMIT

// The rules of a platform team, as one policy file.
const rules = `policies:
  - name: staging-first
    match: request.environment == "prod"
    rule: >-
      history.exists(d, d.environment == "staging"
        && d.version == request.version && d.state == "succeeded")
    message: a version must succeed in staging before it goes to prod
  - name: prod-needs-ticket
    match: request.environment == "prod"
    rule: request.reason.matches('^[A-Z]+-[0-9]+')
    messageExpression: >-
      "prod deploys need --reason starting with a ticket, such as INC-412; got '"
        + request.reason + "'"
  - name: friday-freeze
    match: request.environment == "prod"
    rule: >-
      !(now.getDayOfWeek("Asia/Kolkata") == 5
        && now.getHours("Asia/Kolkata") >= 16)
    message: no prod deploys after 16:00 IST on Fridays
`

// friday is 16:30 in Kolkata on a Friday.
var friday = time.Date(2026, 11, 6, 11, 0, 0, 0, time.UTC)

func input(env, version, reason string, at time.Time) policy.Input {
	return policy.Input{
		Request: policy.Request{Service: "checkout", Environment: env,
			Version: version, Reason: reason},
		Service: policy.Service{Name: "checkout", Team: "payments", Replicas: 4},
		History: []policy.Deployment{{ID: "d-8", Environment: "staging",
			Version: "v1.4.1", State: "succeeded"}},
		Now: at,
	}
}

func load(t *testing.T, yaml string) *policy.Set {
	t.Helper()
	dir := t.TempDir()
	err := os.WriteFile(filepath.Join(dir, "rules.yaml"), []byte(yaml), 0o600)
	if err != nil {
		t.Fatal(err)
	}
	s, err := policy.Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// statuses renders results as "name=status" for compact comparison.
func statuses(rs []policy.Result) string {
	var b []string
	for _, r := range rs {
		b = append(b, r.Name+"="+string(r.Status))
	}
	return strings.Join(b, " ")
}

// END fixtures OMIT
// START check OMIT

func TestRules(t *testing.T) {
	s := load(t, rules)
	monday := friday.AddDate(0, 0, -4)
	for _, tc := range []struct {
		name string
		in   policy.Input
		want string
	}{
		{"staging is not matched", input("staging", "v1.5.0", "", friday),
			"staging-first=skip prod-needs-ticket=skip friday-freeze=skip"},
		{"prod, all good", input("prod", "v1.4.1", "INC-412 fix", monday),
			"staging-first=pass prod-needs-ticket=pass friday-freeze=pass"},
		{"prod, untested, no ticket, Friday", input("prod", "v1.5.0", "fix", friday),
			"staging-first=fail prod-needs-ticket=fail friday-freeze=fail"},
	} {
		got := statuses(s.Check(context.Background(), tc.in))
		if got != tc.want {
			t.Errorf("%s:\n got %s\nwant %s", tc.name, got, tc.want)
		}
	}
}

func TestMessages(t *testing.T) {
	s := load(t, rules)
	rs := policy.Blocking(s.Check(context.Background(),
		input("prod", "v1.4.1", "quick fix", friday.AddDate(0, 0, -1))))
	if len(rs) != 1 {
		t.Fatalf("blocking: %+v", rs)
	}
	want := "prod deploys need --reason starting with a ticket, " +
		"such as INC-412; got 'quick fix'"
	if rs[0].Message != want {
		t.Errorf("message = %q\nwant %q", rs[0].Message, want)
	}
}

// END check OMIT
// START compile OMIT

// Mistakes are found when the policies load, with the place they are in,
// not on the day someone deploys.
func TestLoadErrors(t *testing.T) {
	for _, tc := range []struct{ yaml, want string }{
		{"policies:\n  - name: typo\n    rule: request.envronment == 'prod'\n",
			"undefined field 'envronment'"},
		{"policies:\n  - name: types\n    rule: service.replicas > '3'\n",
			"found no matching overload for '_>_'"},
		{"policies:\n  - name: not-bool\n    rule: request.reason\n",
			"want a bool expression, not string"},
		{"policies:\n  - name: misspelt-key\n    rul: true\n",
			`unknown field "rul"`},
		{"policies:\n  - rule: 'true'\n", "every policy needs a name and a rule"},
	} {
		dir := t.TempDir()
		err := os.WriteFile(filepath.Join(dir, "p.yaml"), []byte(tc.yaml), 0o600)
		if err != nil {
			t.Fatal(err)
		}
		_, err = policy.Load(dir)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%q:\n got %v\nwant an error containing %q",
				tc.yaml, err, tc.want)
		}
		if err != nil && !strings.Contains(err.Error(), "p.yaml") {
			t.Errorf("error does not name the file: %v", err)
		}
	}
}

// A rule that would take too long is stopped by the cost limit and
// reported as an error, which blocks the deployment. CEL charges for work,
// not time: joining two 10 KB strings costs about 2,000 units, so this rule
// reaches the limit of a million within a few hundred joins, on any
// machine, long before the one-second time limit could stop it instead.
func TestCostLimit(t *testing.T) {
	s := load(t, `policies:
  - name: expensive
    rule: >-
      history.all(a, history.all(b, (a.version + b.version).size() > 0))
`)
	in := input("prod", "v1", "", friday)
	long := strings.Repeat("v", 10_000)
	for range 200 {
		in.History = append(in.History, policy.Deployment{ID: "d", Version: long})
	}
	start := time.Now()
	rs := s.Check(context.Background(), in)
	t.Logf("stopped after %v", time.Since(start))
	if rs[0].Status != policy.Error ||
		!strings.Contains(rs[0].Message, "cost limit") {
		t.Errorf("got %+v, want an error for the cost limit", rs[0])
	}
}

// END compile OMIT
