package brain

import (
	"strings"
	"testing"
)

// Goal-aware judging's decisions (docs/specs/goal-aware-judging.md), each on a short real-looking sequence, with the
// calls it makes.

var (
	cursor   = screen{app: "Cursor", bundle: "com.todesktop.230313mzl4w4u92", title: "goals.go — bunny", text: "package brain func decideGoal answer goals media"}
	leetcode = screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Two Sum - LeetCode", url: "https://leetcode.com/problems/two-sum/",
		text: "Two Sum Easy Given an array of integers nums and an integer target return indices of the two numbers such that they add up to target"}
	tutorial = screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Binary Tree Inorder Traversal Explained - YouTube", url: "https://www.youtube.com/watch?v=abc123",
		text: "Binary Tree Inorder Traversal Explained NeetCode subscribe 1.2M views left root right recursion stack"}
	weekendChat = screen{app: "WhatsApp", bundle: "net.whatsapp.WhatsApp", title: "WhatsApp",
		text: "Weekend plans Arun: goa or pondy this weekend? Meera: pondy! beaches and cafes Arun: booking the bus tickets tonight"}
	potluckChat = screen{app: "WhatsApp", bundle: "net.whatsapp.WhatsApp", title: "WhatsApp",
		text: "Potluck app team Ravi: pushed the settle-up screen Charles: reviewing the expense split logic tonight Ravi: tests are green"}
	xHome = screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Home / X", url: "https://x.com/home", text: "For you Following trending posts"}
)

// charlesDay: the oracle for these screens.
func charlesDay(window, site, text string) screenTruth {
	switch {
	case strings.Contains(window, "goals.go"):
		return screenTruth{goal: "building Moku", p: 0.9, category: "building"}
	case strings.Contains(window, "LeetCode"), strings.Contains(window, "Traversal"):
		return screenTruth{goal: "practicing coding problems", p: 0.9, category: "learning"}
	case strings.Contains(text, "Potluck"):
		return screenTruth{goal: "Potluck side project", p: 0.8, category: "communicating"}
	case strings.Contains(text, "Weekend"):
		return screenTruth{goal: goalNone, p: 0.9, category: "chatting"}
	}
	return screenTruth{goal: goalNone, p: 0.9, category: "other"}
}

func goalBrain(t *testing.T) (*Brain, *fakeModels, map[string]*ThreadRow) {
	models := &fakeModels{oracle: charlesDay}
	b := newTestBrain(t, models, true)
	goals := map[string]*ThreadRow{}
	for _, g := range [][3]string{
		{"building Moku", "Building Moku, a desktop companion for the Mac", "building"},
		{"practicing coding problems", "Practicing coding problems and UI exercises", "learning"},
		{"Potluck side project", "Building a bill-splitting app with friends", "building"},
	} {
		goal := seedGoal(b.Store, g[0], g[1], baseTs-60*minute)
		b.Store.SetThreadCategory(goal.ID, g[2])
		goals[g[0]] = b.Store.Thread(goal.ID)
	}
	return b, models, goals
}

func TestGoalJudgingIsOffUnlessSwitchedOn(t *testing.T) {
	for _, c := range []struct {
		env               map[string]string
		goals, calibrates bool
	}{
		{map[string]string{}, false, false},
		{map[string]string{"MOKU_GOAL_JUDGING": "1"}, true, false},
		// A brain not linked for calibration (every release) never calibrates, whatever its environment says.
		{map[string]string{"MOKU_CALIBRATE": "1"}, false, false},
		{map[string]string{"MOKU_CALIBRATE": "0"}, false, false},
	} {
		goals, calibrate := GoalModes(func(k string) string { return c.env[k] })
		if goals != c.goals || calibrate != c.calibrates {
			t.Errorf("%v: goals %v, calibrate %v", c.env, goals, calibrate)
		}
	}
	// Charles's calibration build (scripts/build-app.sh with MOKU_CALIBRATE=1 links calibrationBuild=1).
	defer func(was string) { calibrationBuild = was }(calibrationBuild)
	calibrationBuild = "1"
	if goals, calibrate := GoalModes(func(k string) string { return map[string]string{"MOKU_CALIBRATE": "1"}[k] }); !goals || !calibrate {
		t.Errorf("a calibration build with MOKU_CALIBRATE=1: goals %v, calibrate %v", goals, calibrate)
	}
	if _, calibrate := GoalModes(func(string) string { return "" }); calibrate {
		t.Errorf("a calibration build without MOKU_CALIBRATE calibrates")
	}
	// Off: the old pipeline, two calls (judge, then label), and verdicts carry no goal.
	models := &fakeModels{oracle: charlesDay}
	b := newTestBrain(t, models, false)
	seedGoal(b.Store, "practicing coding problems", "Practicing coding problems and UI exercises", baseTs-minute)
	v := judgeAt(b, baseTs, leetcode)
	if v.State != "working" || v.Goal != nil || v.Switch || !strings.HasPrefix(v.Reason, "[jev]") {
		t.Fatalf("off: %+v", v)
	}
	if calls := jevCalls(b.Store); calls["judge"] != 1 || calls["label"] != 1 || calls["goal"] != 0 {
		t.Fatalf("off: calls %v", calls)
	}
	if b.TextKeepMs() != TextKeepMs {
		t.Fatalf("screen text kept %d ms without calibration", b.TextKeepMs())
	}
}

