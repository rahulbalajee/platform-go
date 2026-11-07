// START head OMIT

// Package policy checks a deployment against the rules a platform team
// writes in CEL, the Common Expression Language that Kubernetes admission
// policies, Envoy and Google Cloud IAM use. A rule is an expression, not a
// program: it can't loop forever, touch files or call the network, it is
// type-checked when it loads, and its cost is capped when it runs. That is
// what makes it safe to load rules from a repository you just cloned.
//
// Policies run in the client, so they are fast feedback, not security: a
// user can always skip a check their own machine runs. Rules that must
// hold belong on the server too.
package policy

// END head OMIT
// START imports OMIT

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"time"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common"
	"cel.dev/cel-go/ext"
	"sigs.k8s.io/yaml"
)

// END imports OMIT
// START input OMIT

// Input is what a policy can see, as the CEL variables request, service,
// history and now. Field names in CEL are the cel tags: request.environment.
// The JSON names match, for checks that read Input as JSON (package wasmext).
type Input struct {
	Request Request      `json:"request"`
	Service Service      `json:"service"`
	History []Deployment `json:"history"` // latest deployments, newest first
	Now     time.Time    `json:"now"`
}

// Request is the deployment being asked for.
type Request struct {
	Service     string `json:"service" cel:"service"`
	Environment string `json:"environment" cel:"environment"`
	Version     string `json:"version" cel:"version"`
	Reason      string `json:"reason" cel:"reason"`
	User        string `json:"user" cel:"user"` // empty when not known
}

// Service is the service being deployed, as the platform describes it.
type Service struct {
	Name     string `json:"name" cel:"name"`
	Team     string `json:"team" cel:"team"`
	Repo     string `json:"repo" cel:"repo"`
	Replicas int    `json:"replicas" cel:"replicas"`
}

// Deployment is one earlier deployment of the service.
type Deployment struct {
	ID          string    `json:"id" cel:"id"`
	Environment string    `json:"environment" cel:"environment"`
	Version     string    `json:"version" cel:"version"`
	State       string    `json:"state" cel:"state"`
	CreatedAt   time.Time `json:"created_at" cel:"created_at"`
}

// END input OMIT
// START policy OMIT

// Policy is one rule, as written in a policy file:
//
//	policies:
//	  - name: staging-first
//	    match: request.environment == "prod"
//	    rule: >-
//	      history.exists(d, d.environment == "staging"
//	        && d.version == request.version && d.state == "succeeded")
//	    message: a version must succeed in staging before it goes to prod
//
// Match selects the deployments the rule applies to (empty: all of them).
// Rule must be true for the deployment to go ahead. MessageExpression, a
// CEL string, explains a failure with values; Message is a fixed text.
type Policy struct {
	Name              string `json:"name"`
	Description       string `json:"description,omitempty"`
	Match             string `json:"match,omitempty"`
	Rule              string `json:"rule"`
	Message           string `json:"message,omitempty"`
	MessageExpression string `json:"messageExpression,omitempty"`
}

type file struct {
	Policies []Policy `json:"policies"`
}

// END policy OMIT
// START result OMIT

// Status is the outcome of one check.
type Status string

// The outcomes. An Error (a rule that failed to evaluate, or a check that
// crashed) blocks the deployment like a Fail: a check that can't answer
// has not said yes.
const (
	Pass  Status = "pass"
	Fail  Status = "fail"
	Skip  Status = "skip" // the match expression was false
	Error Status = "error"
)

// Result is the outcome of one policy or check for one deployment.
type Result struct {
	Name    string `json:"name"`
	Kind    string `json:"kind"`   // "cel" or "wasm"
	Source  string `json:"source"` // the file it came from
	Status  Status `json:"status"`
	Message string `json:"message,omitempty"`
}

// Blocking returns the results that stop a deployment.
func Blocking(results []Result) []Result {
	return slices.DeleteFunc(slices.Clone(results), func(r Result) bool {
		return r.Status != Fail && r.Status != Error
	})
}

// END result OMIT
// START env OMIT

// Limits on evaluation. CEL charges every operation a cost; a rule over a
// list of history costs a few units per element. One million is
// Kubernetes' limit per expression, far above any rule over 20 deployments
// and far below a rule that could stall a deploy. The cost limit is the
// same on every machine; DefaultTimeout is a backstop in wall-clock time.
const (
	costLimit      = 1_000_000
	DefaultTimeout = time.Second
)

// newEnv declares the variables and their types, so a rule that misspells
// a field or compares a string with a number fails when it is loaded, with
// the position of the mistake, instead of when someone deploys.
func newEnv() (*cel.Env, error) {
	return cel.NewEnv(
		ext.NativeTypes(reflect.TypeFor[Request](), reflect.TypeFor[Service](),
			reflect.TypeFor[Deployment](), ext.ParseStructTags(true)),
		cel.Variable("request", cel.ObjectType("policy.Request")),
		cel.Variable("service", cel.ObjectType("policy.Service")),
		cel.Variable("history", cel.ListType(cel.ObjectType("policy.Deployment"))),
		cel.Variable("now", cel.TimestampType),
		ext.Strings(), // lowerAscii, split, ...
	)
}

// END env OMIT
// START compile OMIT

