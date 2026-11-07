// START head OMIT

// Package factory builds the dependencies plat's commands share, lazily: a
// command that prints the version never reads configuration or opens a
// connection, and a test replaces any piece by assigning a field.
package factory

// END head OMIT
// START imports OMIT

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
	"golang.org/x/oauth2/endpoints"

	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/auth"
	"github.com/rahulbalajee/platform-go/pkg/cli/config"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START consts OMIT

// Login defaults. The GitHub client ID belongs to the "plat (Platform Go)"
// OAuth App. Client IDs of public clients are not secrets: every copy of
// the binary carries this one, and the device flow needs no secret at all.
const (
	DefaultClientID = "plat"
	GitHubClientID  = "Ov23li5W53rwQVezfLOU"
)

// END consts OMIT
// START factory OMIT

// Factory is what every command receives. Fields that are functions are
// called when a command needs them, after flags are parsed, so --server and
// --context are already set when Resolve runs.
type Factory struct {
	IO      *cli.IOStreams
	Version string // the plat version, for the User-Agent and `plat version`

	Server  string // the --server flag
	Context string // the --context flag

	Getenv     func(string) string
	HTTPClient func() *http.Client
	GitHubAPI  string // the GitHub REST API, for GitHub logins

	ConfigDir  func() (string, error)
	CacheDir   func() (string, error) // compiled WASM checks (Ch 10)
	WorkDir    func() (string, error) // where repository policies are looked for
	Now        func() time.Time
	Config     func() (*config.File, error) // loaded once per process
	SaveConfig func(*config.File) error
	Resolve    func() (config.Resolved, error)
	Store      func() (auth.Store, error) // opened once per process

	// OAuth returns the login configuration for a context: discovery for
	// an OIDC provider, fixed endpoints for GitHub.
	OAuth  func(ctx context.Context, c config.Context) (*oauth2.Config, error)
	Client func() (*platformapi.Client, error)
}

// END factory OMIT
// START new OMIT

// New returns the Factory plat's main function uses.
func New(ios *cli.IOStreams, version string) *Factory {
	f := &Factory{
		IO:         ios,
		Version:    version,
		Getenv:     os.Getenv,
		HTTPClient: func() *http.Client { return http.DefaultClient },
		GitHubAPI:  "https://api.github.com",
	}
	f.ConfigDir = func() (string, error) {
		if d := f.Getenv("PLAT_CONFIG_DIR"); d != "" {
			return d, nil
		}
		return config.Dir("plat", f.Getenv)
	}
	f.CacheDir = func() (string, error) {
		if d := f.Getenv("PLAT_CACHE_DIR"); d != "" {
			return d, nil
		}
		d, err := os.UserCacheDir()
		return filepath.Join(d, "plat"), err
	}
	f.WorkDir, f.Now = os.Getwd, time.Now
	f.Config = sync.OnceValues(func() (*config.File, error) {
		path, err := f.configPath()
		if err != nil {
			return nil, err
		}
		return config.Load(path)
	})
	f.SaveConfig = func(c *config.File) error {
		path, err := f.configPath()
		if err != nil {
			return err
		}
		return c.Save(path)
	}
	f.Resolve = func() (config.Resolved, error) { return resolve(f) }
	f.Store = sync.OnceValues(func() (auth.Store, error) { return openStore(f) })
	f.OAuth = func(ctx context.Context, c config.Context) (*oauth2.Config, error) {
		return oauthConfig(ctx, f, c)
	}
	f.Client = func() (*platformapi.Client, error) { return newClient(f) }
	return f
}

func (f *Factory) configPath() (string, error) {
	dir, err := f.ConfigDir()
	return filepath.Join(dir, "config.yaml"), err
}

// END new OMIT
// START resolve OMIT

// resolve picks the context and server, turning a missing context into a
// message that says where the name came from.
func resolve(f *Factory) (config.Resolved, error) {
	file, err := f.Config()
	if err != nil {
		return config.Resolved{}, &clierr.Error{Code: clierr.ExitUsage,
			Message: "cannot read the plat configuration", Err: err}
	}
	r, err := file.Resolve(f.Context, f.Server, "PLAT", f.Getenv)
	if nf, ok := errors.AsType[*config.NotFoundError](err); ok {
		return r, &clierr.Error{Code: clierr.ExitUsage, Message: nf.Error(),
			Hint: "List contexts with 'plat config get-contexts'.", Err: err}
	}
	return r, err
}