func TestOneGoalCallAnswersTheStateTheGoalAndTheBucket(t *testing.T) {
	b, models, goals := goalBrain(t)
	workedOn(b.Store, goals["practicing coding problems"], baseTs-minute)
	v := judgeAt(b, baseTs, leetcode)
	if v.State != "working" || v.Goal == nil || v.Goal.ID != goals["practicing coding problems"].ID || v.Switch {
		t.Fatalf("on the current goal: %+v", v)
	}
	if v.Thread == nil || v.Thread.ID != v.Goal.ID || v.Category == nil || *v.Category != "learning" || v.Activity == nil {
		t.Fatalf("labels come with the state, the bucket the goal's: %+v", v)
	}
	if !strings.HasPrefix(v.Reason, `[goal] p=0.90 "practicing coding problems"`) || v.Confidence != 0.9 || v.Source != "jev" {
		t.Fatalf("reason %q, confidence %v, source %s", v.Reason, v.Confidence, v.Source)
	}
	if calls := jevCalls(b.Store); calls["goal"] != 1 || total(calls) != 1 {
		t.Fatalf("one call, not judge plus label: %v (%v)", calls, models.asked)
	}
	// What Jev was asked: the current goal first, then the recent ones, then new and none; the current goal's title in
	// the state; and the bucket in the same call.
	call := b.Store.ModelCalls("goal")[0]
	input := string(call.Input)
	if strings.Contains(input, `"category"`) {
		t.Errorf("the bucket isn't asked: the call stays small")
	}
	for _, want := range []string{`"current_goal":"practicing coding problems"`, `"questions":{"goal":`,
		`"new":"New work: real work that serves none of these goals"`, `"none":"Not work:`} {
		if !strings.Contains(input, want) {
			t.Errorf("the goal call's input lacks %s:\n%s", want, input)
		}
	}
	if first := strings.Index(input, goals["practicing coding problems"].ID); first < 0 || first > strings.Index(input, goals["building Moku"].ID) {
		t.Errorf("the current goal isn't offered first: %s", input)
	}
}

func TestAnotherGoalIsACalmSwitch(t *testing.T) {
	b, _, goals := goalBrain(t)
	workedOn(b.Store, goals["practicing coding problems"], baseTs-minute)
	v := judgeAt(b, baseTs, potluckChat)
	if v.State != "working" || v.Goal == nil || v.Goal.ID != goals["Potluck side project"].ID || !v.Switch {
		t.Fatalf("another goal: %+v", v)
	}
	// From then on it's the current goal: on goal, no longer a switch.
	next := judgeAt(b, baseTs+3_000, screen{app: "WhatsApp", bundle: "net.whatsapp.WhatsApp", title: "WhatsApp", text: potluckChat.text + " Charles: merging it"})
	if next.State != "working" || next.Goal == nil || next.Goal.ID != v.Goal.ID || next.Switch {
		t.Fatalf("on goal after the switch: %+v", next)
	}
}

func TestNoGoalIsADrift(t *testing.T) {
	b, _, goals := goalBrain(t)
	workedOn(b.Store, goals["Potluck side project"], baseTs-minute)
	// The same app, the same window title: the chat about the app is work, the weekend chat isn't.
	v := judgeAt(b, baseTs, weekendChat)
	if v.State != "drifting" || v.Goal != nil || v.Switch || v.Thread != nil {
		t.Fatalf("not work: %+v", v)
	}
	if v.Category == nil || *v.Category != "chatting" || v.Activity == nil || *v.Activity != "chatting on WhatsApp" || !strings.HasPrefix(v.Reason, "[goal] none p=0.90") {
		t.Fatalf("drift labels: %+v", v)
	}
}

