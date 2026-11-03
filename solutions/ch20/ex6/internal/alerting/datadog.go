// START ddhead OMIT

package alerting

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"

	v1alpha1 "watchtower/api/v1alpha1"
)

// Datadog manages one Datadog monitor per HealthCheck through the Monitors
// API (v1). Monitors live outside the cluster, so the controller protects
// them with a finalizer and calls Remove before the HealthCheck goes away.
//
// The monitor queries the watchtower_healthcheck_up metric, which the
// Datadog Agent collects from the operator's /metrics endpoint with its
// OpenMetrics check.
type Datadog struct {
	BaseURL string // e.g. https://api.datadoghq.com or https://api.datadoghq.eu
	APIKey  string
	AppKey  string
	HTTP    *http.Client
	// Query renders the monitor query. Defaults to DefaultDatadogQuery.
	Query func(hc *v1alpha1.HealthCheck) string
}

// Name implements Backend.
func (d *Datadog) Name() string { return "datadog" }

// External implements Backend: monitors live in Datadog, not the cluster.
func (d *Datadog) External() bool { return true }

// END ddhead OMIT

// START ddmonitor OMIT

// DefaultDatadogQuery assumes the OpenMetrics check maps
// watchtower_healthcheck_up to watchtower.healthcheck.up and keeps the
// check_namespace and check_name labels as tags.
func DefaultDatadogQuery(hc *v1alpha1.HealthCheck) string {
	return fmt.Sprintf("max(%s):max:watchtower.healthcheck.up"+
		"{check_namespace:%s,check_name:%s} < 1",
		datadogWindow(hc.Spec.Alert.For.Duration), hc.Namespace, hc.Name)
}

// monitor is the subset of the Datadog monitor object we manage.
type monitor struct {
	ID      int64          `json:"id,omitempty"`
	Name    string         `json:"name"`
	Type    string         `json:"type"`
	Query   string         `json:"query"`
	Message string         `json:"message"`
	Tags    []string       `json:"tags"`
	Options monitorOptions `json:"options"`
}

type monitorOptions struct {
	Thresholds        map[string]float64 `json:"thresholds"`
	NotifyNoData      bool               `json:"notify_no_data"`
	RequireFullWindow bool               `json:"require_full_window"`
}

// uidTag is how we find a monitor we created even if we never recorded its
// ID, for example because the status update after creation failed.
func uidTag(hc *v1alpha1.HealthCheck) string {
	return "watchtower-uid:" + string(hc.UID)
}

// END ddmonitor OMIT

// START ddensure OMIT

// Ensure creates or updates the monitor. External APIs have no owner
// references and no server-side apply, so idempotency is our job: the
// monitor is tagged with the HealthCheck's UID, and before creating one we
// look for an existing monitor with that tag. A crash between "create" and
// "record the ID in status" therefore adopts the orphan instead of creating
// a duplicate on the next reconcile.
func (d *Datadog) Ensure(
	ctx context.Context, hc *v1alpha1.HealthCheck,
) (string, error) {
	if d.APIKey == "" || d.AppKey == "" {
		return "", fmt.Errorf("%w: DD_API_KEY and DD_APP_KEY must be set",
			ErrUnavailable)
	}
	want := d.monitorFor(hc)

	id := knownID(hc)
	if id == 0 {
		found, err := d.findByTag(ctx, uidTag(hc))
		if err != nil {
			return "", err
		}
		id = found
	}
	if id != 0 {
		path := "/api/v1/monitor/" + strconv.FormatInt(id, 10)
		err := d.do(ctx, http.MethodPut, path, want, nil)
		if err == nil {
			return strconv.FormatInt(id, 10), nil
		}
		if !isNotFound(err) {
			return "", err
		}
		// Deleted out from under us (by a human, in the UI): recreate it.
	}
	var created monitor
	err := d.do(ctx, http.MethodPost, "/api/v1/monitor", want, &created)
	if err != nil {
		return "", err
	}
	return strconv.FormatInt(created.ID, 10), nil
}

// END ddensure OMIT

// START ddremove OMIT

