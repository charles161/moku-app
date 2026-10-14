package brain

import (
	"os"
	"testing"
	"time"
)

func TestTheBrainStopsWhenItsParentIsGone(t *testing.T) {
	gone := make(chan struct{}, 1)
	WatchParent(os.Getppid()+1_000_000, 5*time.Millisecond, func() { gone <- struct{}{} }) // some other process's child
	select {
	case <-gone:
	case <-time.After(2 * time.Second):
		t.Fatal("a brain whose parent is gone keeps running")
	}
}

func TestTheBrainKeepsRunningWhileItsParentLives(t *testing.T) {
	gone := make(chan struct{}, 1)
	WatchParent(os.Getppid(), 5*time.Millisecond, func() { gone <- struct{}{} })
	select {
	case <-gone:
		t.Fatal("the brain stopped although its parent is alive")
	case <-time.After(150 * time.Millisecond):
	}
}

func TestABrainStartedByHandHasNoParentToWatch(t *testing.T) {
	for _, env := range []string{"", "x", "0", "1", "-5"} {
		if pid := ParentPID(env); pid != 0 {
			t.Errorf("%q gives %d", env, pid)
		}
	}
	if ParentPID("4242") != 4242 {
		t.Error("a real pid is ignored")
	}
	called := false
	WatchParent(0, time.Millisecond, func() { called = true })
	time.Sleep(20 * time.Millisecond)
	if called {
		t.Error("watched a parent that doesn't exist")
	}
}
