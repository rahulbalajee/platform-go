package platformapi_test

import (
	"testing"

	"platformapi"
)

func TestTakeStopsFetching(t *testing.T) {
	client, fake := newClient(t)
	seq := client.ListDeployments(t.Context(), platformapi.DeploymentFilter{},
		platformapi.PageSize(3))
	got, err := platformapi.Collect(platformapi.Take(seq, 4))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 4 || got[0].ID != "d-8" || got[3].ID != "d-5" {
		t.Errorf("got %d deployments starting %+v, want d-8 to d-5", len(got), got)
	}
	// Four items need two pages of three; the third is never requested.
	if n := len(fake.Requests()); n != 2 {
		t.Errorf("made %d requests, want 2", n)
	}
}

func TestTakeZeroSendsNothing(t *testing.T) {
	client, fake := newClient(t)
	for _, err := range platformapi.Take(client.ListEnvironments(t.Context()), 0) {
		t.Errorf("Take(seq, 0) yielded an item (err %v)", err)
	}
	if n := len(fake.Requests()); n != 0 {
		t.Errorf("made %d requests, want none", n)
	}
}

func TestTakeMoreThanThereAre(t *testing.T) {
	client, _ := newClient(t)
	envs, err := platformapi.Collect(
		platformapi.Take(client.ListEnvironments(t.Context()), 10))
	if err != nil || len(envs) != 3 {
		t.Errorf("got %d environments, err %v; want all 3", len(envs), err)
	}
}

func TestTakePassesErrorsThrough(t *testing.T) {
	client, _ := newClient(t, platformapi.WithToken("stale-token"))
	var items, errs int
	for _, err := range platformapi.Take(client.ListEnvironments(t.Context()), 2) {
		if err != nil {
			errs++
			continue
		}
		items++
	}
	if items != 0 || errs != 1 {
		t.Errorf("got %d items and %d errors, want 0 and 1", items, errs)
	}
}

func TestTakeWorksOnAnyIterator(t *testing.T) {
	letters := func(yield func(string, error) bool) {
		for _, s := range []string{"a", "b", "c"} {
			if !yield(s, nil) {
				return
			}
		}
	}
	got, err := platformapi.Collect(platformapi.Take(letters, 2))
	if err != nil || len(got) != 2 || got[1] != "b" {
		t.Errorf("Take(letters, 2) = %q, %v", got, err)
	}
}
