package commands

// START imports OMIT

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/output"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START cmd OMIT

type watchOptions struct {
	IO       *cli.IOStreams
	Client   func() (*platformapi.Client, error)
	Filter   platformapi.DeploymentFilter
	Interval time.Duration
}

func newDeploymentsWatchCmd(f *factory.Factory) *cobra.Command {
	opts := &watchOptions{IO: f.IO, Client: f.Client}
	cmd := &cobra.Command{
		Use:   "watch",
		Short: "Watch deployments change, live",
		Long: `Watch deployments as they change. On a terminal this is a full-screen
view: up/down (or k/j) to move, c to cancel the selected rollout, q to quit.
When output is not a terminal, plat prints one line for each new deployment
or change of state instead, until interrupted.`,
		Args: cli.ExactArgs(),
		RunE: func(c *cobra.Command, _ []string) error {
			if opts.Interval < 100*time.Millisecond {
				return cli.UsageError(c, fmt.Errorf("--interval %v is too "+
					"short; the minimum is 100ms", opts.Interval))
			}
			client, err := opts.Client()
			if err != nil {
				return err
			}
			if opts.IO.IsStdoutTTY() && opts.IO.IsStdinTTY() {
				return runWatchTUI(c.Context(), opts, client)
			}
			return runWatchStream(c.Context(), opts, client)
		},
	}
	fl := cmd.Flags()
	fl.StringVar(&opts.Filter.Service, "service", "", "only this `SERVICE`")
	fl.StringVarP(&opts.Filter.Environment, "env", "e", "",
		"only this `ENVIRONMENT`")
	fl.DurationVar(&opts.Interval, "interval", 2*time.Second, "how often to refresh")
	return cmd
}

// END cmd OMIT
// START stream OMIT

// runWatchStream prints a line whenever a deployment appears or changes
// state, like `kubectl get -w`. Interrupting it is how it ends, so an
// interrupt is a normal exit, not an error.
func runWatchStream(ctx context.Context, opts *watchOptions,
	client *platformapi.Client,
) error {
	p, err := output.New(opts.IO, "")
	if err != nil {
		return err
	}
	fmt.Fprintln(opts.IO.ErrOut, "Watching for new deployments and state "+
		"changes (Ctrl-C to stop)")
	seen := map[string]platformapi.DeploymentState{}
	first := true
	for {
		list, err := recentDeployments(ctx, client, opts.Filter)
		if interrupted(ctx) {
			return nil
		}
		if err != nil {
			return explain(err, "")
		}
		// Oldest first, so the lines read in the order things happened.
		for _, d := range slices.Backward(list) {
			was, known := seen[d.ID]
			seen[d.ID] = d.State
			if first || (known && was == d.State) {
				continue // print history once, as the starting state
			}
			change := state(p, d.State)
			if known {
				change = string(was) + " -> " + change
			}
			fmt.Fprintf(opts.IO.Out, "%s  %s  %s %s to %s  %s\n",
				time.Now().UTC().Format(time.TimeOnly), d.ID, d.Service,
				d.Version, d.Environment, change)
		}
		first = false
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(opts.Interval):
		}
	}
}

// interrupted reports whether the command was stopped (Ctrl-C), which is
// how a watch normally ends: its error is the interruption, not a failure.
func interrupted(ctx context.Context) bool { return ctx.Err() != nil }

// recentDeployments returns the newest 20 deployments matching f.
func recentDeployments(ctx context.Context, client *platformapi.Client,
	f platformapi.DeploymentFilter,
) ([]platformapi.Deployment, error) {
	var list []platformapi.Deployment
	for d, err := range client.ListDeployments(ctx, f, platformapi.PageSize(20)) {
		if err != nil {
			return nil, err
		}
		if list = append(list, d); len(list) == 20 {
			break
		}
	}
	return list, nil
}

// END stream OMIT
// START model OMIT

// watchModel is the full-screen view, in Bubble Tea's Elm architecture:
// state, an Update that turns messages (key presses, data, timer ticks)
// into new state plus commands to run, and a View that renders state.
// Nothing in it touches the terminal, so tests drive it with messages.
type watchModel struct {
	fetch    func() tea.Cmd // loads the list; its result arrives as listMsg
	cancel   func(id string) tea.Cmd
	interval time.Duration
	now      func() time.Time

	rows       []platformapi.Deployment
	cursor     int
	err        error
	confirming bool   // waiting for y/n to cancel the selected rollout
	status     string // the result of the last action
	width      int
}

// Messages the model receives besides Bubble Tea's own.
type (
	listMsg struct {
		rows []platformapi.Deployment
		err  error
	}
	tickMsg      struct{}
	cancelledMsg struct {
		id  string
		err error
	}
)

// Init loads the list at once.
func (m watchModel) Init() tea.Cmd { return m.fetch() }

// END model OMIT
// START update OMIT

