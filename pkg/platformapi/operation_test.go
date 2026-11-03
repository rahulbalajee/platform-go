// START waittest OMIT

package platformapi_test

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

func TestWaitFollowsRolloutToSuccess(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, _ := newClient(t) // polls every 2s
		op, err := client.CreateDeployment(t.Context(), staging)
		if err != nil {
			t.Fatal(err)
		}
		start := time.Now()
		d, err := client.Wait(t.Context(), op)
		if err != nil {
			t.Fatal(err)
		}
		if d.State != platformapi.StateSucceeded || d.UpdatedReplicas != 4 {
			t.Errorf("deployment = %+v, want 4/4 replicas, succeeded", d)
		}
		// The fake moves one replica per poll: 4 polls, 3 sleeps between.
		if el := time.Since(start); el != 6*time.Second {
			t.Errorf("Wait took %v of virtual time, want 6s", el)
		}
	})
}

// END waittest OMIT

// START canceltest OMIT
func TestCancellingWaitDoesNotCancelTheDeployment(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, fake := newClient(t)
		op, err := client.CreateDeployment(t.Context(), staging)
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
		defer cancel()
		_, err = client.Wait(ctx, op)
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("Wait = %v, want DeadlineExceeded", err)
		}
		// The caller stopped waiting; the platform kept deploying.
		if s := fake.DeploymentState(op.Result.ID); s != "in_progress" {
			t.Errorf("deployment state = %q, want in_progress", s)
		}
	})
}

// END canceltest OMIT

// START failtest OMIT
func TestWaitReportsFailedRollout(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, fake := newClient(t)
		fake.BreakVersion("v1.5.0")
		op, err := client.CreateDeployment(t.Context(), staging)
		if err != nil {
			t.Fatal(err)
		}
		d, err := client.Wait(t.Context(), op)
		opErr, ok := errors.AsType[*platformapi.OperationError](err)
		if !ok || opErr.Code != "rollout_failed" || opErr.OperationID != op.ID {
			t.Fatalf("err = %v, want rollout_failed for %s", err, op.ID)
		}
		if d == nil || d.State != platformapi.StateFailed {
			t.Errorf("deployment = %+v, want the failed final state", d)
		}
	})
}

func TestWaitAfterCancel(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, _ := newClient(t)
		op, err := client.CreateDeployment(t.Context(), staging)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := client.CancelDeployment(t.Context(), op.Result.ID); err != nil {
			t.Fatal(err)
		}
		_, err = client.Wait(t.Context(), op)
		if opErr, ok := errors.AsType[*platformapi.OperationError](err); !ok ||
			opErr.Code != "cancelled" {
			t.Errorf("Wait after cancel = %v, want a cancelled OperationError", err)
		}
	})
}

// END failtest OMIT

// START polltest OMIT
func TestPollYieldsEverySnapshot(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, _ := newClient(t)
		op, err := client.CreateDeployment(t.Context(), staging)
		if err != nil {
			t.Fatal(err)
		}
		var msgs []string
		for snap, err := range client.Poll(t.Context(), op) {
			if err != nil {
				t.Fatal(err)
			}
			msgs = append(msgs, snap.Message)
		}
		if len(msgs) != 4 || msgs[3] != "rolling out v1.5.0: 4/4 replicas updated" {
			t.Errorf("progress messages = %q", msgs)
		}
	})
}

func TestResumeWaitingByOperationID(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, _ := newClient(t)
		op, err := client.CreateDeployment(t.Context(), staging)
		if err != nil {
			t.Fatal(err)
		}
		// A different process only knows the ID it stored.
		resumed := &platformapi.Operation[platformapi.Deployment]{ID: op.ID}
		d, err := client.Wait(t.Context(), resumed)
		if err != nil || d.ID != op.Result.ID {
			t.Errorf("Wait(resumed) = %+v, %v", d, err)
		}
	})
}

func TestPollRejectsOperationWithoutID(t *testing.T) {
	client, fake := newClient(t)
	noID := &platformapi.Operation[platformapi.Deployment]{}
	_, err := client.Wait(t.Context(), noID)
	if err == nil {
		t.Fatal("Wait on an operation without ID succeeded")
	}
	if n := len(fake.Requests()); n != 0 {
		t.Errorf("sent %d requests", n)
	}
}

// END polltest OMIT
