package platformapi_test

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"platformapi"
)

type deployOp = platformapi.Operation[platformapi.Deployment]

// rollouts starts one deployment per service, all to staging. The fake
// needs one poll per replica: checkout 4, inventory 3, ledger 2,
// notifier 2, search 6. Ledger's version is broken and fails at 1 of 2.
func rollouts(t *testing.T, client *platformapi.Client) []*deployOp {
	t.Helper()
	var ops []*deployOp
	services := []string{"checkout", "inventory", "ledger", "notifier", "search"}
	for _, svc := range services {
		req := platformapi.CreateDeploymentRequest{
			Service: svc, Environment: "staging", Version: "v2.0.0",
		}
		if svc == "ledger" {
			req.Version = "v2.0.0-bad"
		}
		op, err := client.CreateDeployment(t.Context(), req)
		if err != nil {
			t.Fatal(err)
		}
		ops = append(ops, op)
	}
	return ops
}

func TestWaitAllPollsConcurrently(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, fake := newClient(t) // polls every 2s
		fake.BreakVersion("v2.0.0-bad")
		ops := rollouts(t, client)

		start := time.Now()
		got, err := client.WaitAll(t.Context(), ops, 5)
		// All five at once: as long as the slowest, search (6 polls).
		if el := time.Since(start); el != 10*time.Second {
			t.Errorf("WaitAll took %v of virtual time, want 10s", el)
		}
		opErr, ok := errors.AsType[*platformapi.OperationError](err)
		if !ok || opErr.OperationID != ops[2].ID || opErr.Code != "rollout_failed" {
			t.Fatalf("err = %v, want ledger's rollout_failed", err)
		}
		if len(got) != 5 {
			t.Fatalf("got %d results, want 5", len(got))
		}
		for i, d := range got {
			want := platformapi.StateSucceeded
			if i == 2 {
				want = platformapi.StateFailed
			}
			if d == nil || d.ID != ops[i].Result.ID || d.State != want {
				t.Errorf("result %d = %+v, want %s %s", i, d, ops[i].Result.ID, want)
			}
		}
	})
}

func TestWaitAllRespectsTheLimit(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, fake := newClient(t)
		fake.BreakVersion("v2.0.0-bad")
		ops := rollouts(t, client)

		start := time.Now()
		_, err := client.WaitAll(t.Context(), ops, 1)
		// One at a time: 6s + 4s + 0s + 2s + 10s of sleeps between polls.
		if el := time.Since(start); el != 22*time.Second {
			t.Errorf("WaitAll with limit 1 took %v, want 22s", el)
		}
		if err == nil {
			t.Error("ledger failed, but WaitAll returned no error")
		}
	})
}

func TestWaitAllStopsWithTheContext(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, _ := newClient(t)
		ops := rollouts(t, client)[:1]
		ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
		defer cancel()
		got, err := client.WaitAll(ctx, ops, 0) // 0: no limit
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Errorf("err = %v, want DeadlineExceeded", err)
		}
		if len(got) != 1 || got[0] != nil {
			t.Errorf("got %+v, want one nil result", got)
		}
	})
}