// Update handles one message. Every listMsg schedules the next fetch, so
// exactly one request is in flight or pending at any time, however slow
// the server is.
func (m watchModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case listMsg:
		m.rows, m.err = msg.rows, msg.err
		m.cursor = min(m.cursor, max(0, len(m.rows)-1))
		return m, tea.Tick(m.interval, func(time.Time) tea.Msg { return tickMsg{} })
	case tickMsg:
		return m, m.fetch()
	case cancelledMsg:
		m.status = "cancelled " + msg.id
		if msg.err != nil {
			m.status = "cancel " + msg.id + ": " + msg.err.Error()
		}
		return m, m.fetch()
	case tea.WindowSizeMsg:
		m.width = msg.Width
	case tea.KeyPressMsg:
		return m.key(msg.String())
	}
	return m, nil
}

func (m watchModel) key(k string) (tea.Model, tea.Cmd) {
	if m.confirming {
		m.confirming = false
		if k == "y" && m.cursor < len(m.rows) {
			return m, m.cancel(m.rows[m.cursor].ID)
		}
		m.status = "not cancelled"
		return m, nil
	}
	switch k {
	case "q", "ctrl+c", "esc":
		return m, tea.Quit
	case "up", "k":
		m.cursor = max(0, m.cursor-1)
	case "down", "j":
		m.cursor = min(len(m.rows)-1, m.cursor+1)
	case "c":
		if m.cursor < len(m.rows) && !m.rows[m.cursor].State.Done() {
			m.confirming = true
		} else {
			m.status = "only a pending or running rollout can be cancelled"
		}
	}
	return m, nil
}

// END update OMIT
// START view OMIT

var (
	bold     = lipgloss.NewStyle().Bold(true)
	selected = lipgloss.NewStyle().Reverse(true)
	faint    = lipgloss.NewStyle().Faint(true)
	stateFg  = map[platformapi.DeploymentState]lipgloss.Style{
		platformapi.StateSucceeded:  fg("2"), // ANSI green
		platformapi.StateFailed:     fg("1"), // red
		platformapi.StateInProgress: fg("3"), // yellow
		platformapi.StatePending:    fg("3"),
	}
)

func fg(c string) lipgloss.Style {
	return lipgloss.NewStyle().Foreground(lipgloss.Color(c))
}

// View renders the model. AltScreen gives the view the whole terminal and
// restores the shell's screen when the program exits.
func (m watchModel) View() tea.View {
	var b strings.Builder
	b.WriteString(bold.Render("Deployments") +
		faint.Render(fmt.Sprintf("  refreshing every %v", m.interval)) + "\n\n")
	b.WriteString(bold.Render(fmt.Sprintf("%-6s %-10s %-8s %-8s %-12s %s",
		"ID", "SERVICE", "ENV", "VERSION", "STATE", "AGE")) + "\n")
	for i, d := range m.rows {
		st := stateFg[d.State].Render(fmt.Sprintf("%-12s", d.State))
		line := fmt.Sprintf("%-6s %-10s %-8s %-8s %s %s", d.ID, d.Service,
			d.Environment, d.Version, st, output.Ago(m.now().Sub(d.CreatedAt)))
		if i == m.cursor {
			line = selected.Render(line)
		}
		b.WriteString(line + "\n")
	}
	b.WriteString("\n")
	switch {
	case m.confirming:
		b.WriteString(bold.Render(fmt.Sprintf("Cancel %s? y/n",
			m.rows[m.cursor].ID)))
	case m.err != nil:
		b.WriteString("error: " + m.err.Error())
	case m.status != "":
		b.WriteString(m.status)
	default:
		b.WriteString(faint.Render("↑/↓ move  c cancel rollout  q quit"))
	}
	v := tea.NewView(b.String())
	v.AltScreen = true
	return v
}

// END view OMIT
// START tui OMIT

// runWatchTUI runs the full-screen view until the person quits.
func runWatchTUI(ctx context.Context, opts *watchOptions,
	client *platformapi.Client,
) error {
	m := watchModel{
		interval: opts.Interval,
		now:      time.Now,
		fetch: func() tea.Cmd {
			return func() tea.Msg {
				rows, err := recentDeployments(ctx, client, opts.Filter)
				return listMsg{rows: rows, err: explain(err, "")}
			}
		},
		cancel: func(id string) tea.Cmd {
			return func() tea.Msg {
				_, err := client.CancelDeployment(ctx, id)
				return cancelledMsg{id: id, err: explain(err, "deployment "+id)}
			}
		},
	}
	_, err := tea.NewProgram(m, tea.WithContext(ctx),
		tea.WithInput(opts.IO.In), tea.WithOutput(opts.IO.Out)).Run()
	if interrupted(ctx) {
		return nil // Bubble Tea reports the cancelled context as ErrProgramKilled
	}
	return err
}

// END tui OMIT
