package commands

// START imports OMIT

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/internal/plat/policy"
	"github.com/rahulbalajee/platform-go/internal/plat/wasmext"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START load OMIT

// checks are the pre-deploy checks plat found: CEL policies (*.yaml) and
// WASM checks (*.wasm) from the user's configuration directory and from
// the repository plat runs in. Both can only refuse a deployment, which is
// why a cloned repository may bring its own.
type checks struct {
	cel  *policy.Set
	wasm *wasmext.Runner
}

// policyDirs are where checks live: $CONFIG/policies for the ones a
// platform team installs, and .plat/policies in the working directory for
// a repository's own.
func policyDirs(f *factory.Factory) ([]string, error) {
	cfg, err := f.ConfigDir()
	if err != nil {
		return nil, err
	}
	wd, err := f.WorkDir()
	if err != nil {
		return nil, err
	}
	return []string{filepath.Join(cfg, "policies"),
		filepath.Join(wd, ".plat", "policies")}, nil
}

// loadChecks compiles every check. A policy that doesn't compile is a
// usage error that names the file: nothing deploys past a broken rule.
func loadChecks(ctx context.Context, f *factory.Factory) (*checks, error) {
	dirs, err := policyDirs(f)
	if err != nil {
		return nil, err
	}
	cel, err := policy.Load(dirs...)
	if err != nil {
		return nil, brokenChecks(err)
	}
	cache, err := f.CacheDir()
	if err != nil {
		return nil, err
	}
	wasm, err := wasmext.Load(ctx, filepath.Join(cache, "wasm"), dirs...)
	if err != nil {
		return nil, brokenChecks(err)
	}
	return &checks{cel: cel, wasm: wasm}, nil
}

func brokenChecks(err error) error {
	return &clierr.Error{Code: clierr.ExitUsage, ID: "PLAT-POLICY-LOAD",
		Message: "cannot load the pre-deploy checks", Err: err,
		Hint: "Fix or remove the file named above; 'plat policy list' shows " +
			"where checks are read from."}
}

func (c *checks) close(ctx context.Context) { _ = c.wasm.Close(ctx) }

func (c *checks) len() int { return c.cel.Len() + c.wasm.Len() }

// names lists every check, CEL first.
func (c *checks) names() []policy.Result {
	return append(c.cel.Names(), c.wasm.Names()...)
}

// run evaluates every check against in.
func (c *checks) run(ctx context.Context, in policy.Input) []policy.Result {
	return append(c.cel.Check(ctx, in), c.wasm.Check(ctx, in)...)
}

// END load OMIT
// START input OMIT

// checkInput gathers what checks see: the request, the service as the
// platform knows it, and the service's latest deployments, newest first.
func checkInput(ctx context.Context, client *platformapi.Client,
	req policy.Request, f *factory.Factory,
) (policy.Input, error) {
	in := policy.Input{Request: req, Now: f.Now().UTC(),
		History: []policy.Deployment{}}
	s, err := client.GetService(ctx, req.Service)
	if err != nil {
		return in, explain(err, fmt.Sprintf("service %q", req.Service))
	}
	in.Service = policy.Service{Name: s.Name, Team: s.Team, Repo: s.Repo,
		Replicas: s.Replicas}
	for d, err := range client.ListDeployments(ctx,
		platformapi.DeploymentFilter{Service: req.Service},
		platformapi.PageSize(20)) {
		if err != nil {
			return in, explain(err, "")
		}
		in.History = append(in.History, policy.Deployment{ID: d.ID,
			Environment: d.Environment, Version: d.Version,
			State: string(d.State), CreatedAt: d.CreatedAt})
		if len(in.History) == 20 {
			break
		}
	}
	return in, nil
}

// END input OMIT
// START refused OMIT

// refused is the error for a deployment the checks stopped: exit status 1,
// one detail line per check that said no.
func refused(blocking []policy.Result) error {
	var errs []error
	for _, r := range blocking {
		msg := r.Message
		if r.Status == policy.Error {
			msg = "check failed to run: " + msg
		}
		errs = append(errs, fmt.Errorf("%s (%s): %s", r.Name, r.Kind, msg))
	}
	what := "check"
	if len(blocking) > 1 {
		what = "checks"
	}
	return &clierr.Error{Code: clierr.ExitFailure, ID: "PLAT-POLICY",
		Message: fmt.Sprintf("refused by %d pre-deploy %s", len(blocking), what),
		Hint: "Nothing was deployed. Run 'plat policy check' with the same " +
			"arguments to see every check.",
		Err: errors.Join(errs...)}
}

// summary is the one line deploy prints about checks that passed.
func summary(results []policy.Result) string {
	n := map[policy.Status]int{}
	for _, r := range results {
		n[r.Status]++
	}
	parts := []string{fmt.Sprintf("%d passed", n[policy.Pass])}
	if n[policy.Skip] > 0 {
		parts = append(parts, fmt.Sprintf("%d not applicable", n[policy.Skip]))
	}
	return "Pre-deploy checks: " + strings.Join(parts, ", ")
}

// END refused OMIT
