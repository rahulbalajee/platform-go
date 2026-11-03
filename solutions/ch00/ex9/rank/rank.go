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
	return TopFunc(counts, n, cmp.Compare[K])
}

// START solution OMIT

// TopFunc is like Top for keys that < cannot compare. compare orders
// keys with equal counts; it returns a negative number when a sorts
// before b, a positive number when it sorts after, and 0 otherwise.
func TopFunc[K comparable](
	counts map[K]int, n int, compare func(a, b K) int,
) []Count[K] {
	all := make([]Count[K], 0, len(counts))
	for k, c := range counts {
		all = append(all, Count[K]{Key: k, N: c})
	}
	slices.SortFunc(all, func(a, b Count[K]) int {
		if a.N != b.N {
			return cmp.Compare(b.N, a.N) // larger counts first
		}
		return compare(a.Key, b.Key)
	})
	if n < 0 {
		n = 0
	}
	if n < len(all) {
		all = all[:n]
	}
	return all
}

// END solution OMIT

// END top OMIT
