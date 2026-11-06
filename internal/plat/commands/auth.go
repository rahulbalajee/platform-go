package commands

// START imports OMIT

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"text/tabwriter"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/spf13/cobra"
	"golang.org/x/oauth2"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/auth"
	"github.com/rahulbalajee/platform-go/pkg/cli/config"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
)

// END imports OMIT
// START login OMIT

type loginOptions struct {
	F        *factory.Factory
	Provider string
}

func newLoginCmd(f *factory.Factory,
	runF func(context.Context, *loginOptions) error,
) *cobra.Command {
	opts := &loginOptions{F: f}
	cmd := &cobra.Command{
		Use:   "login",
		Short: "Log in to the platform",
		Long: `Log in with the OAuth 2.0 device flow: plat shows a code and a URL,
you approve the login in a browser on any device, and plat stores the
tokens in your OS keychain. Logging in to a context that doesn't exist yet
creates it from --server.`,
		Example: `  plat login --server http://127.0.0.1:8484
  plat login --context gh --server http://127.0.0.1:8484 --provider github`,
		Args: cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			if runF != nil {
				return runF(c.Context(), opts)
			}
			return runLogin(c.Context(), opts)
		},
	}
	cmd.Flags().StringVar(&opts.Provider, "provider", "",
		"how to log in: oidc (the platform's provider) or github")
	return cmd
}

// runLogin logs in to the resolved context, creating it if needed, and
// makes it the current context when there was none.
func runLogin(ctx context.Context, opts *loginOptions) error {
	f := opts.F
	file, err := f.Config()
	if err != nil {
		return err
	}
	c, err := loginContext(f, file, opts.Provider)
	if err != nil {
		return err
	}
	cfg, err := f.OAuth(ctx, c)
	if err != nil {
		return err
	}
	tok, err := auth.Login(ctx, cfg, func(da *oauth2.DeviceAuthResponse) error {
		return showCode(f.IO, da)
	})
	if err != nil {
		return explainLogin(err)
	}
	store, err := f.Store()
	if err != nil {
		return err
	}
	if err := auth.Save(store, c.Name, tok); err != nil {
		return fmt.Errorf("storing the login: %w", err)
	}
	file.SetContext(c)
	if file.CurrentContext == "" {
		file.CurrentContext = c.Name
	}
	if err := f.SaveConfig(file); err != nil {
		return err
	}
	who, err := identity(ctx, f, c, cfg, tok)
	if err != nil {
		who = "(unknown: " + err.Error() + ")"
	}
	fmt.Fprintf(f.IO.ErrOut, "Logged in to %s as %s (context %q, "+
		"credentials in %s)\n", c.Server, who, c.Name, store.Name())
	return nil
}

// END login OMIT
// START logincontext OMIT

// loginContext returns the context to log in to: the one --context,
// PLAT_CONTEXT or current-context names (or "default"), created from
// --server or PLAT_SERVER if it doesn't exist yet.
func loginContext(f *factory.Factory, file *config.File, provider string,
) (config.Context, error) {
	name := f.Context
	if name == "" {
		name = f.Getenv("PLAT_CONTEXT")
	}
	if name == "" {
		name = file.CurrentContext
	}
	if name == "" {
		name = "default"
	}
	server := f.Server
	if server == "" {
		server = f.Getenv("PLAT_SERVER")
	}
	c, exists := file.Context(name)
	if !exists {
		if server == "" {
			return c, &clierr.Error{Code: clierr.ExitUsage,
				Message: fmt.Sprintf("context %q does not exist", name),
				Hint:    "Pass --server URL to create it."}
		}
		c = config.Context{Name: name}
	}
	if server != "" {
		c.Server = server
	}
	if provider != "" {
		c.Provider = provider
	}
	return c, nil
}

// END logincontext OMIT
// START showcode OMIT

