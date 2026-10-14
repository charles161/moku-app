package brain

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The calibration dashboard: moments, what's shown, the scores, and the page's HTTP rules.

func calibratingBrain(t *testing.T) (*Brain, map[string]*ThreadRow) {
	t.Helper()
	store, err := OpenStore(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.Close)
	b := NewBrain(BrainOptions{Store: store, Models: &fakeModels{oracle: charlesDay}, Config: func() CompanionConfig { return DefaultConfig },
		Now: func() int64 { return baseTs + 60*minute }, Calibrate: true})
	goals := map[string]*ThreadRow{}
	for _, g := range []string{"building Moku", "practicing coding problems", "Potluck side project"} {
		goals[g] = seedGoal(store, g, "About "+g, baseTs-60*minute)
	}
	return b, goals
}

// run: a screen sampled every 3 s for n samples from at; returns the next free time.
func run(b *Brain, at int64, n int, s screen) int64 {
	for i := 0; i < n; i++ {
		judgeAt(b, at, s)
		at += 3_000
	}
	return at
}

func TestMomentsAreRunsOfOneWindowWithOneAnswer(t *testing.T) {
	b, goals := calibratingBrain(t)
	if !b.goalJudging || b.TextKeepMs() != CalibrationTextKeepMs {
		t.Fatalf("calibrating: goal judging %v, text kept %d ms", b.goalJudging, b.TextKeepMs())
	}
	workedOn(b.Store, goals["practicing coding problems"], baseTs-minute)
	at := run(b, baseTs, 10, leetcode)
	at = run(b, at, 10, potluckChat)
	at = run(b, at, 10, weekendChat)
	at = run(b, at, 2, screen{app: "Finder", bundle: "com.apple.finder", title: "Downloads"}) // neutral: ends a moment
	run(b, at, 10, leetcode)

	moments := b.moments(baseTs, baseTs+60*minute)
	var kinds []string
	for _, m := range moments {
		kinds = append(kinds, m.Kind)
	}
	if strings.Join(kinds, ",") != "goal,switch,drift,switch" {
		t.Fatalf("kinds %v: %+v", kinds, moments)
	}
	first, sw := moments[0], moments[1]
	if first.End-first.Start != 30_000 || *first.GoalTitle != "practicing coding problems" || first.Place != "leetcode.com" || first.P == nil || *first.P != 0.9 {
		t.Errorf("the first moment: %+v", first)
	}
	if *sw.GoalTitle != "Potluck side project" || sw.FromGoal == nil || *sw.FromGoal != "practicing coding problems" || sw.Place != "WhatsApp" {
		t.Errorf("the switch: %+v", sw)
	}
	if last := moments[3]; *last.FromGoal != "Potluck side project" {
		t.Errorf("back to coding problems is a switch from the goal before the drift: %+v", last)
	}
	// Every drift and switch is shown; they're all longer than 20 s.
	for _, m := range moments[1:] {
		if !m.Shown {
			t.Errorf("not shown: %+v", m)
		}
	}
}