func TestMediaSitesKeepTheStricterBar(t *testing.T) {
	cases := []struct {
		name  string
		truth screenTruth
		state string
		goal  string
	}{
		{"work p=0.7 drifts on a media site", screenTruth{dist: map[string]float64{"practicing coding problems": 0.7, goalNone: 0.3}, category: "learning"}, "drifting", ""},
		{"a goal at p=0.85", screenTruth{goal: "practicing coding problems", p: 0.85, category: "learning"}, "working", "practicing coding problems"},
		{"work but no goal at p=0.8", screenTruth{dist: map[string]float64{"practicing coding problems": 0.6, goalNew: 0.35, goalNone: 0.05}, category: "learning"}, "working", ""},
		{"never a new goal", screenTruth{dist: map[string]float64{goalNew: 0.9, goalNone: 0.1}, category: "learning"}, "working", ""},
	}
	for _, c := range cases {
		models := &fakeModels{oracle: func(string, string, string) screenTruth { return c.truth }}
		b := newTestBrain(t, models, true)
		seedGoal(b.Store, "practicing coding problems", "Practicing coding problems and UI exercises", baseTs-minute)
		v := judgeAt(b, baseTs, tutorial)
		title := ""
		if v.Goal != nil {
			title = v.Goal.Title
		}
		if v.State != c.state || title != c.goal || !strings.HasPrefix(v.Reason, "[media]") || len(b.Store.AllThreads()) != 1 {
			t.Errorf("%s: %s on %q (%s), %d goals", c.name, v.State, title, v.Reason, len(b.Store.AllThreads()))
		}
	}
}

func TestANewGoalIsCheckedAgainstTheExistingOnes(t *testing.T) {
	handbook := screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Acme handbook - First week", url: "https://handbook.acme.example/first-week",
		text: "Acme handbook Your first week accounts tools who to ask ship a small fix"}
	models := &fakeModels{
		oracle: func(window, _, _ string) screenTruth {
			if strings.Contains(window, "Acme handbook") {
				return screenTruth{goal: goalNew, p: 0.8, category: "building"}
			}
			return screenTruth{goal: goalNone, p: 0.9}
		},
		names: func(string) (string, string, string) {
			return "drafting the Acme handbook", "Writing the handbook for people new at Acme", "drafting the handbook"
		},
		same: func(title string) (string, float64) {
			if title == "drafting the Acme handbook" {
				return "writing the onboarding doc", 0.9
			}
			return "", 0
		},
	}
	b := newTestBrain(t, models, true)
	onboarding := seedGoal(b.Store, "writing the onboarding doc", "Writing the onboarding doc for new engineers", baseTs-24*60*minute)
	v := judgeAt(b, baseTs, handbook)
	if v.State != "working" || !v.IsNewThread || v.Goal == nil || !v.Goal.Provisional {
		t.Fatalf("a new goal, provisional until named: %+v", v)
	}
	// Luna named it; Jev found it repeats the onboarding doc; it folded into it.
	if threads := b.Store.AllThreads(); len(threads) != 1 || threads[0].ID != onboarding.ID {
		t.Fatalf("goals after the check: %+v", threads)
	}
	if stored, _ := b.Store.Verdict(v.SampleID); stored.ThreadID == nil || *stored.ThreadID != onboarding.ID {
		t.Fatalf("the verdict moved to the onboarding doc: %+v", stored)
	}
	// A repeat of the same screen reuses the answer, on the goal it folded into.
	again := judgeAt(b, baseTs+3_000, handbook)
	if again.Goal == nil || again.Goal.ID != onboarding.ID || again.IsNewThread || !strings.HasPrefix(again.Reason, "[reuse]") {
		t.Fatalf("reused after the merge: %+v", again)
	}
	if calls := jevCalls(b.Store); calls["goal"] != 1 || calls["dedupe"] != 1 {
		t.Fatalf("calls %v", calls)
	}
	// A different goal stays.
	models.same = func(string) (string, float64) { return "", 0 }
	other := screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Acme handbook — Sales", url: "https://handbook.acme.example/sales", text: "Acme sales"}
	models.names = func(string) (string, string, string) {
		return "learning pottery", "Learning to throw pots", "learning pottery"
	}
	judgeAt(b, baseTs+60_000, other)
	if n := len(b.Store.AllThreads()); n != 2 {
		t.Fatalf("a different goal is kept: %d goals", n)
	}
}

