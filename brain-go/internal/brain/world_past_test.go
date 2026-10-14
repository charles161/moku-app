package brain

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

// A long history is read once, a day at a time, and kept: the world no longer reads it all at every start (17 s and
// 676 MB on 90 days) with the brain's lock held. See worldCache.

// seedDays: `days` days of work, a verdict every 3 minutes from 09:00 to 17:00, on two goals, with a drift every ninth
// verdict, ending the day before `last`.
func seedDays(t *testing.T, store *Store, last time.Time, days int) {
	t.Helper()
	for _, id := range []string{"goal-a", "goal-b"} {
		if store.Thread(id) == nil {
			store.CreateThread(id, "Goal "+id, "", 0, nil)
		}
	}
	n := 0
	for d := days; d >= 1; d-- {
		day := time.Date(last.Year(), last.Month(), last.Day()-d, 9, 0, 0, 0, Zone())
		for i := 0; i < 160; i++ {
			ts := day.Add(time.Duration(i) * 3 * time.Minute).UnixMilli()
			id := fmt.Sprintf("seed-%d", n)
			n++
			store.InsertSample(ActivitySample{ID: id, TS: float64(ts), App: AppInfo{BundleID: "b.edit", Name: "Editor"}, Window: &WindowInfo{Title: "a file"}})
			state, thread := "working", &ThreadRef{ID: []string{"goal-a", "goal-b"}[(d+i/40)%2]}
			if i%9 == 8 {
				state, thread = "drifting", nil
			}
			store.InsertVerdict(Verdict{SampleID: id, State: state, Thread: thread, Source: "test"}, ts)
		}
	}
}

func newPastStore(t *testing.T) *Store {
	t.Helper()
	store, err := OpenStore(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.Close)
	return store
}

func TestALongHistoryIsReadADayAtATimeWithTheLockLetGoBetweenDaysAndThenKept(t *testing.T) {
	store := newPastStore(t)
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, Zone()).UnixMilli()
	seedDays(t, store, time.UnixMilli(now), 60)
	b := NewBrain(BrainOptions{Store: store, Models: &fakeModels{}, Config: func() CompanionConfig { return DefaultConfig }, Now: func() int64 { return now }})

	// Called as the brain's handlers do, with the lock held; while the lock is let go, anyone else can have it.
	yields, free := 0, 0
	b.Lock()
	world := b.world.snapshot(store, DefaultConfig, now, func(fn func()) {
		yields++
		b.Unlock()
		if b.TryLock() { // a judgment arriving while a day is built gets the lock at once
			free++
			b.Unlock()
		}
		fn()
		b.Lock()
	})
	b.Unlock()
	if b.world.builds != 1 || b.world.steps < 55 {
		t.Errorf("built %d times in %d steps, want once, a step a day", b.world.builds, b.world.steps)
	}
	if yields < b.world.steps-2 || free != yields {
		t.Errorf("the lock was let go %d times (free %d) in %d steps", yields, free, b.world.steps)
	}
	if want := worldSnapshotFrom(store, DefaultConfig, now, b.world.past.Through); JSON(world) != JSON(want) {
		t.Errorf("the world differs from the timeline read in one go:\n%s\n%s", JSON(world), JSON(want))
	}
	// A verdict covers a minute (the samples are 3 minutes apart), 160 a day, 8 in 9 of them work.
	if world.FocusMinutesAllTime < 60*140 {
		t.Errorf("only %d focused minutes in 60 days of work", world.FocusMinutesAllTime)
	}

	// A new brain (a restart) loads the totals; it doesn't read the history.
	var restarted worldCache
	again := restarted.snapshot(store, DefaultConfig, now, inline)
	if restarted.builds != 0 || restarted.steps != 0 {
		t.Errorf("after a restart it built %d times in %d steps", restarted.builds, restarted.steps)
	}
	if JSON(again) != JSON(world) {
		t.Error("a restart changed the answer")
	}

	// The next day it reads that one day.
	tomorrow := now + 24*3_600_000
	restarted.snapshot(store, DefaultConfig, tomorrow, inline)
	if restarted.builds != 0 || restarted.steps != 1 {
		t.Errorf("a day later it built %d times in %d steps, want one step", restarted.builds, restarted.steps)
	}
}

