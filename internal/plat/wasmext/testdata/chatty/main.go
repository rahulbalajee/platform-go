// Command chatty prints a megabyte and refuses the deployment.
package main

import (
	"os"
	"strings"
)

func main() {
	os.Stdout.WriteString(strings.Repeat("too much output ", 64<<10))
	os.Exit(1)
}