func TestReuseCutsRepeatsAndAsksAgainOnABigChange(t *testing.T) {
	b, _, goals := goalBrain(t)
	workedOn(b.Store, goals["practicing coding problems"], baseTs-minute)
	step := func(at int64, s screen) Verdict { return judgeAt(b, baseTs+at, s) }
	calls := func() int { return jevCalls(b.Store)["goal"] }
	typed := func(s screen, words string) screen { s.text += " " + words; return s }

	step(0, leetcode)
	// Typing a solution: the words barely change. Reused, with no call, for up to 5 minutes from the call.
	for i, at := range []int64{9_000, 60_000, 150_000, 290_000} {
		v := step(at, typed(leetcode, strings.Repeat("hashmap ", i+1)+"seen complement"))
		if !strings.HasPrefix(v.Reason, "[reuse] mostly the same words") || v.Goal == nil || v.Source != "shortcut" {
			t.Fatalf("at %d s: %+v", at/1000, v)
		}
	}
	if calls() != 1 {
		t.Fatalf("reused: %d calls", calls())
	}
	// Five minutes after the call: asked again.
	step(301_000, typed(leetcode, "return indices"))
	if calls() != 2 {
		t.Fatalf("after 5 min: %d calls", calls())
	}
	// The same app and window title, but another chat: a big change, asked at once.
	step(310_000, potluckChat)
	v := step(313_000, weekendChat)
	if calls() != 4 || v.State != "drifting" {
		t.Fatalf("another chat: %d calls, %s", calls(), v.State)
	}
	// The exact same screen keeps its answer for 10 minutes, as rule same-screen did.
	v = step(313_000+9*60_000, weekendChat)
	if calls() != 4 || !strings.HasPrefix(v.Reason, "[reuse] the same screen") {
		t.Fatalf("the same screen: %d calls, %s", calls(), v.Reason)
	}
}

func TestTheRulesComeFirst(t *testing.T) {
	b, _, goals := goalBrain(t)
	workedOn(b.Store, goals["practicing coding problems"], baseTs-minute)
	// A known feed drifts with no call.
	if v := judgeAt(b, baseTs, xHome); v.State != "drifting" || !strings.HasPrefix(v.Reason, "[known-feed]") {
		t.Fatalf("feed: %+v", v)
	}
	// A work app is work by rule: it only needs its goal, asked once for its window (the labeler's cache). The goal
	// arrives a moment later, on the next verdict and in the first one's stored row.
	first := judgeAt(b, baseTs+3_000, cursor)
	if first.State != "working" || !strings.HasPrefix(first.Reason, "[work-app]") || first.Goal != nil {
		t.Fatalf("work app: %+v", first)
	}
	second := judgeAt(b, baseTs+6_000, screen{app: cursor.app, bundle: cursor.bundle, title: cursor.title, text: cursor.text + " return pick"})
	if second.Goal == nil || second.Goal.ID != goals["building Moku"].ID || second.Switch {
		t.Fatalf("the work app's goal: %+v", second)
	}
	if stored, _ := b.Store.Verdict(first.SampleID); stored.ThreadID == nil || *stored.ThreadID != goals["building Moku"].ID {
		t.Fatalf("the first verdict's goal, written back: %+v", stored)
	}
	if calls := jevCalls(b.Store); calls["goal"] != 0 || calls["label"] != 1 || calls["judge"] != 0 {
		t.Fatalf("calls %v", calls)
	}
	// Cached per window: the goal isn't asked again 30 minutes on, even with the text changing; after an hour it is.
	judgeAt(b, baseTs+30*minute, screen{app: cursor.app, bundle: cursor.bundle, title: cursor.title, text: cursor.text + " tests pass"})
	if calls := jevCalls(b.Store); calls["label"] != 1 {
		t.Fatalf("30 min on: %v", calls)
	}
	judgeAt(b, baseTs+62*minute, screen{app: cursor.app, bundle: cursor.bundle, title: cursor.title, text: cursor.text + " shipped"})
	if calls := jevCalls(b.Store); calls["label"] != 2 {
		t.Fatalf("an hour on: %v", calls)
	}
}

// The lock is let go while Jev is asked: a goal merged or forgotten meanwhile (the dashboard, a duplicate check)
// never leaves a verdict pointing at a goal that's gone.
func TestAGoalGoneDuringTheCallIsFollowedOrDropped(t *testing.T) {
	b, models, goals := goalBrain(t)
	problems, moku := goals["practicing coding problems"], goals["building Moku"]
	workedOn(b.Store, problems, baseTs-minute)
	models.during = func() {
		b.Store.MergeThread(problems.ID, moku.ID)
		b.merged[problems.ID] = moku.ID
	}
	v := judgeAt(b, baseTs, leetcode)
	if v.Goal == nil || v.Goal.ID != moku.ID || v.Thread.ID != moku.ID {
		t.Fatalf("merged meanwhile: %+v", v)
	}
	if stored, _ := b.Store.Verdict(v.SampleID); stored.ThreadID == nil || *stored.ThreadID != moku.ID {
		t.Fatalf("stored on the goal it merged into: %+v", stored)
	}
	models.during = func() { b.Store.ForgetThread(moku.ID) }
	v = judgeAt(b, baseTs+10*minute, screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "goals.go at main · charles161/moku",
		url: "https://github.com/charles161/moku/blob/main/brain-go/goals.go", text: "func goalDays spans window segments"})
	if v.State != "working" || v.Goal != nil || v.Thread != nil || v.Switch {
		t.Fatalf("forgotten meanwhile: %+v", v)
	}
}