func TestACorrectionToThePastDeletesTheSavedTotalsAtOnceAndTheyAreBuiltAgain(t *testing.T) {
	store := newPastStore(t)
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, Zone()).UnixMilli()
	seedDays(t, store, time.UnixMilli(now), 10)
	var cache worldCache
	cache.snapshot(store, DefaultConfig, now, inline)
	if store.Meta(worldPastKey) == nil {
		t.Fatal("the totals weren't saved")
	}

	store.Relabel([]string{"seed-5", "seed-6"}, "drifting", now) // "this wasn't work", ten days back
	if store.Meta(worldPastKey) != nil {
		t.Error("a correction to the past left the saved totals, which a crash would then bring back")
	}
	world := cache.snapshot(store, DefaultConfig, now, inline)
	if cache.builds != 2 {
		t.Errorf("built %d times, want again after the correction", cache.builds)
	}
	if want := worldSnapshotFrom(store, DefaultConfig, now, cache.past.Through); JSON(world) != JSON(want) {
		t.Error("the world doesn't have the correction")
	}
	if whole := worldSnapshot(store, DefaultConfig, now); world.FocusMinutesAllTime != whole.FocusMinutesAllTime {
		t.Errorf("%d focused minutes, the whole timeline says %d", world.FocusMinutesAllTime, whole.FocusMinutesAllTime)
	}
}

func TestSavedTotalsAreNotUsedWhenTheStartHousekeepingChangedThePast(t *testing.T) {
	store := newPastStore(t)
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, Zone()).UnixMilli()
	seedDays(t, store, time.UnixMilli(now), 10)
	var first worldCache
	first.snapshot(store, DefaultConfig, now, inline) // saved

	// The next start: threads named the same are merged before the first call (main.go), which moves old verdicts.
	store.pastLookahead.Store(0) // this process hasn't loaded them yet, so nothing deleted them
	store.MergeThread("goal-b", "goal-a")
	var restarted worldCache
	world := restarted.snapshot(store, DefaultConfig, now, inline)
	if restarted.builds != 1 {
		t.Errorf("the totals saved before the merge were used (%d builds)", restarted.builds)
	}
	if len(world.Threads) != 1 || world.Threads[0].ID != "goal-a" {
		t.Errorf("threads after the merge: %+v", world.Threads)
	}
}

func TestADamagedSavedTotalIsIgnored(t *testing.T) {
	store := newPastStore(t)
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, Zone()).UnixMilli()
	seedDays(t, store, time.UnixMilli(now), 5)
	for _, junk := range []string{"not json", `{"through":0}`, `{"through":5,"lookahead":1}`, `{"through":5,"lookahead":9,"focusMs":-3}`, `[]`} {
		store.SetMeta(worldPastKey, junk)
		var cache worldCache
		world := cache.snapshot(store, DefaultConfig, now, inline)
		if want := worldSnapshotFrom(store, DefaultConfig, now, cache.past.Through); JSON(world) != JSON(want) || cache.builds != 1 {
			t.Errorf("%q: %d builds, answer differs", junk, cache.builds)
		}
	}
}

func TestTwoCallsDuringABuildShareIt(t *testing.T) {
	store := newPastStore(t)
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, Zone()).UnixMilli()
	seedDays(t, store, time.UnixMilli(now), 30)
	b := NewBrain(BrainOptions{Store: store, Models: &fakeModels{}, Config: func() CompanionConfig { return DefaultConfig }, Now: func() int64 { return now }})
	var wg sync.WaitGroup
	answers := make([]string, 4)
	for i := range answers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			b.Lock()
			defer b.Unlock()
			answers[i] = JSON(b.World())
		}()
	}
	wg.Wait()
	if b.world.builds != 1 {
		t.Errorf("%d builds for 4 calls", b.world.builds)
	}
	for i := 1; i < len(answers); i++ {
		if answers[i] != answers[0] {
			t.Errorf("call %d answered differently", i)
		}
	}
}

func TestAHistoryWithNothingBeforeYesterdayNeedsNoBuild(t *testing.T) {
	store := newPastStore(t)
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, Zone()).UnixMilli()
	seedDays(t, store, time.UnixMilli(now), 1)
	var cache worldCache
	world := cache.snapshot(store, DefaultConfig, now, inline)
	if cache.steps != 0 {
		t.Errorf("%d days read for a history of one day", cache.steps)
	}
	if want := worldSnapshot(store, DefaultConfig, now); JSON(world) != JSON(want) {
		t.Error("the world differs from the whole timeline")
	}
	var empty worldCache
	if w := empty.snapshot(newPastStore(t), DefaultConfig, now, inline); w.FocusMinutesAllTime != 0 || len(w.Threads) != 0 {
		t.Errorf("an empty store has a world: %+v", w)
	}
}
