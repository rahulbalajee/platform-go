// Package rank finds the most common keys in a map of counts.
package rank

import (
	"cmp"
	"slices"
)

// START top OMIT

// Count is a key and the number of times it was seen.
type Count[K any] struct {
	Key K
	N   int
}

// Top returns the n keys with the highest counts, highest first. Keys
// with equal counts are sorted by key, so the result is the same on
// every run even though map order is not.
func Top[K cmp.Ordered](counts map[K]int, n int) []Count[K] {
	all := make([]Count[K], 0, len(counts))
	for k, c := range counts {
		all = append(all, Count[K]{Key: k, N: c})
	}
	slices.SortFunc(all, func(a, b Count[K]) int {
		if a.N != b.N {
			return cmp.Compare(b.N, a.N) // larger counts first
		}
		return cmp.Compare(a.Key, b.Key)
	})
	if n < 0 {
		n = 0
	}
	if n < len(all) {
		all = all[:n]
	}
	return all
}

// END top OMIT