// Remove deletes the monitor. A monitor that is already gone is success.
func (d *Datadog) Remove(
	ctx context.Context, hc *v1alpha1.HealthCheck,
) error {
	id := knownID(hc)
	if id == 0 {
		found, err := d.findByTag(ctx, uidTag(hc))
		if err != nil {
			return err
		}
		if found == 0 {
			return nil // nothing was ever created
		}
		id = found
	}
	path := "/api/v1/monitor/" + strconv.FormatInt(id, 10)
	err := d.do(ctx, http.MethodDelete, path, nil, nil)
	if isNotFound(err) {
		return nil
	}
	return err
}

// END ddremove OMIT

// START ddbody OMIT

// monitorFor renders the desired monitor for hc.
func (d *Datadog) monitorFor(hc *v1alpha1.HealthCheck) monitor {
	q := d.Query
	if q == nil {
		q = DefaultDatadogQuery
	}
	msg := ruleSummary(hc)
	if hc.Spec.Alert.RunbookURL != "" {
		msg += "\n\nRunbook: " + hc.Spec.Alert.RunbookURL
	}
	return monitor{
		Name:    fmt.Sprintf("[watchtower] %s/%s is failing", hc.Namespace, hc.Name),
		Type:    "metric alert",
		Query:   q(hc),
		Message: msg,
		Tags: []string{
			uidTag(hc),
			"managed-by:watchtower",
			"severity:" + hc.Spec.Alert.Severity,
			"check_namespace:" + hc.Namespace,
			"check_name:" + hc.Name,
		},
		Options: monitorOptions{Thresholds: map[string]float64{"critical": 1}},
	}
}

// knownID is the monitor ID recorded in status, or 0.
func knownID(hc *v1alpha1.HealthCheck) int64 {
	a := hc.Status.Alerting
	if a == nil || a.Backend != "datadog" {
		return 0
	}
	id, _ := strconv.ParseInt(a.Ref, 10, 64)
	return id
}

// findByTag returns the ID of a monitor carrying tag, or 0.
func (d *Datadog) findByTag(ctx context.Context, tag string) (int64, error) {
	var found []monitor
	path := "/api/v1/monitor?monitor_tags=" + url.QueryEscape(tag)
	if err := d.do(ctx, http.MethodGet, path, nil, &found); err != nil {
		return 0, err
	}
	if len(found) == 0 {
		return 0, nil
	}
	return found[0].ID, nil
}

// apiError is a non-2xx response from Datadog.
type apiError struct {
	Status int
	Body   string
}

func (e *apiError) Error() string {
	return fmt.Sprintf("datadog API: HTTP %d: %s", e.Status, e.Body)
}

// isNotFound reports whether err is a 404 from Datadog.
func isNotFound(err error) bool {
	ae, ok := errors.AsType[*apiError](err)
	return ok && ae.Status == http.StatusNotFound
}

// do sends one API request and decodes a 2xx JSON response into out.
func (d *Datadog) do(ctx context.Context, method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, d.BaseURL+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("DD-API-KEY", d.APIKey)
	req.Header.Set("DD-APPLICATION-KEY", d.AppKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := d.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusTooManyRequests {
		reset := resp.Header.Get("X-RateLimit-Reset")
		return &RateLimitedError{RetryAfter: retryAfter(reset)}
	}
	if resp.StatusCode/100 != 2 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return &apiError{Status: resp.StatusCode, Body: string(b)}
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// retryAfter turns X-RateLimit-Reset, the seconds until Datadog's rate
// limit window resets, into a wait: a minute if it is missing or invalid,
// at most an hour.
func retryAfter(reset string) time.Duration {
	n, err := strconv.Atoi(reset)
	if err != nil || n <= 0 {
		return time.Minute
	}
	return min(time.Duration(n)*time.Second, time.Hour)
}

// datadogWindow maps an alert "for" duration onto the evaluation windows
// Datadog monitor queries accept, rounding up.
func datadogWindow(d time.Duration) string {
	for _, w := range []struct {
		d time.Duration
		s string
	}{
		{time.Minute, "last_1m"}, {5 * time.Minute, "last_5m"},
		{10 * time.Minute, "last_10m"}, {15 * time.Minute, "last_15m"},
		{30 * time.Minute, "last_30m"}, {time.Hour, "last_1h"},
		{2 * time.Hour, "last_2h"}, {4 * time.Hour, "last_4h"},
	} {
		if d <= w.d {
			return w.s
		}
	}
	return "last_1d"
}

// END ddbody OMIT
