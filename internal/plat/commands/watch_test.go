package commands

// START imports OMIT

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START model OMIT

// newTestModel returns a watch model whose commands record what they were
// asked to do instead of calling an API.
func newTestModel(rows ...platformapi.Deployment) (*watchModel, *[]string) {
	var calls []string
	at := time.Date(2026, 11, 6, 9, 0, 0, 0, time.UTC)
	m := &watchModel{
		interval: time.Second,
		now:      func() time.Time { return at.Add(5 * time.Minute) },
		fetch: func() tea.Cmd {
			return func() tea.Msg { calls = append(calls, "fetch"); return nil }
		},
		cancel: func(id string) tea.Cmd {
			return func() tea.Msg { calls = append(calls, "cancel "+id); return nil }
		},
	}
	for i := range rows {
		rows[i].CreatedAt = at
	}
	next, _ := m.Update(listMsg{rows: rows})
	*m = next.(watchModel)
	return m, &calls
}

// press sends key presses to m and runs any command they return.
func press(t *testing.T, m *watchModel, keys ...string) tea.Msg {
	t.Helper()
	var last tea.Msg
	for _, k := range keys {
		msg := tea.KeyPressMsg{Code: rune(k[0]), Text: k}
		if k == "down" {
			msg = tea.KeyPressMsg{Code: tea.KeyDown}
		}
		next, cmd := m.Update(msg)
		*m = next.(watchModel)
		if cmd != nil {
			last = cmd()
		}
	}
	return last
}

var watchRows = []platformapi.Deployment{
	{ID: "d-10", Service: "checkout", Environment: "prod", Version: "v1.5.0",
		State: platformapi.StateInProgress},
	{ID: "d-9", Service: "checkout", Environment: "staging", Version: "v1.5.0",
		State: platformapi.StateSucceeded},
}

func TestWatchViewShowsRowsAndAge(t *testing.T) {
	m, _ := newTestModel(watchRows...)
	v := m.View()
	if !v.AltScreen {
		t.Error("the view should take the whole screen")
	}
	for _, want := range []string{"d-10", "in_progress", "succeeded", "5m ago",
		"c cancel rollout"} {
		if !strings.Contains(v.Content, want) {
			t.Errorf("view lacks %q:\n%s", want, v.Content)
		}
	}
}

// END model OMIT
// START keys OMIT

func TestWatchCancelAsksFirst(t *testing.T) {
	m, calls := newTestModel(watchRows...)
	press(t, m, "c")
	if !m.confirming || !strings.Contains(m.View().Content, "Cancel d-10? y/n") {
		t.Fatalf("no confirmation:\n%s", m.View().Content)
	}
	press(t, m, "n")
	if len(*calls) != 0 || m.status != "not cancelled" {
		t.Fatalf("n: calls %v, status %q", *calls, m.status)
	}
	press(t, m, "c", "y")
	if strings.Join(*calls, ",") != "cancel d-10" {
		t.Errorf("calls = %v, want cancel d-10", *calls)
	}
}

func TestWatchWontCancelAFinishedRollout(t *testing.T) {
	m, calls := newTestModel(watchRows...)
	press(t, m, "down", "c", "y")
	if len(*calls) != 0 || m.confirming {
		t.Errorf("cancelled a finished deployment: %v", *calls)
	}
}

func TestWatchQuits(t *testing.T) {
	m, _ := newTestModel(watchRows...)
	if _, ok := press(t, m, "q").(tea.QuitMsg); !ok {
		t.Error("q did not quit")
	}
}

// END keys OMIT
// START stream OMIT

// Without a terminal, watch prints one line per change, for logs and
// pipes, and an interrupt ends it with exit 0.
func TestWatchStreamsChanges(t *testing.T) {
	p := newTestPlat(t)
	client, _ := p.f.Client()
	var out lockedBuilder
	p.f.IO.Out = &out
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- runWatchStream(ctx, &watchOptions{IO: p.f.IO,
			Interval: 10 * time.Millisecond}, client)
	}()
	time.Sleep(50 * time.Millisecond) // let it record the existing history
	op, err := client.CreateDeployment(ctx, platformapi.CreateDeploymentRequest{
		Service: "checkout", Environment: "dev", Version: "v1.5.0"})
	if err != nil {
		t.Fatal(err)
	}
	// The fake only advances a rollout when its operation is read, so the
	// deployment stays pending until Wait: watch must see it pending first.
	eventually(t, func() bool { return strings.Contains(out.String(), "pending") })
	if _, err := client.Wait(ctx, op); err != nil {
		t.Fatal(err)
	}
	eventually(t, func() bool {
		return strings.Contains(out.String(), "-> succeeded")
	})
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("watch ended with %v, want nil after an interrupt", err)
	}
	got := out.String()
	if !strings.Contains(got, "d-9  checkout v1.5.0 to dev  pending\n") ||
		strings.Contains(got, "d-8") { // history is not repeated
		t.Errorf("stream:\n%s", got)
	}
}

// eventually waits up to two seconds for cond.
func eventually(t *testing.T, cond func() bool) {
	t.Helper()
	for range 200 {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("condition not met within 2s")
}

// lockedBuilder is a strings.Builder safe to read while another goroutine
// writes to it.
type lockedBuilder struct {
	mu sync.Mutex
	b  strings.Builder
}

func (l *lockedBuilder) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuilder) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// END stream OMIT
