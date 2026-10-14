package brain

import (
	"os"
	"strconv"
	"time"
)

// A brain Moku.app starts is Moku's child, and must not outlive it. If the app is killed or crashes, the brain would
// stay on port 8020 as an orphan: the next Moku would find it answering and adopt it, and never restart it, even if it
// is an older version (0.1.7 left such orphans) or later hangs. So the app tells its brain who its parent is
// (MOKU_PARENT_PID), and the brain shuts down, as for SIGTERM, when that parent is gone. A brain started by hand has
// no such variable and runs until it's stopped.

// ParentPID: the app's pid from MOKU_PARENT_PID, or 0 when the brain wasn't started by one.
func ParentPID(env string) int {
	pid, err := strconv.Atoi(env)
	if err != nil || pid <= 1 {
		return 0
	}
	return pid
}

// WatchParent calls gone once, as soon as this process is no longer pid's child (its parent became launchd, pid 1),
// looking every `every`. It returns at once when pid is 0.
func WatchParent(pid int, every time.Duration, gone func()) {
	if pid == 0 {
		return
	}
	go func() {
		for range time.Tick(every) {
			if os.Getppid() != pid {
				gone()
				return
			}
		}
	}()
}
