// Command lockdemo is a stand-in for a CLI that must not run twice at once
// (a deploy, a backup, a migration). It takes a lock file, "works" for a
// while, and exits.
//
//	lockdemo -name A -hold 2s            # flock: fail at once if held
//	lockdemo -name B -wait 5s            # flock: wait up to 5s
//	lockdemo -name C -pidfile -hold 2s   # the O_EXCL pid-file approach
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/fsx"
)

// exitTempFail is EX_TEMPFAIL from sysexits.h: "try again later".
const exitTempFail = 75

func main() {
	name := flag.String("name", "A", "label for this run's output")
	path := flag.String("lock", "/tmp/lockdemo.lock", "lock file")
	hold := flag.Duration("hold", time.Second, "how long to hold the lock")
	wait := flag.Duration("wait", 0, "how long to wait for the lock (0: don't)")
	pidfile := flag.Bool("pidfile", false, "use an O_EXCL pid file instead of flock")
	flag.Parse()

	logf := func(format string, args ...any) {
		fmt.Printf("%s %s: %s\n", time.Now().Format("15:04:05.000"), *name,
			fmt.Sprintf(format, args...))
	}
	release, err := acquire(*path, *wait, *pidfile)
	if le, ok := errors.AsType[*fsx.LockedError](err); ok {
		logf("another run is in progress, exiting")
		fmt.Printf("%15s held by %s\n", "", le.Holder)
		os.Exit(exitTempFail)
	}
	if err != nil {
		logf("%v", err)
		if errors.Is(err, os.ErrExist) {
			os.Exit(exitTempFail)
		}
		os.Exit(1)
	}
	logf("acquired lock (pid %d), working for %v", os.Getpid(), *hold)
	time.Sleep(*hold)
	if err := release(); err != nil {
		logf("release: %v", err)
		os.Exit(1)
	}
	logf("done, lock released")
}

// START acquire OMIT
func acquire(path string, wait time.Duration, pidfile bool) (func() error, error) {
	if pidfile {
		return acquirePIDFile(path)
	}
	if wait == 0 {
		l, err := fsx.TryLock(path) // *fsx.LockedError if held
		if err != nil {
			return nil, err
		}
		return l.Unlock, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), wait)
	defer cancel()
	l, err := fsx.Acquire(ctx, path)
	if err != nil {
		return nil, fmt.Errorf("gave up waiting: %w", err)
	}
	return l.Unlock, nil
}

// acquirePIDFile is the traditional approach: create the file only if it
// does not exist, write our PID, and delete the file when done. If the
// process dies before deleting it, the file stays behind.
func acquirePIDFile(path string) (func() error, error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		owner, _ := os.ReadFile(path)
		return nil, fmt.Errorf("pid file exists (pid %s): %w", owner, err)
	}
	_, err = f.WriteString(strconv.Itoa(os.Getpid()))
	if err = errors.Join(err, f.Close()); err != nil {
		return nil, err
	}
	return func() error { return os.Remove(path) }, nil
}

// END acquire OMIT