// openStore opens the credential store named by PLAT_CREDENTIAL_STORE
// (auto by default) and warns once if tokens will sit in a plain file.
func openStore(f *Factory) (auth.Store, error) {
	dir, err := f.ConfigDir()
	if err != nil {
		return nil, err
	}
	s, warning, err := auth.Open("plat", dir, f.Getenv("PLAT_CREDENTIAL_STORE"))
	if warning != "" {
		fmt.Fprintf(f.IO.ErrOut, "warning: %s\n", warning)
	}
	return s, err
}

// END resolve OMIT
// START oauth OMIT

// oauthConfig builds the login configuration for c. OIDC providers publish
// their endpoints at a well-known URL, so any compliant one works: this dev
// provider, Dex, Keycloak, Okta, Entra ID.
func oauthConfig(ctx context.Context, f *Factory, c config.Context,
) (*oauth2.Config, error) {
	switch c.Provider {
	case "github":
		id := c.ClientID
		if id == "" {
			id = GitHubClientID
		}
		return auth.NewConfig(id, endpoints.GitHub), nil
	case "", "oidc":
		issuer := c.Issuer
		if issuer == "" {
			issuer = c.Server
		}
		ctx = oidc.ClientContext(ctx, f.HTTPClient())
		p, err := oidc.NewProvider(ctx, issuer)
		if err != nil {
			return nil, fmt.Errorf("discovering the login provider at %s: %w",
				issuer, err)
		}
		id := c.ClientID
		if id == "" {
			id = DefaultClientID
		}
		return auth.NewConfig(id, p.Endpoint(), oidc.ScopeOpenID, "email"), nil
	}
	return nil, &clierr.Error{Code: clierr.ExitUsage,
		Message: fmt.Sprintf("context %q has unknown provider %q",
			c.Name, c.Provider),
		Hint: "Use oidc or github: plat config set-context NAME --provider oidc"}
}

// END oauth OMIT
// START client OMIT

// newClient builds the API client for the resolved context. The token comes
// from PLAT_TOKEN if set (CI jobs use a service token that way), otherwise
// from the context's stored login. Never from a flag: a --token flag would
// end up in shell history and in `ps` output for everyone on the machine.
func newClient(f *Factory) (*platformapi.Client, error) {
	r, err := f.Resolve()
	if err != nil {
		return nil, err
	}
	if r.Context.Server == "" {
		return nil, &clierr.Error{
			Code:    clierr.ExitUsage,
			Message: "no platform server configured",
			Hint:    "Run 'plat login --server URL', or set PLAT_SERVER.",
			Err:     errNoServer,
		}
	}
	opts := []platformapi.Option{
		platformapi.WithHTTPClient(f.HTTPClient()),
		platformapi.WithUserAgent("plat/" + f.Version),
	}
	switch {
	case f.Getenv("PLAT_TOKEN") != "":
		opts = append(opts, platformapi.WithToken(f.Getenv("PLAT_TOKEN")))
	case r.Context.Name != "":
		src, err := f.TokenSource(context.Background(), r.Context)
		if err != nil {
			return nil, err
		}
		opts = append(opts, platformapi.WithTokenSource(apiTokens{src}))
	}
	return platformapi.New(r.Context.Server, opts...)
}

var errNoServer = errors.New("no server URL")

// END client OMIT
// START tokensource OMIT

// TokenSource returns the refreshing source for c's stored login.
func (f *Factory) TokenSource(ctx context.Context, c config.Context,
) (*auth.Source, error) {
	store, err := f.Store()
	if err != nil {
		return nil, err
	}
	dir, err := f.ConfigDir()
	if err != nil {
		return nil, err
	}
	lock := filepath.Join(dir, "refresh-"+c.Name+".lock")
	cfg := func() (*oauth2.Config, error) { return f.OAuth(ctx, c) }
	return auth.NewSource(ctx, cfg, store, c.Name, lock), nil
}

// apiTokens adapts an auth.Source to the SDK. The SDK calls Token before
// every request, and InvalidateToken when the server answers 401: the
// source then refreshes and the SDK retries the request once.
type apiTokens struct{ src *auth.Source }

func (a apiTokens) Token(context.Context) (string, error) {
	t, err := a.src.Token()
	if err != nil {
		return "", err
	}
	return t.AccessToken, nil
}

func (a apiTokens) InvalidateToken(rejected string) { a.src.Invalidate(rejected) }

// END tokensource OMIT