// showCode tells the person what to do. The code goes on its own line so
// it is easy to read off a screen share or a second monitor.
func showCode(ios *cli.IOStreams, da *oauth2.DeviceAuthResponse) error {
	if da.VerificationURIComplete != "" {
		_, err := fmt.Fprintf(ios.ErrOut, "To log in, open this page and "+
			"confirm the code:\n\n  %s\n\n  code: %s\n\nWaiting for approval... "+
			"(Ctrl-C to cancel)\n", da.VerificationURIComplete, da.UserCode)
		return err
	}
	_, err := fmt.Fprintf(ios.ErrOut, "To log in, open %s and enter "+
		"the code:\n\n  %s\n\nWaiting for approval... (Ctrl-C to cancel)\n",
		da.VerificationURI, da.UserCode)
	return err
}

// explainLogin turns the ways a login can end into messages.
func explainLogin(err error) error {
	switch {
	case errors.Is(err, auth.ErrDenied):
		return &clierr.Error{Code: clierr.ExitNoPerm, Message: "login denied",
			Err: err}
	case errors.Is(err, auth.ErrCodeExpired):
		return &clierr.Error{Code: clierr.ExitTempFail,
			Message: "the login code expired before it was approved",
			Hint:    "Run 'plat login' again.", Err: err}
	}
	return explain(err, "")
}

// END showcode OMIT
// START identity OMIT

// identity says who tok belongs to. For OIDC it is the verified ID token's
// email. Expiry is not checked: an ID token proves who logged in, and
// whoami should still answer after the access token's ten minutes are up.
// For GitHub it is the login GitHub reports for the token.
func identity(ctx context.Context, f *factory.Factory, c config.Context,
	cfg *oauth2.Config, tok *auth.Token,
) (string, error) {
	if c.Provider == "github" {
		return githubLogin(ctx, f, tok.AccessToken)
	}
	issuer := c.Issuer
	if issuer == "" {
		issuer = c.Server
	}
	ctx = oidc.ClientContext(ctx, f.HTTPClient())
	p, err := oidc.NewProvider(ctx, issuer)
	if err != nil {
		return "", err
	}
	v := p.Verifier(&oidc.Config{ClientID: cfg.ClientID, SkipExpiryCheck: true})
	id, err := v.Verify(ctx, tok.IDToken)
	if err != nil {
		return "", fmt.Errorf("verifying the ID token: %w", err)
	}
	var claims struct {
		Email string `json:"email"`
	}
	if err := id.Claims(&claims); err == nil && claims.Email != "" {
		return claims.Email, nil
	}
	return id.Subject, nil
}

