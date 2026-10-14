package brain

import (
	"strings"
	"testing"
)

// The tuning loop: his ratings are the test set; a new version is replayed on them and scored against them.
func TestReplayScoresANewVersionAgainstHisRatings(t *testing.T) {
	b, goals := calibratingBrain(t)
	workedOn(b.Store, goals["practicing coding problems"], baseTs-minute)
	at := run(b, baseTs, 10, leetcode)
	at = run(b, at, 10, potluckChat)
	run(b, at, 10, weekendChat)
	date := localDate(baseTs)
	moments := b.moments(baseTs, baseTs+60*minute)
	if len(moments) != 3 {
		t.Fatalf("moments %+v", moments)
	}
	// He agrees with the LeetCode goal and the weekend drift, but says the Potluck chat was a drift too.
	for i, rating := range []Rating{{OK: true}, {OK: false, Truth: ptr("drift")}, {OK: true}} {
		if err := b.rateMoment(date, moments[i].ID, rating); err != nil {
			t.Fatal(err)
		}
	}
	// A new version that calls that chat a drift.
	stricter := &fakeModels{oracle: func(window, site, text string) screenTruth {
		if strings.Contains(text, "Potluck") {
			return screenTruth{goal: goalNone, p: 0.7, category: "chatting"}
		}
		return charlesDay(window, site, text)
	}}
	report := ReplayRatings(b.Store, stricter, 0)
	if report.Moments != 3 || report.Calls != 3 {
		t.Fatalf("replayed %d moments with %d calls", report.Moments, report.Calls)
	}
	if *report.Before.DriftRecall != 0.5 || *report.After.DriftRecall != 1 || *report.After.DriftPrecision != 1 || *report.After.GoalRight != 1 {
		t.Fatalf("before %+v, after %+v", report.Before, report.After)
	}
	if len(report.Changed) != 1 || report.Changed[0].Was != "switch: Potluck side project" || report.Changed[0].Now != "drift" || !report.Changed[0].RightNow {
		t.Fatalf("changed %+v", report.Changed)
	}
	table := ReplayTable(report)
	for _, want := range []string{"3 rated moments replayed", "Drift recall", "50%", "100%", "Jev: 3 calls", "✓", "switch: Potluck side project → drift (really drift)"} {
		if !strings.Contains(table, want) {
			t.Errorf("the table lacks %q:\n%s", want, table)
		}
	}
}

// A moment he marked right that a new version gets wrong counts against it: here a ✓ drift that becomes work.
func TestReplayCountsANewMistakeOnAMomentMarkedRight(t *testing.T) {
	b, goals := calibratingBrain(t)
	workedOn(b.Store, goals["practicing coding problems"], baseTs-minute)
	at := run(b, baseTs, 10, leetcode)
	run(b, at, 10, weekendChat)
	moments := b.moments(baseTs, baseTs+60*minute)
	for _, m := range moments {
		if err := b.rateMoment(localDate(baseTs), m.ID, Rating{OK: true}); err != nil {
			t.Fatal(err)
		}
	}
	lenient := &fakeModels{oracle: func(window, site, text string) screenTruth {
		if strings.Contains(text, "Weekend") {
			return screenTruth{goal: "Potluck side project", p: 0.6}
		}
		return charlesDay(window, site, text)
	}}
	report := ReplayRatings(b.Store, lenient, 0)
	if *report.Before.DriftRecall != 1 || report.After.DriftsTrue != 1 || *report.After.DriftRecall != 0 || *report.After.GoalRight != 1 {
		t.Fatalf("before %+v, after %+v", report.Before, report.After)
	}
	if len(report.Changed) != 1 || report.Changed[0].RightNow || report.Changed[0].Truth != "drift" {
		t.Fatalf("changed %+v", report.Changed)
	}
}

// The replay's copy: whole and consistent while another connection writes in WAL mode, never the original.
func TestCopyDatabaseIsConsistentWhileTheBrainWrites(t *testing.T) {
	dir := t.TempDir()
	from, to := dir+"/moku.sqlite", dir+"/copy.sqlite"
	store, err := OpenStore(from)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	seedGoal(store, "writing the onboarding doc", "Writing the onboarding doc", baseTs)
	if err := CopyDatabase(from, to); err != nil {
		t.Fatal(err)
	}
	seedGoal(store, "building Moku", "Building Moku", baseTs) // after the copy: not in it
	copied, err := OpenStore(to)
	if err != nil {
		t.Fatal(err)
	}
	defer copied.Close()
	if threads := copied.AllThreads(); len(threads) != 1 || threads[0].Title != "writing the onboarding doc" {
		t.Fatalf("copy %+v", threads)
	}
	if len(store.AllThreads()) != 2 {
		t.Fatalf("the original is untouched")
	}
}
