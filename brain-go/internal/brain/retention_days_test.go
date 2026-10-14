package brain

import (
	"encoding/json"
	"testing"
	"time"
)

// A day's summary is saved before its detail goes, and Your day then answers for that day from it, looking the same.

// yourDay: the Today window for a date as the app asks for it twice (the first ask starts the note and the goals' lines
// in the background, the second has them), as JSON.
func yourDay(t *testing.T, b *Brain, date string) string {
	t.Helper()
	ask := func() TodaySummary {
		b.Lock()
		defer b.Unlock()
		summary, err := b.Today(date)
		if err != nil {
			t.Fatal(err)
		}
		return summary
	}
	ask()
	b.Settle()
	return JSON(ask())
}

func theDays(t *testing.T, b *Brain, from, to string) string {
	t.Helper()
	b.Lock()
	defer b.Unlock()
	days, err := b.Days(from, to)
	if err != nil {
		t.Fatal(err)
	}
	return JSON(days)
}

// historyBrain: a brain over `days` days of seeded history ending the day before the test's "now" (2026-10-04, noon).
func historyBrain(t *testing.T, store *Store, days, perDay int, step time.Duration) (*Brain, int64) {
	t.Helper()
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, Zone()).UnixMilli()
	seedHistory(store, time.UnixMilli(now).In(Zone()), days, perDay, step, nil)
	return NewBrain(BrainOptions{Store: store, Models: &fakeModels{}, Config: func() CompanionConfig { return DefaultConfig }, Now: func() int64 { return now }}), now
}

func dateAgo(now int64, days int) string {
	t := time.UnixMilli(now).In(Zone())
	return dayStart(t.Year(), t.Month(), t.Day()-days).Format("2006-01-02")
}

func TestASavedDayAnswersYourDayTheSameOnceItsDetailIsGone(t *testing.T) {
	store := newPastStore(t)
	b, now := historyBrain(t, store, 12, 1800, 20*time.Second)
	oldest, newest := dateAgo(now, 12), dateAgo(now, 8)

	// Before: what the app is shown for the old days, and for the strip.
	before := map[string]string{}
	for ago := 12; ago >= 8; ago-- {
		before[dateAgo(now, ago)] = yourDay(t, b, dateAgo(now, ago))
	}
	stripBefore := theDays(t, b, oldest, dateAgo(now, 1))
	var segments, goals, steps, comebacks, bests, notes int
	for _, day := range before {
		var summary TodaySummary
		must(json.Unmarshal([]byte(day), &summary))
		segments += len(summary.Segments)
		goals += len(summary.Goals)
		for _, g := range summary.Goals {
			steps += len(g.Steps) + len(g.Workflow)
		}
		comebacks += len(summary.Comebacks)
		if summary.BestComeback != nil {
			bests++
		}
		if summary.Note != nil {
			notes++
		}
	}
	if segments < 50 || goals == 0 || steps == 0 || comebacks == 0 || bests == 0 || notes != 5 {
		t.Fatalf("the seeded days are too thin to prove anything: %d segments, %d goals, %d steps and workflow links, %d comebacks, %d best, %d notes", segments, goals, steps, comebacks, bests, notes)
	}

	// Save them, then let their detail go.
	for ago := 12; ago >= 8; ago-- {
		date := dateAgo(now, ago)
		bounds, _ := dayWindow(date)
		saved := b.frozenDay(date, bounds, now)
		if JSON(saved) != before[date] {
			t.Fatalf("%s: the summary saved isn't what Your day showed:\n%s\n%s", date, JSON(saved), before[date])
		}
		store.SaveDay(date, now, saved)
	}
	through, _ := dayWindow(newest)
	store.AdvancePruned(pastTotals{Through: through.End})
	for _, table := range []string{"verdicts", "samples", "model_calls"} {
		store.exec(`DELETE FROM `+table+` WHERE ts < ?`, through.End)
	}
	if rows := store.Timeline(0, through.End); len(rows) != 0 {
		t.Fatalf("%d verdicts left before the boundary", len(rows))
	}

	oldestDay, _ := dayWindow(oldest)
	if gone, _ := b.buildDay(oldest, oldestDay, now); gone.FocusedMinutes != 0 {
		t.Fatal("the detail is still there: the saved summary answers nothing")
	}
	for date, want := range before {
		if got := yourDay(t, b, date); got != want {
			t.Errorf("%s: Your day changed once the detail went:\n%s\n%s", date, got, want)
		}
	}
	if got := theDays(t, b, oldest, dateAgo(now, 1)); got != stripBefore {
		t.Errorf("the day strip changed once the detail went:\n%s\n%s", got, stripBefore)
	}
	// The detail of the days after is still there, and still read.
	if rows := store.Timeline(through.End, MaxSafeInteger); len(rows) == 0 {
		t.Error("the newer days lost their detail")
	}
}

