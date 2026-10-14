package brain

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"strings"
	"testing"
)

// An hour of Charles's work, replayed through the brain with goal-aware judging off (as today) and on, counting Jev's
// calls and their cost. A sample every 3 s, as the app sends them. The screens and how their words change follow his
// real days (2026-10-01 to 10-03): a streaming page whose subtitles change about half its words, chats that move a
// message every few seconds, docs being scrolled, code being typed. With shadow mode's numbers, about half the calls on
// those screens repeated a window whose words had barely changed.

// pseudoWords: n distinct made-up words for a seed, the same every run.
func pseudoWords(seed string, from, n int) []string {
	out := make([]string, 0, n)
	for i := from; i < from+n; i++ {
		h := sha1.Sum([]byte(fmt.Sprintf("%s-%d", seed, i)))
		out = append(out, "w"+hex.EncodeToString(h[:3]))
	}
	return out
}

// rolling: a page's fixed words plus a window of `shown` lines that moves on one line every `every` ticks.
func rolling(seed string, fixed, lineWords, shown, every, tick int) string {
	words := pseudoWords(seed+"/page", 0, fixed)
	first := tick / every
	for line := first; line < first+shown; line++ {
		words = append(words, pseudoWords(fmt.Sprintf("%s/line%d", seed, line), 0, lineWords)...)
	}
	return strings.Join(words, " ")
}

// typing: a page's words plus words typed so far, one every `every` ticks.
func typing(seed string, fixed, every, tick int) string {
	return strings.Join(append(pseudoWords(seed+"/page", 0, fixed), pseudoWords(seed+"/typed", 0, tick/every)...), " ")
}

type hourSegment struct {
	minutes int
	at      func(tick int) screen
}

func chrome(title, url string) screen {
	return screen{app: "Google Chrome", bundle: "com.google.Chrome", title: title, url: url}
}

func withText(s screen, text string) screen { s.text = text; return s }

var charlesHour = []hourSegment{
	// Building Moku in Cursor (a work app): code being typed.
	{8, func(k int) screen {
		return withText(screen{app: "Cursor", bundle: "com.todesktop.230313mzl4w4u92", title: "goals.go — bunny"}, typing("cursor", 120, 2, k))
	}},
	// Coding practice: a LeetCode problem, solved by typing.
	{8, func(k int) screen {
		return withText(chrome("Two Sum - LeetCode", "https://leetcode.com/problems/two-sum/"), "LeetCode "+typing("leetcode", 110, 3, k))
	}},
	// A tutorial for it on YouTube: comments loading under the video.
	{4, func(k int) screen {
		return withText(chrome("Binary Tree Inorder Traversal Explained - YouTube", "https://www.youtube.com/watch?v=abc123"), "Traversal "+rolling("youtube", 70, 15, 4, 5, k))
	}},
	// WhatsApp: the chat about the bill-splitting app, a message every 12 s.
	{4, func(k int) screen {
		return withText(screen{app: "WhatsApp", bundle: "net.whatsapp.WhatsApp", title: "WhatsApp"}, "Potluck app team "+rolling("wa-split", 10, 8, 15, 4, k))
	}},
	// The same window, another chat: weekend plans.
	{4, func(k int) screen {
		return withText(screen{app: "WhatsApp", bundle: "net.whatsapp.WhatsApp", title: "WhatsApp"}, "Weekend plans "+rolling("wa-weekend", 10, 8, 15, 4, k))
	}},
	// A show on a streaming site that isn't on the known lists: a new subtitle line every 3 s.
	{10, func(k int) screen {
		return withText(chrome("Dark S2 E5 - StreamHub", "https://streamhub.example/watch/dark-s02e05"), rolling("streamhub", 30, 12, 2, 1, k))
	}},
	// Email (a work site): the inbox moving.
	{4, func(k int) screen {
		return withText(chrome("Inbox (3) - sam@example.com - Gmail", "https://mail.google.com/mail/u/0/#inbox"), rolling("gmail", 40, 12, 10, 10, k))
	}},
	// Stripe's docs for the payments work: three pages, each scrolled.
	{8, func(k int) screen {
		page := k / 54
		titles := []string{"Payment Intents API", "Webhooks", "Testing"}
		s := chrome(titles[min(page, 2)]+" | Stripe Documentation", fmt.Sprintf("https://docs.stripe.com/page%d", page))
		return withText(s, "Stripe "+rolling(fmt.Sprintf("stripe%d", page), 110, 10, 6, 7, k))
	}},
	// The X home feed (a known feed: no call either way).
	{5, func(k int) screen {
		return withText(chrome("Home / X", "https://x.com/home"), rolling("x", 20, 20, 5, 2, k))
	}},
	// Back to Cursor.
	{5, func(k int) screen {
		return withText(screen{app: "Cursor", bundle: "com.todesktop.230313mzl4w4u92", title: "goals.go — bunny"}, typing("cursor2", 120, 2, k))
	}},
}

