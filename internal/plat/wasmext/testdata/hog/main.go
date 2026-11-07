// Command hog allocates far more memory than a check is allowed.
package main

import "fmt"

func main() {
	var keep [][]byte
	for range 100 {
		keep = append(keep, make([]byte, 16<<20)) // 1.6 GiB in total
	}
	fmt.Println(len(keep))
}