// Set is a list of compiled policies, ready to check deployments.
type Set struct {
	// Timeout bounds the evaluation of each policy; zero means
	// DefaultTimeout.
	Timeout  time.Duration
	policies []compiled
}

type compiled struct {
	Policy
	source               string
	match, rule, explain cel.Program // match and explain may be nil
}

// Len reports how many policies the set holds.
func (s *Set) Len() int { return len(s.policies) }

// Names lists the policies with the file each came from.
func (s *Set) Names() []Result {
	var out []Result
	for _, p := range s.policies {
		out = append(out, Result{Name: p.Name, Kind: "cel", Source: p.source})
	}
	return out
}

// Compile compiles policies read from source (a file name, for messages).
// It reports every broken policy, not just the first.
func Compile(source string, policies []Policy) (*Set, error) {
	env, err := newEnv()
	if err != nil {
		return nil, err
	}
	s := &Set{}
	var errs []error
	for _, p := range policies {
		c, err := compile(env, source, p)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		s.policies = append(s.policies, c)
	}
	return s, errors.Join(errs...)
}

func compile(env *cel.Env, source string, p Policy) (compiled, error) {
	c := compiled{Policy: p, source: source}
	if p.Name == "" || p.Rule == "" {
		return c, fmt.Errorf("%s: every policy needs a name and a rule", source)
	}
	var err error
	where := func(field string) string {
		return fmt.Sprintf("%s: policy %s, %s", source, p.Name, field)
	}
	if c.rule, err = program(env, p.Rule, where("rule"), cel.BoolType); err != nil {
		return c, err
	}
	if p.Match != "" {
		c.match, err = program(env, p.Match, where("match"), cel.BoolType)
		if err != nil {
			return c, err
		}
	}
	if p.MessageExpression != "" {
		c.explain, err = program(env, p.MessageExpression,
			where("messageExpression"), cel.StringType)
	}
	return c, err
}

// program parses, type-checks and plans one expression.
func program(env *cel.Env, expr, where string, want *cel.Type) (cel.Program, error) {
	ast, iss := env.CompileSource(common.NewStringSource(expr, where))
	if err := iss.Err(); err != nil {
		return nil, err // "ERROR: where:1:9: undefined field 'envronment'" + caret
	}
	if !ast.OutputType().IsExactType(want) {
		return nil, fmt.Errorf("%s: want a %s expression, not %s",
			where, want, ast.OutputType())
	}
	return env.Program(ast, cel.CostLimit(costLimit),
		cel.InterruptCheckFrequency(100))
}

// END compile OMIT
// START load OMIT

// Load compiles every *.yaml and *.yml policy file in dirs, in name order.
// A directory that doesn't exist holds no policies. Unknown fields are
// errors, so "rul:" for "rule:" can't silently disable a policy.
func Load(dirs ...string) (*Set, error) {
	all := &Set{}
	var errs []error
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			ext := filepath.Ext(e.Name())
			if e.IsDir() || (ext != ".yaml" && ext != ".yml") {
				continue
			}
			path := filepath.Join(dir, e.Name())
			s, err := loadFile(path)
			if err != nil {
				errs = append(errs, err)
			}
			if s != nil {
				all.policies = append(all.policies, s.policies...)
			}
		}
	}
	return all, errors.Join(errs...)
}

func loadFile(path string) (*Set, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f file
	if err := yaml.UnmarshalStrict(b, &f); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return Compile(path, f.Policies)
}

// END load OMIT
// START check OMIT

// Check evaluates every policy against in.
func (s *Set) Check(ctx context.Context, in Input) []Result {
	vars := map[string]any{"request": in.Request, "service": in.Service,
		"history": in.History, "now": in.Now}
	timeout := cmp.Or(s.Timeout, DefaultTimeout)
	var out []Result
	for _, p := range s.policies {
		r := Result{Name: p.Name, Kind: "cel", Source: p.source}
		r.Status, r.Message = p.check(ctx, vars, timeout)
		out = append(out, r)
	}
	return out
}

func (p compiled) check(ctx context.Context, vars map[string]any,
	timeout time.Duration,
) (Status, string) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if p.match != nil {
		ok, err := evalBool(ctx, p.match, vars)
		if err != nil {
			return Error, "match: " + err.Error()
		}
		if !ok {
			return Skip, ""
		}
	}
	ok, err := evalBool(ctx, p.rule, vars)
	switch {
	case err != nil:
		return Error, "rule: " + err.Error()
	case ok:
		return Pass, ""
	}
	msg := p.Message
	if p.explain != nil {
		if v, _, err := p.explain.ContextEval(ctx, vars); err == nil {
			msg, _ = v.Value().(string)
		}
	}
	if msg == "" {
		msg = "rule is false: " + strings.Join(strings.Fields(p.Rule), " ")
	}
	return Fail, msg
}

func evalBool(ctx context.Context, prg cel.Program,
	vars map[string]any,
) (bool, error) {
	v, _, err := prg.ContextEval(ctx, vars)
	if err != nil {
		return false, err // "no such key", "runtime cost limit exceeded", ...
	}
	b, ok := v.Value().(bool)
	if !ok {
		return false, fmt.Errorf("result is %v, not a bool", v)
	}
	return b, nil
}

// END check OMIT