func hourOracle(window, site, text string) screenTruth {
	switch {
	case strings.Contains(window, "goals.go"):
		return screenTruth{goal: "building Moku", p: 0.9, category: "building"}
	case strings.Contains(text, "LeetCode"):
		return screenTruth{goal: "practicing coding problems", p: 0.9, category: "learning"}
	case strings.Contains(text, "Traversal"):
		return screenTruth{goal: "practicing coding problems", p: 0.85, category: "learning"}
	case strings.Contains(text, "Potluck"):
		return screenTruth{goal: "Potluck side project", p: 0.8, category: "communicating"}
	case strings.Contains(window, "Gmail"):
		return screenTruth{goal: "checking email", p: 0.9, category: "communicating"}
	case strings.Contains(text, "Stripe"):
		return screenTruth{goal: "adding Stripe payments", p: 0.85, category: "building"}
	case strings.Contains(site, "streamhub"):
		return screenTruth{goal: goalNone, p: 0.95, category: "watching"}
	}
	return screenTruth{goal: goalNone, p: 0.9, category: "chatting"}
}

type hourRun struct {
	calls    map[string]int
	cost     float64
	verdicts []Verdict
}

func replayHour(t *testing.T, goalJudging bool) hourRun {
	// "Today's" cost in the spec's gate is the focus pipeline as it was when goal-aware judging was specified, one call for
	// every new text. Since launch QA (2026-10-04) the focus pipeline reuses a window's answer too (reuse.go), which is
	// cheaper and steadier, so the gate is measured against the pipeline without it.
	if !goalJudging {
		focusWindowReuse = false
		t.Cleanup(func() { focusWindowReuse = true })
	}
	b := newTestBrain(t, &fakeModels{oracle: hourOracle}, goalJudging)
	start := baseTs
	for _, g := range [][3]string{
		{"building Moku", "Building Moku, a desktop companion for the Mac", "building"},
		{"practicing coding problems", "Practicing coding problems and UI exercises", "learning"},
		{"Potluck side project", "Building a bill-splitting app with friends", "building"},
		{"checking email", "Reading and answering work email", "communicating"},
		{"adding Stripe payments", "Adding Stripe payments and webhooks to Moku", "building"},
	} {
		goal := seedGoal(b.Store, g[0], g[1], start-2*60*minute)
		b.Store.SetThreadCategory(goal.ID, g[2])
		if g[0] == "building Moku" {
			workedOn(b.Store, goal, start-minute)
		}
	}
	run := hourRun{calls: map[string]int{}}
	ts := start
	for _, segment := range charlesHour {
		for k := 0; k < segment.minutes*20; k++ {
			run.verdicts = append(run.verdicts, judgeAt(b, ts, segment.at(k)))
			ts += 3_000
		}
	}
	run.calls = jevCalls(b.Store)
	costs := map[string]float64{}
	for _, c := range b.Store.ModelCalls("") {
		if c.CostUsd != nil && strings.Contains(string(c.Input), "questions") {
			run.cost += *c.CostUsd
			costs[c.Purpose] += *c.CostUsd
		}
	}
	for purpose, cost := range costs {
		t.Logf("goal judging %v: %s calls cost $%.7f each", goalJudging, purpose, cost/float64(run.calls[purpose]))
	}
	return run
}

func TestAReplayedHourCostsAtMost60PercentOfToday(t *testing.T) {
	before, after := replayHour(t, false), replayHour(t, true)
	t.Logf("calls per hour: before %d %v, after %d %v", total(before.calls), before.calls, total(after.calls), after.calls)
	t.Logf("Jev cost per hour: before $%.5f, after $%.5f (%.0f%%)", before.cost, after.cost, 100*after.cost/before.cost)
	if after.cost > 0.6*before.cost || total(after.calls) > total(before.calls)*6/10 {
		t.Errorf("goal-aware judging must cost at most 60%% of today's: $%.5f against $%.5f", after.cost, before.cost)
	}
	// The same states as today, minute by minute, and the goals where they belong.
	differ := 0
	for i := range before.verdicts {
		if before.verdicts[i].State != after.verdicts[i].State {
			differ++
		}
	}
	if differ > len(before.verdicts)/100 {
		t.Errorf("%d of %d verdicts changed state", differ, len(before.verdicts))
	}
	segmentAt := func(minute int) []Verdict { return after.verdicts[minute*20 : minute*20+20] }
	for _, c := range []struct {
		minute   int
		state    string
		goal     string
		switched bool
	}{
		{9, "working", "practicing coding problems", false},
		{17, "working", "practicing coding problems", false},
		{21, "working", "Potluck side project", false},
		{25, "drifting", "", false},
		{30, "drifting", "", false},
		{44, "working", "adding Stripe payments", false},
	} {
		for _, v := range segmentAt(c.minute) {
			title := ""
			if v.Goal != nil {
				title = v.Goal.Title
			}
			if v.State != c.state || title != c.goal {
				t.Errorf("minute %d: %s on %q (%s)", c.minute, v.State, title, v.Reason)
				break
			}
		}
	}
	// Leaving coding practice for the Potluck chat is a switch: calm, the first verdict there says so.
	if first := after.verdicts[20*20]; !first.Switch || first.Goal == nil || first.Goal.Title != "Potluck side project" {
		t.Errorf("the switch to the chat: %+v", first)
	}
}
