package brain

import (
	"math/rand"
	"testing"
)

// A scripted day: one verdict every 30 s, so spans touch. Each step is (state, thread, url, activity, minutes).
type step struct {
	state, thread, url, activity string
	minutes                      int
}

func scriptedSpans(steps []step) ([]Span, Window) {
	var rows []TimelineRow
	ts := int64(1_000_000_000)
	start := ts
	for i, s := range steps {
		for k := 0; k < s.minutes*2; k++ {
			row := TimelineRow{SampleID: string(rune('a'+i)) + string(rune('a'+k%26)) + string(rune('a'+k/26)), TS: ts, State: s.state, AppName: "Chrome", BundleID: "com.google.Chrome"}
			if s.thread != "" {
				row.ThreadID = ptr(s.thread)
			}
			if s.url != "" {
				row.URL = ptr("https://" + s.url + "/x")
			}
			if s.activity != "" {
				row.Activity = ptr(s.activity)
			}
			rows = append(rows, row)
			ts += 30_000
		}
	}
	return toSpans(rows, ts), Window{start, ts}
}

func goalsOf(spans []Span, w Window) []GoalDay {
	segments := daySegments(spans, w, func(s Span) SpanLabels { return SpanLabels{Activity: s.Activity} })
	return goalDays(spans, w, segments, 120_000, func(id string) string { return "Goal " + id })
}

func goalByID(goals []GoalDay, id string) *GoalDay {
	for i := range goals {
		if goals[i].ID == id {
			return &goals[i]
		}
	}
	return nil
}

func TestGoalDetoursBelongToTheGoalYouCameBackTo(t *testing.T) {
	spans, w := scriptedSpans([]step{
		{"working", "a", "github.com", "reviewing a PR", 10},
		{"drifting", "", "youtube.com", "", 3},
		{"working", "a", "github.com", "reviewing a PR", 5},
		{"drifting", "", "x.com", "", 2},
		{"working", "b", "docs.stripe.com", "reading the Stripe docs", 4},
	})
	goals := goalsOf(spans, w)
	a, b := goalByID(goals, "a"), goalByID(goals, "b")
	if a == nil || b == nil {
		t.Fatalf("goals: %+v", goals)
	}
	if a.Minutes != 15 || b.Minutes != 4 {
		t.Fatalf("minutes: a %d, b %d", a.Minutes, b.Minutes)
	}
	if a.Detours != 1 || a.DetourMinutes != 3 || a.DetourPlace == nil || *a.DetourPlace != "youtube.com" {
		t.Fatalf("a's detours: %d, %d min, %v", a.Detours, a.DetourMinutes, a.DetourPlace)
	}
	if b.Detours != 0 {
		t.Fatalf("a drift between two goals isn't b's detour: %d", b.Detours)
	}
	if goals[0].ID != "a" || len(a.Apps) != 1 || a.Apps[0].Activities[0] != "reviewing a PR" {
		t.Fatalf("order or apps: %+v", goals)
	}
}

func TestGoalStretchCarriesThroughShortDriftsOnly(t *testing.T) {
	spans, w := scriptedSpans([]step{
		{"working", "a", "", "", 10},
		{"drifting", "", "youtube.com", "", 1},
		{"working", "a", "", "", 5},
		{"drifting", "", "youtube.com", "", 5},
		{"working", "a", "", "", 4},
	})
	a := goalByID(goalsOf(spans, w), "a")
	if a.LongestMinutes != 15 {
		t.Fatalf("longest: %d, want 15 (10 + 5 across a 1-minute drift)", a.LongestMinutes)
	}
	if a.Detours != 2 {
		t.Fatalf("detours: %d", a.Detours)
	}
}

func TestWorkWithoutAGoalIsOtherWorkAndComesLast(t *testing.T) {
	spans, w := scriptedSpans([]step{
		{"working", "", "mail.google.com", "email", 30},
		{"working", "a", "", "", 5},
	})
	goals := goalsOf(spans, w)
	if len(goals) != 2 || goals[1].ID != otherGoalID || goals[1].Title != "Other work" || goals[1].Minutes != 30 {
		t.Fatalf("goals: %+v", goals)
	}
}

// Goal minutes add up to the day's focused minutes (focusStats), give or take rounding per goal.
func TestGoalMinutesAddUpToTheDaysFocus(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	for round := 0; round < 200; round++ {
		spans := randomTimeline(r, 1+r.Intn(600))
		w := Window{spans[0].Start - r.Int63n(600_000), spans[len(spans)-1].Next + 60_000}
		if r.Intn(3) == 0 { // a window that cuts the timeline, like midnight
			w.Start += (w.End - w.Start) / 3
		}
		goals := goalsOf(spans, w)
		var sum int64
		for _, g := range goals {
			sum += g.Minutes
		}
		focus := roundMinutes(focusStats(spans, w, 120_000).FocusMs)
		if diff := sum - focus; diff > int64(len(goals)) || -diff > int64(len(goals)) {
			t.Fatalf("round %d: goals add up to %d min, focus is %d (%d goals)", round, sum, focus, len(goals))
		}
	}
}

func TestGoalLines(t *testing.T) {
	facts := OMap{{"goal_1", OMap{{"goal", "Coding practice"}, {"minutes", int64(93)}}}}
	if line := acceptGoalLine(`"Two LeetCode problems, then the modal exercise in Cursor."`, facts); line == nil || *line != "Two LeetCode problems, then the modal exercise in Cursor" {
		t.Fatalf("a good line: %v", line)
	}
	for _, bad := range []string{"Wasted an hour on YouTube", "Finished 7 problems", "Did a lot. Then more."} {
		if line := acceptGoalLine(bad, facts); line != nil {
			t.Fatalf("accepted %q", bad)
		}
	}
	g := GoalDay{Apps: []GoalApp{{Minutes: 40, Activities: []string{"building the settings screen"}}, {Minutes: 20, Activities: []string{"reading the Stripe docs", "work"}}}}
	if got := activitiesLine(g); got != "Building the settings screen, then reading the Stripe docs" {
		t.Fatalf("activitiesLine: %q", got)
	}
}
