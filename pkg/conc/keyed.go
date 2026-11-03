// START type OMIT

package conc

import (
	"context"
	"sync"
)

// KeyedSemaphore limits concurrency per key: at most limit holders for any
// single key, with no limit across keys. Tools use it for politeness, for
// example "no more than 4 concurrent requests to any one host" while still
// checking hundreds of hosts in parallel.
//
// Memory is proportional to the number of keys currently in use; idle keys
// are deleted as soon as their last holder or waiter leaves.
type KeyedSemaphore struct {
	limit int

	mu    sync.Mutex
	slots map[string]*keyedSlot
}

type keyedSlot struct {
	tokens chan struct{} // buffered to limit; a send acquires a slot
	refs   int           // holders + waiters; guarded by KeyedSemaphore.mu
}

// NewKeyedSemaphore returns a semaphore allowing limit holders per key.
func NewKeyedSemaphore(limit int) *KeyedSemaphore {
	return &KeyedSemaphore{limit: max(limit, 1), slots: make(map[string]*keyedSlot)}
}

// END type OMIT

// START acquire OMIT

// Acquire blocks until a slot for key is free or ctx is done. On success it
// returns a release function that must be called; calling it more than once
// is a no-op.
func (k *KeyedSemaphore) Acquire(ctx context.Context, key string) (func(), error) {
	k.mu.Lock()
	s, ok := k.slots[key]
	if !ok {
		s = &keyedSlot{tokens: make(chan struct{}, k.limit)}
		k.slots[key] = s
	}
	s.refs++ // count waiters too, so the slot isn't deleted under them
	k.mu.Unlock()

	select {
	case s.tokens <- struct{}{}:
		var once sync.Once
		return func() {
			once.Do(func() {
				<-s.tokens
				k.unref(key, s)
			})
		}, nil
	case <-ctx.Done():
		k.unref(key, s)
		return nil, context.Cause(ctx)
	}
}

func (k *KeyedSemaphore) unref(key string, s *keyedSlot) {
	k.mu.Lock()
	defer k.mu.Unlock()
	s.refs--
	if s.refs == 0 {
		delete(k.slots, key)
	}
}

// END acquire OMIT

// START len OMIT

// Len reports the number of keys currently tracked. It exists for tests and
// metrics; a steadily growing Len indicates leaked release functions.
func (k *KeyedSemaphore) Len() int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return len(k.slots)
}

// END len OMIT