// githubLogin returns the GitHub login that owns token.
func githubLogin(ctx context.Context, f *factory.Factory, token string,
) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		f.GitHubAPI+"/user", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := f.HTTPClient().Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GitHub answered %s", resp.Status)
	}
	var u struct {
		Login string `json:"login"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&u); err != nil {
		return "", err
	}
	return "github:" + u.Login, nil
}

// END identity OMIT
// START logout OMIT

func newLogoutCmd(f *factory.Factory) *cobra.Command {
	return &cobra.Command{
		Use:   "logout",
		Short: "Forget the stored login of the current context",
		Args:  cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			r, err := f.Resolve()
			if err != nil {
				return err
			}
			if r.Context.Name == "" {
				return notLoggedIn("no context is selected")
			}
			store, err := f.Store()
			if err != nil {
				return err
			}
			if err := store.Delete(r.Context.Name); err != nil {
				return err
			}
			fmt.Fprintf(f.IO.ErrOut, "Logged out of context %q\n", r.Context.Name)
			return nil
		},
	}
}

// END logout OMIT
// START whoami OMIT

func newWhoamiCmd(f *factory.Factory) *cobra.Command {
	return &cobra.Command{
		Use:   "whoami",
		Short: "Print who you are logged in as",
		Args:  cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			ctx := c.Context()
			if f.Getenv("PLAT_TOKEN") != "" {
				_, err := fmt.Fprintln(f.IO.Out, "(PLAT_TOKEN from the environment)")
				return err
			}
			r, tok, err := currentLogin(ctx, f)
			if err != nil {
				return err
			}
			cfg, err := f.OAuth(ctx, r.Context)
			if err != nil {
				return err
			}
			who, err := identity(ctx, f, r.Context, cfg, tok)
			if err != nil {
				return err
			}
			_, err = fmt.Fprintln(f.IO.Out, who)
			return err
		},
	}
}

// currentLogin returns the resolved context and its stored login,
// refreshed if the access token had expired.
func currentLogin(ctx context.Context, f *factory.Factory,
) (config.Resolved, *auth.Token, error) {
	r, err := f.Resolve()
	if err != nil {
		return r, nil, err
	}
	if r.Context.Name == "" {
		return r, nil, notLoggedIn("no context is selected")
	}
	src, err := f.TokenSource(ctx, r.Context)
	if err != nil {
		return r, nil, err
	}
	if _, err := src.Token(); err != nil {
		return r, nil, explain(err, "")
	}
	store, err := f.Store()
	if err != nil {
		return r, nil, err
	}
	tok, err := auth.Load(store, r.Context.Name)
	return r, tok, err
}

func notLoggedIn(why string) error {
	return &clierr.Error{Code: clierr.ExitNoPerm, ID: "PLAT-LOGIN",
		Message: "not logged in: " + why,
		Hint:    "Run 'plat login --server URL'."}
}

// END whoami OMIT
// START authgroup OMIT

func newAuthCmd(f *factory.Factory) *cobra.Command {
	cmd := cli.Group(&cobra.Command{
		Use:   "auth",
		Short: "Inspect and use the stored login",
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "token",
		Short: "Print a valid access token, for scripts",
		Long: `Print the current context's access token, refreshing it first if it
has expired. Use it to call the API with other tools:

  curl -H "Authorization: Bearer $(plat auth token)" "$SERVER/v1/services"

The token is a credential: don't paste it into chats or logs.`,
		Args: cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			_, tok, err := currentLogin(c.Context(), f)
			if err != nil {
				return err
			}
			_, err = fmt.Fprintln(f.IO.Out, tok.AccessToken)
			return err
		},
	}, newAuthStatusCmd(f))
	return cmd
}

// END authgroup OMIT
// START status OMIT

// newAuthStatusCmd shows what plat will use and where each piece came from.
// It never fails because of a missing login: it is what you run to find
// out why other commands fail.
func newAuthStatusCmd(f *factory.Factory) *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show the context, server and login plat would use",
		Args:  cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			r, err := f.Resolve()
			if err != nil {
				return err
			}
			tw := tabwriter.NewWriter(f.IO.Out, 0, 0, 2, ' ', 0)
			fmt.Fprintf(tw, "Context:\t%s\n", origin(r.Context.Name, r.ContextOrigin))
			fmt.Fprintf(tw, "Server:\t%s\n", origin(r.Context.Server, r.ServerOrigin))
			provider := r.Context.Provider
			if provider == "" {
				provider = "oidc"
			}
			fmt.Fprintf(tw, "Provider:\t%s\n", provider)
			fmt.Fprintf(tw, "Login:\t%s\n", loginState(f, r.Context.Name))
			return tw.Flush()
		},
	}
}

func origin(value, from string) string {
	if value == "" {
		return "(none)"
	}
	return fmt.Sprintf("%s (from %s)", value, from)
}

func loginState(f *factory.Factory, name string) string {
	if f.Getenv("PLAT_TOKEN") != "" {
		return "PLAT_TOKEN from the environment (overrides any stored login)"
	}
	if name == "" {
		return "not logged in"
	}
	store, err := f.Store()
	if err != nil {
		return "unknown: " + err.Error()
	}
	tok, err := auth.Load(store, name)
	switch {
	case errors.Is(err, auth.ErrNotFound):
		return "not logged in"
	case err != nil:
		return "unknown: " + err.Error()
	}
	refresh := "no refresh token"
	if tok.RefreshToken != "" {
		refresh = "refreshable"
	}
	state := "expired"
	if tok.Expiry.After(time.Now()) {
		state = "valid until " + tok.Expiry.Local().Format(time.TimeOnly)
	}
	return fmt.Sprintf("%s, %s (stored in %s)", state, refresh, store.Name())
}

// END status OMIT