func TestANewGoalIsItsOwnKindOfMoment(t *testing.T) {
	b, _ := calibratingBrain(t)
	models := b.Models.(*fakeModels)
	models.oracle = func(string, string, string) screenTruth { return screenTruth{goal: goalNew, p: 0.8} }
	models.names = func(string) (string, string, string) {
		return "learning pottery", "Learning to throw pots", "learning pottery"
	}
	run(b, baseTs, 8, screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Throwing a bowl", url: "https://pottery.example/bowl", text: "clay wheel centering"})
	moments := b.moments(baseTs, baseTs+60*minute)
	if len(moments) != 1 || moments[0].Kind != "new" || *moments[0].GoalTitle != "learning pottery" || !moments[0].Shown {
		t.Fatalf("%+v", moments)
	}
}

func TestAboutAFifthOfOnGoalMomentsAreShown(t *testing.T) {
	b, goals := calibratingBrain(t)
	workedOn(b.Store, goals["building Moku"], baseTs-minute)
	at := baseTs
	for i := 0; i < 200; i++ {
		at = run(b, at, 8, screen{app: "Google Chrome", bundle: "com.google.Chrome", title: fmt.Sprintf("goals.go (%d)", i),
			url: fmt.Sprintf("https://docs%d.example/", i), text: "package brain"})
	}
	shown, onGoal := 0, 0
	for _, m := range b.moments(baseTs, at) {
		if m.Kind == "goal" {
			onGoal++
			if m.Shown {
				shown++
			}
		}
	}
	if onGoal < 150 || shown < onGoal/10 || shown > onGoal*3/10 {
		t.Fatalf("%d of %d on-goal moments shown", shown, onGoal)
	}
}

func said(m Moment) json.RawMessage { data, _ := json.Marshal(m); return data }

func TestScoresFollowTheExitBar(t *testing.T) {
	p := func(x float64) *float64 { return &x }
	goal := func(title string, p *float64) Moment {
		return Moment{State: "working", Kind: "goal", GoalID: ptr("g_" + title), GoalTitle: ptr(title), P: p, Place: "leetcode.com"}
	}
	drift := func(place string, p *float64, nudged bool) Moment {
		return Moment{State: "drifting", Kind: "drift", P: p, Place: place, Nudged: nudged}
	}
	day := int64(baseTs)
	ratings := []GoalRating{
		{Start: day, Said: said(goal("problems", p(0.92))), OK: true},
		{Start: day, Said: said(goal("problems", p(0.85))), OK: true},
		// The wrong goal.
		{Start: day, Said: said(goal("problems", p(0.81))), OK: false, Truth: ptr("goal"), TruthGoalID: ptr("g_email")},
		// A ✗ that names Moku's own goal is a slip of the finger: right.
		{Start: day, Said: said(goal("email", p(0.95))), OK: false, Truth: ptr("goal"), TruthGoalID: ptr("g_email")},
		{Start: day + 24*60*minute, Said: said(drift("streamhub.example", p(0.95), false)), OK: true},
		// Moku nudged during real work.
		{Start: day + 24*60*minute, Said: said(drift("WhatsApp", p(0.7), true)), OK: false, Truth: ptr("goal"), TruthGoalID: ptr("g_split")},
		// Personal but fine, called a drift.
		{Start: day + 24*60*minute, Said: said(drift("insurer.example", p(0.6), false)), OK: false, Truth: ptr("personal")},
		// A drift Moku missed.
		{Start: day + 48*60*minute, Said: said(goal("problems", p(0.55))), OK: false, Truth: ptr("drift")},
	}
	s := scoreRatings(ratings)
	if s.Rated != 8 || s.Days != 3 || s.WorkRated != 5 || *s.GoalRight != 0.6 {
		t.Errorf("goal right: %+v (%v)", s, *s.GoalRight)
	}
	if s.DriftsSaid != 3 || *s.DriftPrecision != 0.333 || s.DriftsTrue != 2 || *s.DriftRecall != 0.5 {
		t.Errorf("drifts: said %d precision %v, true %d recall %v", s.DriftsSaid, *s.DriftPrecision, s.DriftsTrue, *s.DriftRecall)
	}
	if s.NudgesOnWork != 1 || s.Personal != 1 || s.PersonalSaidDrift != 1 {
		t.Errorf("nudges %d, personal %d (%d said drift)", s.NudgesOnWork, s.Personal, s.PersonalSaidDrift)
	}
	bins := calibrationBins(ratings)
	if bins[4].N != 3 || *bins[4].Right != 1 || bins[3].N != 2 || *bins[3].Right != 0.5 || bins[2].N != 1 || bins[1].N != 1 || bins[0].N != 1 || *bins[0].Right != 0 {
		t.Errorf("bins %+v", bins)
	}
	if worst := worstPlaces(ratings, 8); len(worst) != 3 || worst[0].Place != "leetcode.com" || worst[0].Wrong != 2 {
		t.Errorf("worst %+v", worst)
	}
	bar := exitBar(s, Cost{Ratio: p(0.45), NowP90: 900, NowMax: 2_000, BeforeP90: 850})
	passed := map[string]bool{}
	for _, line := range bar {
		passed[line.What] = line.Pass
	}
	if passed["Rated moments"] || passed["Goal right"] || passed["Nudges on real work"] || !passed["Jev cost per active hour"] || !passed["Verdicts as fast as before"] {
		t.Errorf("bar %+v", bar)
	}
}

func request(t *testing.T, h http.Handler, method, path, origin, body string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, "http://127.0.0.1:8020"+path, strings.NewReader(body))
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestTheDashboardIsLocalAndOnlyInTheCalibrationBuild(t *testing.T) {
	// Any other build has no dashboard.
	plain := NewHandler(newTestBrain(t, &fakeModels{}, true), AppOptions{Port: 8020})
	if w := request(t, plain, "GET", "/calibrate", "", ""); w.Code != 404 {
		t.Fatalf("not calibrating: %d", w.Code)
	}

	b, goals := calibratingBrain(t)
	h := NewHandler(b, AppOptions{Port: 8020})
	page := request(t, h, "GET", "/calibrate", "", "")
	csp := page.Header().Get("content-security-policy")
	body := page.Body.String()
	if page.Code != 200 || !strings.Contains(csp, "script-src 'nonce-") || !strings.Contains(csp, "frame-ancestors 'none'") || strings.Contains(body, "{{nonce}}") {
		t.Fatalf("page %d, csp %q", page.Code, csp)
	}
	nonce := strings.TrimSuffix(strings.SplitN(strings.SplitN(csp, "'nonce-", 2)[1], "'", 2)[0], "")
	if !strings.Contains(body, `<script nonce="`+nonce+`">`) || strings.Contains(body, "innerHTML") {
		t.Fatalf("the page's script carries the nonce and never writes HTML")
	}
	if page.Header().Get("x-frame-options") != "DENY" || page.Header().Get("x-content-type-options") != "nosniff" {
		t.Fatalf("headers %v", page.Header())
	}

	workedOn(b.Store, goals["practicing coding problems"], baseTs-minute)
	run(b, baseTs, 10, leetcode)
	run(b, baseTs+30_000, 10, weekendChat)
	date := localDate(baseTs)
	own := "http://127.0.0.1:8020"
	day := request(t, h, "GET", "/calibrate/day?date="+date, "", "")
	var shown CalibrationDay
	json.Unmarshal(day.Body.Bytes(), &shown)
	if day.Code != 200 || len(shown.Moments) != 1 || shown.Moments[0].Kind != "drift" || shown.Shown != 1 {
		t.Fatalf("day %d: %s", day.Code, day.Body.String())
	}
	drift := shown.Moments[0]

	// The page's own requests carry its origin: only those, and only to /calibrate.
	rate := fmt.Sprintf(`{"date":%q,"momentId":%q,"ok":false,"truth":"goal","goalId":%q}`, date, drift.ID, goals["Potluck side project"].ID)
	if w := request(t, h, "POST", "/calibrate/rate", "https://evil.example", rate); w.Code != 403 {
		t.Fatalf("another site: %d", w.Code)
	}
	if w := request(t, h, "POST", "/v1/feedback", own, `{"ts":1,"kind":"pat"}`); w.Code != 403 {
		t.Fatalf("the dashboard's origin elsewhere: %d", w.Code)
	}
	if w := request(t, h, "POST", "/calibrate/rate", own, rate); w.Code != 200 {
		t.Fatalf("rate: %d %s", w.Code, w.Body.String())
	}
	if w := request(t, h, "POST", "/calibrate/rate", own, `{"date":"`+date+`","momentId":"`+drift.ID+`","ok":false,"truth":"maybe"}`); w.Code != 400 {
		t.Fatalf("a bad truth: %d", w.Code)
	}
	if w := request(t, h, "POST", "/calibrate/rate", own, `{"date":"`+date+`","momentId":"nope","ok":true}`); w.Code != 404 {
		t.Fatalf("no such moment: %d", w.Code)
	}
	var report Report
	json.Unmarshal(request(t, h, "GET", "/calibrate/report", "", "").Body.Bytes(), &report)
	if report.Overall.Rated != 1 || report.Overall.DriftsSaid != 1 || *report.Overall.DriftPrecision != 0 || len(report.Bar) != 7 {
		t.Fatalf("report %+v", report.Overall)
	}
	// The rating keeps what Moku said then.
	stored := b.Store.GoalRatings(0, MaxSafeInteger)
	if len(stored) != 1 || !strings.Contains(string(stored[0].Said), `"kind":"drift"`) || *stored[0].TruthGoalID != goals["Potluck side project"].ID {
		t.Fatalf("stored %+v", stored)
	}
	if w := request(t, h, "POST", "/calibrate/unrate", own, `{"momentId":"`+drift.ID+`"}`); w.Code != 200 || len(b.Store.GoalRatings(0, MaxSafeInteger)) != 0 {
		t.Fatalf("unrate: %d", w.Code)
	}

	// The goals list: rename, merge a duplicate, not a real goal.
	edit := func(body string) int { return request(t, h, "POST", "/calibrate/goal", own, body).Code }
	if edit(`{"id":"`+goals["building Moku"].ID+`","title":"building Moku, the app"}`) != 200 || b.Store.Thread(goals["building Moku"].ID).Title != "building Moku, the app" {
		t.Fatalf("rename")
	}
	if edit(`{"id":"`+goals["Potluck side project"].ID+`","mergeInto":"`+goals["building Moku"].ID+`"}`) != 200 || b.Store.Thread(goals["Potluck side project"].ID) != nil {
		t.Fatalf("merge")
	}
	if edit(`{"id":"`+goals["practicing coding problems"].ID+`","notAGoal":true}`) != 200 || b.Store.Thread(goals["practicing coding problems"].ID) != nil {
		t.Fatalf("not a real goal")
	}
	if v, _ := b.Store.Verdict(drift.ID); v == nil || v.State != "drifting" {
		t.Fatalf("verdicts keep their state")
	}
	if edit(`{"id":"nope","title":"x"}`) != 400 {
		t.Fatalf("no such goal")
	}
}
