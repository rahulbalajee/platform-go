package flaky

import (
	"fmt"
	"sync"
)

// A package-level registry: convenient in main, and the classic source of
// tests that pass alone and fail together.
var (
	mu       sync.Mutex
	registry = map[string]string{}
)

// Register adds a named check. Names must be unique.
func Register(name, target string) error {
	mu.Lock()
	defer mu.Unlock()
	if _, dup := registry[name]; dup {
		return fmt.Errorf("check %q already registered", name)
	}
	registry[name] = target
	return nil
}

// Len reports how many checks are registered.
func Len() int {
	mu.Lock()
	defer mu.Unlock()
	return len(registry)
}