// What the world reports about the past is a sum over every verdict there ever was, and it must not shrink when old
// verdicts go: a rebuild of its totals starts from the totals of what was deleted.
func TestTheWorldsTotalsDoNotShrinkWhenOldVerdictsGo(t *testing.T) {
	store := newPastStore(t)
	_, now := historyBrain(t, store, 30, 600, 60*time.Second)
	var cache worldCache
	want := JSON(cache.snapshot(store, DefaultConfig, now, inline))
	if cache.past.FocusMs < 30*3_600_000 {
		t.Fatalf("only %d focus minutes in the history", cache.past.FocusMs/60_000)
	}

	// Delete the first 20 days' verdicts, keeping their totals.
	cut, _ := dayWindow(dateAgo(now, 11))
	first := store.FirstVerdictAt()
	store.AdvancePruned(pastTotals{Through: *first}.extend(store, cut.Start, now))
	store.exec(`DELETE FROM verdicts WHERE ts < ?`, cut.Start)
	store.exec(`DELETE FROM samples WHERE ts < ?`, cut.Start)

	store.forgetPast() // the saved totals, as a correction to the past would have deleted them
	var rebuilt worldCache
	if got := JSON(rebuilt.snapshot(store, DefaultConfig, now, inline)); got != want {
		t.Errorf("the world's totals changed when the old verdicts went:\n%s\n%s", got, want)
	}
	if rebuilt.builds != 1 {
		t.Errorf("built %d times, want once, from the totals kept", rebuilt.builds)
	}

	// Without the totals of what was deleted, the world would have lost its history.
	store.exec(`DELETE FROM meta WHERE key = ?`, prunedKey)
	store.forgetPast()
	var without worldCache
	if got := JSON(without.snapshot(store, DefaultConfig, now, inline)); got == want {
		t.Error("the world is the same without the kept totals: the deleted days weren't counted in it at all")
	}
}

func TestDeletingMyDataDeletesTheSavedDaysAndTheBoundaryToo(t *testing.T) {
	store := newPastStore(t)
	b, now := historyBrain(t, store, 3, 300, 60*time.Second)
	date := dateAgo(now, 2)
	bounds, _ := dayWindow(date)
	store.SaveDay(date, now, b.frozenDay(date, bounds, now))
	store.AdvancePruned(pastTotals{Through: bounds.End})
	b.Lock()
	b.DeleteEverything()
	b.Unlock()
	if store.HasSavedDay(date) || store.FirstSavedDay() != nil || store.prunedThrough.Load() != 0 || store.Meta(prunedKey) != nil {
		t.Error("something of the saved days is left after Delete my data")
	}
	b.Lock()
	summary, _ := b.Today(date)
	b.Unlock()
	if summary.FocusedMinutes > 0 || len(summary.Segments) > 0 {
		t.Errorf("Your day still has data for %s: %s", date, JSON(summary))
	}
}
