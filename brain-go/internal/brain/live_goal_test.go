package brain

import (
	"os"
	"strings"
	"testing"
)

// Live goal-aware judging against the real Jev, on real-looking screens: run by hand, a dozen calls at most. First run
// (2026-10-04): 5 of 7 right, 0.4–1.1 s a call, $0.00003 a call. The two misses were "work, no goal sure enough": Jev
// split its probability between related goals (on Stripe docs: new 0.40, two goals 0.29 and 0.11), under the 0.5
// bar.
//
//	MOKU_LIVE=1 MOKU_DEV_ENV=…/bunny/.env go test ./internal/brain -run LiveGoal -v
func TestLiveGoalJudging(t *testing.T) {
	if os.Getenv("MOKU_LIVE") != "1" {
		t.Skip("live: MOKU_LIVE=1")
	}
	t.Setenv("MOKU_HOME", t.TempDir())
	LoadEnv(DevEnvPath())
	if ModelAccess() != "key" {
		t.Fatalf("no development key")
	}
	store, err := OpenStore(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	b := NewBrain(BrainOptions{Store: store, Models: NewModels(ModelOptions{Transport: NewGateway()}), Config: func() CompanionConfig { return DefaultConfig },
		Now: func() int64 { return baseTs }, GoalJudging: true})
	goals := map[string]*ThreadRow{}
	for _, g := range [][2]string{
		{"practicing coding problems", "Practicing coding problems and frontend UI exercises"},
		{"building Moku", "Building Moku, a desktop companion app for the Mac"},
		{"Potluck side project", "Building a bill-splitting app with two friends"},
		{"writing the onboarding doc", "Writing the onboarding doc for new engineers"},
		{"adding Stripe payments", "Adding Stripe payments and webhooks to Moku"},
	} {
		goals[g[0]] = seedGoal(store, g[0], g[1], baseTs-60*minute)
	}
	workedOn(store, goals["practicing coding problems"], baseTs-minute)
	cases := []struct {
		s           screen
		state, goal string
	}{
		{screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Two Sum - LeetCode", url: "https://leetcode.com/problems/two-sum/",
			text: "1. Two Sum Easy Topics Companies Hint Given an array of integers nums and an integer target, return indices of the two numbers such that they add up to target. You may assume that each input would have exactly one solution. Example 1: Input: nums = [2,7,11,15], target = 9 Output: [0,1] Code JavaScript var twoSum = function(nums, target) { const seen = new Map(); for (let i = 0; i < nums.length; i++) {"},
			"working", "practicing coding problems"},
		{screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Build a Modal Component in React - YouTube", url: "https://www.youtube.com/watch?v=xyz",
			text: "Build a Modal Component in React 84K views Frontend practice: we build an accessible modal with focus trapping, portals and escape to close. Chapters 0:00 Intro 2:10 Requirements 5:45 Portal 9:30 Focus trap"},
			"working", "practicing coding problems"},
		{screen{app: "WhatsApp", bundle: "net.whatsapp.WhatsApp", title: "WhatsApp",
			text: "Potluck app Ravi: pushed the settle-up screen to main. Charles: nice, I'll review the expense split logic tonight. Ravi: the rounding bug is fixed, tests are green now. Meera: can we demo it to the group on Sunday?"},
			"working", "Potluck side project"},
		{screen{app: "WhatsApp", bundle: "net.whatsapp.WhatsApp", title: "WhatsApp",
			text: "Weekend crew Arun: goa or pondy this weekend? Meera: pondy!! beaches and cafes Arun: booking the bus tonight then Charles: count me in, which cafe first? Meera: the french one near the promenade"},
			"drifting", ""},
		{screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Dark S2 E5 - StreamHub", url: "https://streamhub.example/watch/dark-s2e5",
			text: "Home Movies TV Shows Dark Season 2 Episode 5 Lost and Found 52m Audio playing Jonas: What we know is a drop. What we don't know is an ocean. Next episode Subtitles English"},
			"drifting", ""},
		{screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Webhooks | Stripe Documentation", url: "https://docs.stripe.com/webhooks",
			text: "Receive Stripe events in your webhook endpoint. Listen to events in your Stripe account on your webhook endpoint so your integration can automatically trigger reactions. Verify webhook signatures with the Stripe-Signature header. payment_intent.succeeded checkout.session.completed"},
			"working", "adding Stripe payments"},
		{screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Onboarding for new engineers - Acme wiki", url: "https://wiki.acme.example/onboarding",
			text: "Onboarding for new engineers. Week one: get your laptop, set up the repo, run the tests, ship a small fix. Who to ask: the platform team. Questions go at the end."},
			"working", "writing the onboarding doc"},
	}
	at, right, asked := baseTs, 0, 0
	for _, c := range cases {
		if only := os.Getenv("MOKU_LIVE_ONLY"); only != "" && !strings.Contains(c.s.title, only) {
			continue
		}
		asked++
		v := judgeAt(b, at, c.s)
		at += 30_000
		title := ""
		if v.Goal != nil {
			title = v.Goal.Title
		}
		mark := "✓"
		if v.State != c.state || (c.goal != "" && title != c.goal) {
			mark = "✗ (want " + c.state + " " + c.goal + ")"
		} else {
			right++
		}
		t.Logf("%s %-50s → %s %q switch=%v (%s) %d ms", mark, Clip(c.s.title, 50), v.State, title, v.Switch, v.Reason, v.LatencyMs)
	}
	// A measurement, not a gate: the thresholds are tuned on Charles's ratings (the replay tool), not on these.
	t.Logf("right: %d of %d", right, asked)
	var cost float64
	calls := 0
	for _, c := range store.ModelCalls("") {
		if c.ErrorCode != nil && *c.ErrorCode == "unavailable" {
			continue
		}
		calls++
		if c.CostUsd != nil {
			cost += *c.CostUsd
		}
		if !c.OK {
			t.Logf("failed %s call: %v", c.Purpose, deref(c.ErrorCode))
		}
	}
	t.Logf("%d model calls, $%.6f in all", calls, cost)
	if strings.Contains(os.Getenv("MOKU_LIVE_SHOW"), "goal") {
		for _, c := range store.ModelCalls("goal") {
			t.Logf("%s", c.Output)
		}
	}
}
