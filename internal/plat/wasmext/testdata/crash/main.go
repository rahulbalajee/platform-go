// Command crash panics, as a buggy check would.
package main

func main() {
	var m map[string]int
	m["boom"]++ // assignment to entry in nil map
}
