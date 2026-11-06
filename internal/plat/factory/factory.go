// START head OMIT

// Package factory builds the dependencies plat's commands share, lazily: a
// command that prints the version never reads configuration or opens a
// connection, and a test replaces any piece by assigning a field.
package factory

// END head OMIT
// START imports OMIT

import (
	"errors"
	"net/http"
	"os"

	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START factory OMIT

// Factory is what every command receives. Fields that are functions are
// called when a command needs them, after flags are parsed, so a --server
// flag on the command line is already in Server when Client runs.
type Factory struct {
	IO      *cli.IOStreams
	Version string // the plat version, for the User-Agent and `plat version`

	// Server is the platform API's base URL: the --server flag, else
	// PLAT_SERVER.
	Server string

	Getenv     func(string) string
	HTTPClient func() *http.Client
	Client     func() (*platformapi.Client, error)
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
	}
	f.Client = func() (*platformapi.Client, error) { return newClient(f) }
	return f
}

// END new OMIT
// START client OMIT

// newClient builds the API client from the server and token. The token
// comes only from the environment: a --token flag would end up in shell
// history and in `ps` output for everyone on the machine to read.
func newClient(f *Factory) (*platformapi.Client, error) {
	server := f.Server
	if server == "" {
		server = f.Getenv("PLAT_SERVER")
	}
	if server == "" {
		return nil, &clierr.Error{
			Code:    clierr.ExitUsage,
			Message: "no platform server configured",
			Hint:    "Pass --server URL or set PLAT_SERVER.",
			Err:     errNoServer,
		}
	}
	opts := []platformapi.Option{
		platformapi.WithHTTPClient(f.HTTPClient()),
		platformapi.WithUserAgent("plat/" + f.Version),
	}
	if token := f.Getenv("PLAT_TOKEN"); token != "" {
		opts = append(opts, platformapi.WithToken(token))
	}
	return platformapi.New(server, opts...)
}

var errNoServer = errors.New("no server URL")

// END client OMIT
