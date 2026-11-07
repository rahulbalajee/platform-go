// Command snoop tries to reach outside its sandbox and reports what it
// found. Every attempt should fail.
package main

import (
	"fmt"
	"net"
	"os"
)

func main() {
	_, errFile := os.ReadFile("/etc/passwd")
	_, errDir := os.ReadDir("/")
	_, errNet := net.Dial("tcp", "example.com:80")
	fmt.Printf("file: %v; dir: %v; net: %v; HOME=%q\n",
		errFile != nil, errDir != nil, errNet != nil, os.Getenv("HOME"))
	os.Exit(1)
}
