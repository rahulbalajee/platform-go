package commands

// START imports OMIT

import (
	"errors"
	"fmt"
	"net"
	"net/http"

	"github.com/rahulbalajee/platform-go/pkg/cli/auth"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START explain OMIT

// explain turns an error from the SDK into one a person can act on: what
// went wrong in their terms, the exit code scripts branch on, and the next
// command to run. what names the thing the call was about ("service
// \"checkout\""), for not-found errors. Errors it doesn't recognise pass
// through; clierr still reports them, with exit code 1.
func explain(err error, what string) error {
	if err == nil {
		return nil
	}
	switch {
	case errors.Is(err, auth.ErrNotFound):
		return &clierr.Error{Code: clierr.ExitNoPerm, ID: "PLAT-LOGIN",
			Message: "not logged in to this context",
			Hint:    "Run 'plat login'.", Err: err}
	case errors.Is(err, auth.ErrLoginExpired):
		return &clierr.Error{Code: clierr.ExitNoPerm, ID: "PLAT-LOGIN",
			Message: "your login has expired or was revoked",
			Hint:    "Run 'plat login' again.", Err: err}
	}
	if errors.Is(err, platformapi.ErrNotFound) {
		return &clierr.Error{Code: clierr.ExitFailure,
			Message: what + " not found", Err: err}
	}
	if ae, ok := errors.AsType[*platformapi.APIError](err); ok {
		switch ae.StatusCode {
		case http.StatusUnauthorized:
			return &clierr.Error{Code: clierr.ExitNoPerm, ID: "PLAT-AUTH",
				Message: "the platform rejected your credentials",
				Hint:    "Run 'plat login', or check PLAT_TOKEN.", Err: err}
		case http.StatusForbidden:
			return &clierr.Error{Code: clierr.ExitNoPerm, ID: "PLAT-DENIED",
				Message: "you are not allowed to do that: " + ae.Message,
				Err:     err}
		}
	}
	if oe, ok := errors.AsType[*net.OpError](err); ok && oe.Op == "dial" {
		return &clierr.Error{Code: clierr.ExitTempFail, ID: "PLAT-UNREACHABLE",
			Message: fmt.Sprintf("cannot reach the platform at %s", oe.Addr),
			Hint:    "Check --server or PLAT_SERVER, and that the server is up.",
			Err:     err}
	}
	return err
}

// END explain OMIT
