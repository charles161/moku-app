package brain

import (
	"strings"
	"testing"
)

// Your day's labels (docs/specs/next-wave.md §6, from the 2026-09-28 audit): "practicing system design" was there
// twice, and a row said "Claude · using ChatGPT".

// A thread Luna names the same as an older one folds into it, without goal-aware judging too.
func TestAThreadNamedLikeAnOlderOneMergesIntoIt(t *testing.T) {
	design := screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Designing a rate limiter", url: "https://bytebytego.com/courses/rate-limiter",
		text: "Design a rate limiter token bucket leaking bucket sliding window"}
	models := &fakeModels{
		oracle: func(window, _, _ string) screenTruth {
			if strings.Contains(window, "rate limiter") {
				return screenTruth{goal: goalNew, p: 0.9, category: "learning"}
			}
			return screenTruth{goal: goalNone, p: 0.9}
		},
		names: func(string) (string, string, string) {
			return "Practicing system design", "Practicing system design problems", "practicing system design"
		},
	}
	b := newTestBrain(t, models, false)
	older := seedGoal(b.Store, "practicing system design", "Practicing system design problems", baseTs-24*60*minute)
	// Work; the labeler starts a thread for it, and Luna names it like the older one.
	v := judgeAt(b, baseTs, design)
	if v.State != "working" {
		t.Fatalf("work: %+v", v)
	}
	if threads := b.Store.AllThreads(); len(threads) != 1 || threads[0].ID != older.ID || threads[0].Title != "practicing system design" {
		t.Fatalf("one thread, the older one's name: %+v", threads)
	}
	if stored, _ := b.Store.Verdict(v.SampleID); stored.ThreadID == nil || *stored.ThreadID != older.ID {
		t.Fatalf("the verdict moved to the older thread: %+v", stored)
	}
	if calls := jevCalls(b.Store); calls["dedupe"] != 0 {
		t.Fatalf("no model call for a repeat this plain: %v", calls)
	}
}

// Repeats named before merging existed fold in at startup: into the oldest, which keeps its name.
func TestRepeatsAlreadyThereMergeAtStartup(t *testing.T) {
	b := newTestBrain(t, &fakeModels{}, false)
	first := seedGoal(b.Store, "practicing system design", "Drills", baseTs-3*24*60*minute)
	seedGoal(b.Store, "Practicing system  design", "Drills again", baseTs-24*60*minute)
	seedGoal(b.Store, "practicing system design", "And again", baseTs-60*minute)
	doc := seedGoal(b.Store, "writing the onboarding doc", "Writing the onboarding doc", baseTs-2*60*minute)
	// A thread still on its placeholder isn't a repeat yet.
	b.Store.CreateThread(newThreadID(), "practicing system design", "Placeholder", baseTs, nil)
	merges := b.MergeSameTitles()
	if len(merges) != 2 || merges[0].Into != first.ID || merges[1].Into != first.ID {
		t.Fatalf("merges %+v", merges)
	}
	var ids []string
	for _, th := range b.Store.AllThreads() {
		ids = append(ids, th.ID)
	}
	if len(ids) != 3 || !strings.Contains(strings.Join(ids, " "), first.ID) || !strings.Contains(strings.Join(ids, " "), doc.ID) {
		t.Fatalf("threads left %v", ids)
	}
	if again := b.MergeSameTitles(); len(again) != 0 {
		t.Fatalf("nothing left to merge: %+v", again)
	}
}

func TestAPhraseNamingAnotherAppDoesNotLabelThisOne(t *testing.T) {
	names := append(knownPlaceNames(), "Claude", "ChatGPT", "Notes", "Cursor")
	for _, c := range []struct {
		phrase, app string
		host        *string
		other       bool
	}{
		{"using ChatGPT", "Claude", nil, true},
		{"using ChatGPT", "ChatGPT", nil, false},
		{"using ChatGPT", "Google Chrome", ptr("chatgpt.com"), false},
		{"reviewing PRs on GitHub", "Cursor", nil, true},
		{"reviewing PRs on GitHub", "Google Chrome", ptr("github.com"), false},
		{"building Moku", "Cursor", nil, false},
		{"writing notes", "Cursor", nil, false},      // a word, not the Notes app
		{"using ChatGPTs API", "Claude", nil, false}, // inside a longer word
	} {
		if got := namesOtherPlace(c.phrase, names, c.app, c.host); got != c.other {
			t.Errorf("%q on %s (%v): %v", c.phrase, c.app, c.host, got)
		}
	}
}

// One thread over two apps, its phrase written in ChatGPT: the ChatGPT row keeps it, the Claude row doesn't.
func TestYourDayGivesEachAppItsOwnPhrase(t *testing.T) {
	store, err := OpenStore(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.Close)
	bundles["ChatGPT"] = "com.openai.chat"
	defer delete(bundles, "ChatGPT")
	spans, w := movedSpans([]move{
		{"working", "t_design", "ChatGPT", "Rate limiter", "", "using ChatGPT", 10 * 60},
		{"working", "t_design", "Claude", "Consistent hashing", "", "using ChatGPT", 10 * 60},
	})
	rows := builtRows(daySegments(spans, w, labelResolver(store, spans)))
	got := map[string]string{}
	for _, r := range rows {
		got[r.App] = r.Activity
	}
	if got["ChatGPT"] != "using ChatGPT" || got["Claude"] != NeutralWords.Work {
		t.Fatalf("rows %v", got)
	}
}
