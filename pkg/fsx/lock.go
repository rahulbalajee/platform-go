// START lockhead OMIT

package fsx

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

// ErrLocked reports that another process holds the lock.
var ErrLocked = errors.New("lock is held by another process")

// LockedError is returned when the lock is held elsewhere. It matches
// ErrLocked with errors.Is.
type LockedError struct {
	Path   string
	Holder string // what the holder recorded, e.g. "pid=4242 host=ci-7 since=..."
}

func (e *LockedError) Error() string {
	if e.Holder == "" {
		return e.Path + ": " + ErrLocked.Error()
	}
	return fmt.Sprintf("%s: %v (%s)", e.Path, ErrLocked, e.Holder)
}

// Is makes errors.Is(err, ErrLocked) true for a *LockedError.
func (e *LockedError) Is(target error) bool { return target == ErrLocked }

// Lock is an exclusive advisory lock on a file. On Unix it is a flock(2)
// lock, which the kernel releases when the holder's descriptor is closed,
// including when the process crashes or is killed, so it cannot go stale.
type Lock struct {
	f    *os.File
	path string
}

// END lockhead OMIT

// START trylock OMIT
// TryLock takes an exclusive lock on path, creating the file if needed. It
// does not wait: if another process holds the lock it returns a
// *LockedError describing the holder.
func TryLock(path string) (*Lock, error) {
	for range 10 {
		f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
		if err != nil {
			return nil, fmt.Errorf("lock %s: %w", path, err)
		}
		if err := lockFile(f); err != nil {
			_ = f.Close()
			if errors.Is(err, errWouldBlock) {
				return nil, &LockedError{Path: path, Holder: readHolder(path)}
			}
			return nil, fmt.Errorf("lock %s: %w", path, err)
		}
		// We locked the inode we opened. If the file was deleted or
		// replaced in between, path now names a different inode that
		// someone else can lock too. Start again on the current file.
		if !samePath(f, path) {
			_ = f.Close()
			continue
		}
		l := &Lock{f: f, path: path}
		if err := l.recordHolder(); err != nil {
			_ = l.Unlock()
			return nil, err
		}
		return l, nil
	}
	return nil, fmt.Errorf("lock %s: file keeps being replaced", path)
}

// END trylock OMIT

// START acquire OMIT
// Acquire waits until it holds the lock on path or ctx is done. It polls
// with backoff, because a blocking flock cannot be interrupted by a
// context. Waiters are not served in FIFO order.
func Acquire(ctx context.Context, path string) (*Lock, error) {
	delay := 10 * time.Millisecond
	for {
		l, err := TryLock(path)
		if !errors.Is(err, ErrLocked) {
			return l, err
		}
		t := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			t.Stop()
			return nil, fmt.Errorf("%w: %w", err, context.Cause(ctx))
		case <-t.C:
		}
		delay = min(2*delay, 500*time.Millisecond)
	}
}

// Unlock releases the lock. The file itself is left in place on purpose:
// removing it lets a waiter lock the unlinked inode while a newcomer
// creates and locks a fresh file under the same name.
func (l *Lock) Unlock() error {
	if l == nil || l.f == nil {
		return nil
	}
	_ = l.f.Truncate(0) // clear the holder record; best effort
	err := errors.Join(unlockFile(l.f), l.f.Close())
	l.f = nil
	if err != nil {
		return fmt.Errorf("unlock %s: %w", l.path, err)
	}
	return nil
}

// END acquire OMIT

// START holder OMIT
// recordHolder writes who holds the lock, for the error message other
// processes print. It is diagnostic only; the kernel lock is the truth.
func (l *Lock) recordHolder() error {
	host, _ := os.Hostname()
	rec := fmt.Sprintf("pid=%d host=%s since=%s\n",
		os.Getpid(), host, time.Now().UTC().Format(time.RFC3339))
	if err := l.f.Truncate(0); err != nil {
		return fmt.Errorf("lock %s: %w", l.path, err)
	}
	if _, err := l.f.WriteAt([]byte(rec), 0); err != nil {
		return fmt.Errorf("lock %s: %w", l.path, err)
	}
	return nil
}

// readHolder returns the holder record, or "" if it cannot be read (on
// Windows the locked byte range is not readable by other processes).
func readHolder(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	b, _ := io.ReadAll(io.LimitReader(f, 256))
	return strings.TrimSpace(string(b))
}

// samePath reports whether the open file f is still the file named path.
func samePath(f *os.File, path string) bool {
	a, err := f.Stat()
	if err != nil {
		return false
	}
	b, err := os.Stat(path)
	if err != nil {
		return false // includes fs.ErrNotExist: the file was removed
	}
	return os.SameFile(a, b)
}

// END holder OMIT
