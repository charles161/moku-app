package brain

import (
	"fmt"
	"runtime"
	"testing"
	"time"
)

// A long session through the real pipeline (rules, Jev, the labeler, naming, activity) with the fake models: nothing
// the brain starts may be left running, and the world must keep answering. (The binary's own soak, with its memory,
// file descriptors and latencies, is a driver replaying a 10-hour day against a brain: see TestSeedHistory for data.)
func TestAHoursLongSessionLeavesNoGoroutinesBehind(t *testing.T) {
	models := &fakeModels{
		oracle: func(window, site, text string) screenTruth {
			if len(window)%3 == 0 {
				return screenTruth{goal: goalNone, p: 1, category: "scrolling"}
			}
			return screenTruth{goal: "new", p: 1, category: "building"}
		},
	}
	b := newTestBrain(t, models, false)
	runtime.GC()
	before := runtime.NumGoroutine()
	ts := baseTs
	for i := 0; i < 1500; i++ {
		ts += 3000
		page := (i / 15) % 60
		judgeAt(b, ts, screen{app: "Chrome", bundle: "com.google.Chrome", title: fmt.Sprintf("Page %d", page), url: fmt.Sprintf("https://example.com/p/%d", page),
			text: fmt.Sprintf("the words of page %d, reading %d", page, i/45)})
		if i%250 == 0 {
			b.Lock()
			b.World()
			b.Unlock()
		}
	}
	b.Settle()
	time.Sleep(200 * time.Millisecond)
	runtime.GC()
	if after := runtime.NumGoroutine(); after > before+2 {
		t.Errorf("%d goroutines before, %d after 1,500 samples", before, after)
	}
	if n := len(b.Store.ModelCalls("")); n == 0 {
		t.Error("no model call was made, so the pipeline wasn't exercised")
	}
}
