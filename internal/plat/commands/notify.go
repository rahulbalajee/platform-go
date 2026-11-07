package commands

// START imports OMIT

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/spf13/cobra"
	"sigs.k8s.io/yaml"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
	"github.com/rahulbalajee/platform-go/pkg/platnotify"
)

// END imports OMIT
// START config OMIT

// notifierConfig is one entry of notifiers.yaml in plat's configuration
// directory:
//
//	notifiers:
//	  - name: chat
//	    command: [platnotify-webhook]
//
// The command is looked up on PATH like any other. Secrets, such as a
// webhook URL, stay out of this file: the plugin reads them from its
// environment, which is plat's.
type notifierConfig struct {
	Name    string   `json:"name"`
	Command []string `json:"command"`
}

// notifyTimeout bounds each notifier: a slow chat server must not hold up
// the deploy that is waiting for it.
const notifyTimeout = 10 * time.Second

func loadNotifiers(f *factory.Factory) ([]notifierConfig, error) {
	dir, err := f.ConfigDir()
	if err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "notifiers.yaml")
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var file struct {
		Notifiers []notifierConfig `json:"notifiers"`
	}
	if err := yaml.UnmarshalStrict(b, &file); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	for _, n := range file.Notifiers {
		if n.Name == "" || len(n.Command) == 0 {
			return nil, fmt.Errorf("%s: every notifier needs a name and a command",
				path)
		}
	}
	return file.Notifiers, nil
}

// END config OMIT
// START notify OMIT

// notification is the outcome of telling one notifier.
type notification struct {
	name, detail string
	err          error
}

// notify tells every notifier about e, all at once, each in its own
// process with its own deadline. It reports outcomes; it never fails the
// command, because by now the deployment has happened.
func notify(ctx context.Context, f *factory.Factory, e platnotify.Event,
) []notification {
	cfgs, err := loadNotifiers(f)
	if err != nil {
		return []notification{{name: "notifiers.yaml", err: err}}
	}
	out := make([]notification, len(cfgs))
	var wg sync.WaitGroup
	for i, c := range cfgs {
		wg.Go(func() {
			detail, err := notifyOne(ctx, f, c, e)
			out[i] = notification{name: c.Name, detail: detail, err: err}
		})
	}
	wg.Wait()
	return out
}

func notifyOne(ctx context.Context, f *factory.Factory, c notifierConfig,
	e platnotify.Event,
) (string, error) {
	path, err := exec.LookPath(c.Command[0])
	if err != nil {
		return "", err // includes exec.ErrDot for ./plugin on PATH
	}
	// The deadline covers starting the plugin too, and the context kills
	// the process if the plugin hangs.
	ctx, cancel := context.WithTimeout(ctx, notifyTimeout)
	defer cancel()
	//nolint:gosec // running the plugin the user configured is the point
	cmd := exec.CommandContext(ctx, path, c.Command[1:]...)
	p, err := platnotify.Start(cmd, f.IO.ErrOut)
	if err != nil {
		return "", fmt.Errorf("starting %s: %w", path, err)
	}
	defer p.Close()
	return p.Notify(ctx, e)
}

// report prints one line per notifier to stderr: what it did, or a
// warning. Exit status is not affected.
func report(f *factory.Factory, results []notification) {
	for _, n := range results {
		if n.err != nil {
			fmt.Fprintf(f.IO.ErrOut, "  warning: notifier %s: %v\n", n.name, n.err)
			continue
		}
		fmt.Fprintf(f.IO.ErrOut, "  notified %s: %s\n", n.name, n.detail)
	}
}

// eventOf turns a finished deployment into a notifier event.
func eventOf(d *platformapi.Deployment, user string, at time.Time) platnotify.Event {
	return platnotify.Event{ID: d.ID, Service: d.Service,
		Environment: d.Environment, Version: d.Version, State: string(d.State),
		Reason: d.Reason, User: user, FinishedAt: at}
}

// END notify OMIT
// START cmd OMIT

func newNotifiersCmd(f *factory.Factory) *cobra.Command {
	cmd := cli.Group(&cobra.Command{
		Use:     "notifiers",
		Aliases: []string{"notifier"},
		Short:   "Test the plugins plat notifies after a deploy",
		Long: `After a deploy that plat waited for, plat tells the notifier plugins
listed in notifiers.yaml in its configuration directory. A notifier that
fails prints a warning; the deploy's exit status does not change.`,
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "test",
		Short: "Send a test event to every notifier",
		Args:  cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			results := notify(c.Context(), f, platnotify.Event{ID: "d-test",
				Service: "plat", Environment: "test", Version: f.Version,
				State: "test", User: currentUser(c.Context(), f),
				FinishedAt: f.Now()})
			if len(results) == 0 {
				return &clierr.Error{Code: clierr.ExitFailure,
					Message: "no notifiers are configured",
					Hint: "List them in notifiers.yaml; " +
						"see 'plat notifiers --help'."}
			}
			report(f, results)
			for _, r := range results {
				if r.err != nil {
					return &clierr.Error{Code: clierr.ExitFailure,
						Message: "a notifier failed", Err: r.err}
				}
			}
			return nil
		},
	})
	return cmd
}

// END cmd OMIT
