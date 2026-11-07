// Command platnotify-webhook is a notifier plugin for plat that posts a
// message about each finished deployment to a webhook. The JSON body,
// {"text": "..."}, is what Slack and Mattermost incoming webhooks and
// Microsoft Teams workflows accept. Set PLAT_WEBHOOK_URL, and list the
// plugin in plat's notifiers.yaml:
//
//	notifiers:
//	  - name: chat
//	    command: [platnotify-webhook]
//
// The name does not start with "plat-": that prefix is for executable
// plugins, which plat runs as commands, and this is not one.
package main

// START main OMIT

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"

	"github.com/rahulbalajee/platform-go/pkg/platnotify"
)

func main() {
	platnotify.Serve(webhook{url: os.Getenv("PLAT_WEBHOOK_URL"),
		client: http.DefaultClient})
}

type webhook struct {
	url    string
	client *http.Client
}

var icons = map[string]string{"succeeded": "✅", "failed": "❌",
	"cancelled": "⏹️", "test": "🔔"}

// Notify posts one message. The context carries plat's deadline, so a
// slow webhook can't hold up the deploy that is waiting for it.
func (w webhook) Notify(ctx context.Context, e platnotify.Event) (string, error) {
	if w.url == "" {
		return "", errors.New("PLAT_WEBHOOK_URL is not set")
	}
	text := fmt.Sprintf("%s %s %s to %s: %s (%s)", icons[e.State], e.Service,
		e.Version, e.Environment, e.State, e.ID)
	if e.Reason != "" {
		text += "; " + e.Reason
	}
	if e.User != "" {
		text += ", by " + e.User
	}
	body, err := json.Marshal(map[string]string{"text": text})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url,
		bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := w.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("webhook answered %s", resp.Status)
	}
	u, _ := url.Parse(w.url)
	return "posted to " + u.Host, nil // never print the URL: it is the secret
}

// END main OMIT
