package brain

import (
	"fmt"
	"slices"
	"strings"
)

// The FOCUS pipeline: is the person working right now? It decides the verdict's state (with its confidence, source
// and reason) and nothing else, by executing the focus rulebook in order: meeting, system-screen, away, learned,
// neutral-app, known-feed, front-page, same-screen, work-app, drift-app, media, jev. Jev answers one question here,
// work or distraction; threads, activities and buckets are never asked or read.

type FocusDecision struct {
	State      string
	Confidence float64
	Source     string
	Reason     string
	// labels: set only by goal-aware judging, whose one call answers the goal with the state (its phrase and bucket
	// come with the goal).
	labels *Labels
}

type focusInput struct {
	sample   ActivitySample
	screen   Screen
	text     *string
	previous *SampleRow
}

const minute = 60_000

func because(rule, text string) string { return "[" + rule + "] " + text }

func decide(rule, state string, confidence float64, source, text string) *FocusDecision {
	return &FocusDecision{State: state, Confidence: confidence, Source: source, Reason: because(rule, text)}
}

type focusPipeline struct {
	b *Brain
	// Jev calls in flight by exact screen: a repeat sample waits for the answer instead of asking twice.
	inFlight map[string]*inFlightJudge
	// anchors: each window's last goal answer (goal-aware judging's rule reuse, reuse.go).
	anchors map[string]goalAnchor
}

type inFlightJudge struct {
	done     chan struct{}
	decision FocusDecision
}

func newFocus(b *Brain) *focusPipeline {
	return &focusPipeline{b: b, inFlight: map[string]*inFlightJudge{}, anchors: map[string]goalAnchor{}}
}

func (f *focusPipeline) decide(in focusInput) FocusDecision {
	if f.b.goalJudging {
		return f.decideByGoal(in)
	}
	for _, rule := range []func() *FocusDecision{
		func() *FocusDecision { return quickCheck(in.sample, in.screen, in.previous, f.b.config()) },
		func() *FocusDecision { return f.learned(in.screen) },
		func() *FocusDecision { return neutralApp(in.screen) },
		func() *FocusDecision { return knownFeed(in.screen) },
		func() *FocusDecision { return frontPageDrift(in.screen) },
		func() *FocusDecision { return f.reused(in.screen, in.sample) },
		func() *FocusDecision { return workApp(in.screen) },
		func() *FocusDecision { return driftingApp(in.screen) },
		// The same window with mostly the same words keeps its answer a few minutes (reuse.go): a page on the fence must not
		// flip between work and drift as its text scrolls, and a video's ticking clock needn't be a new question every 3 s.
		func() *FocusDecision {
			if !focusWindowReuse {
				return nil
			}
			return f.reusedGoal(in.screen, in.sample.Ts(), in.text)
		},
	} {
		if d := rule(); d != nil {
			return *d
		}
	}
	return f.askJevOnce(in.sample, in.screen, in.text)
}

// focusWindowReuse: the focus pipeline's window reuse (above). Only the replayed-hour test turns it off, to measure the cost
// the pipeline had before it: the baseline goal-aware judging's "at most 60% of today's" gate was written against.
var focusWindowReuse = true

// decideByGoal: goal-aware judging's order (goaljudge.go): the rules as without goals, then reuse, then one goal call.
func (f *focusPipeline) decideByGoal(in focusInput) FocusDecision {
	for _, rule := range []func() *FocusDecision{
		func() *FocusDecision { return quickCheck(in.sample, in.screen, in.previous, f.b.config()) },
		func() *FocusDecision { return f.learned(in.screen) },
		func() *FocusDecision { return neutralApp(in.screen) },
		func() *FocusDecision { return knownFeed(in.screen) },
		func() *FocusDecision { return frontPageDrift(in.screen) },
		func() *FocusDecision { return workApp(in.screen) },
		func() *FocusDecision { return driftingApp(in.screen) },
		func() *FocusDecision { return f.reusedGoal(in.screen, in.sample.Ts(), in.text) },
	} {
		if d := rule(); d != nil {
			return *d
		}
	}
	return f.askJevOnce(in.sample, in.screen, in.text)
}

// learned: what the person taught about this context decides, with no model call.
func (f *focusPipeline) learned(s Screen) *FocusDecision {
	rule := findLearnedRule(f.b.Store, s)
	if rule == nil {
		return nil
	}
	state, effect := "drifting", "not work"
	if rule.Effect == "work" {
		state, effect = "working", "work"
	}
	return decide(ruleLearned, state, 1, "override",
		fmt.Sprintf("rule %d: %s on %s (%s %s)", rule.ID, effect, rule.describe(), rule.Source, localClock(rule.CreatedAt)))
}

// reused: the exact screen Jev judged in the last 10 minutes gets the same state.
func (f *focusPipeline) reused(s Screen, sample ActivitySample) *FocusDecision {
	ts := sample.Ts()
	prior := f.b.Store.RecentJevVerdict(s, ts-int64(Rules.SameScreenWindowMinutes)*minute, ts, sample.ID)
	if prior == nil {
		return nil
	}
	ago := int64(Round(float64(ts-prior.TS) / 1000))
	return &FocusDecision{State: prior.State, Confidence: prior.Confidence, Source: "shortcut",
		Reason: because(ruleSameScreen, fmt.Sprintf("as %ds ago: %s", ago, prior.Reason))}
}

func (f *focusPipeline) askJevOnce(sample ActivitySample, s Screen, text *string) FocusDecision {
	// Nothing but the app's name (neither Accessibility nor Screen Recording, or a screen Moku never reads): a model can only
	// guess, and a guess became ten minutes of drift for a browser. Missing data never counts as drift (rule no-info).
	if s.Title == "" && s.URL == nil && (text == nil || strings.TrimSpace(*text) == "") {
		return *decide(ruleNoInfo, "unknown", 0, "fallback", s.AppName+": no window title, address or words to judge")
	}
	key := screenKey(s)
	if running, ok := f.inFlight[key]; ok {
		f.b.unlocked(func() { <-running.done })
		shared := running.decision
		if shared.Source == "jev" || shared.Source == "local" {
			out := FocusDecision{State: shared.State, Confidence: shared.Confidence, Source: "shortcut", Reason: because(ruleSameScreen, "judged just now: "+shared.Reason)}
			if shared.labels != nil {
				labels := *shared.labels
				labels.IsNewThread = false
				out.labels = &labels
			}
			return out
		}
		return shared
	}
	call := &inFlightJudge{done: make(chan struct{})}
	f.inFlight[key] = call
	defer func() {
		delete(f.inFlight, key)
		close(call.done)
	}()
	if f.b.goalJudging {
		call.decision = f.askGoal(sample, s, text)
	} else {
		call.decision = f.askJev(sample, s, text)
		if d := call.decision; d.Source == "jev" || d.Source == "local" {
			f.anchor(s, sample.Ts(), text, d)
		}
	}
	return call.decision
}

// askJev: rules media and jev: one Jev call, one question, work or distraction.
func (f *focusPipeline) askJev(sample ActivitySample, s Screen, text *string) FocusDecision {
	var excerpt *string
	if text != nil {
		excerpt = ptr(Slice16(*text, TextExcerpt))
	}
	state := focusState(ScreenInput{App: s.AppName, WindowTitle: s.Title, Site: hostAndPath(s.URL), ScreenContents: excerpt})
	questions := QuestionSet{{"kind", kindQuestion}}
	outcome := f.b.judgeModel(state, questions, true)
	var output any
	if outcome.OK {
		output = judgeOutput(outcome, true)
	}
	f.b.Store.InsertModelCall(ModelCallRecord{
		Purpose: "judge", SampleID: &sample.ID, Model: outcome.Model, OK: outcome.OK, ErrorCode: errorCodePtr(outcome.OK, outcome.ErrorCode),
		LatencyMs: outcome.LatencyMs, Attempts: outcome.Attempts, TokensIn: outcome.TokensIn, TokensOut: outcome.TokensOut,
		CostUsd: outcome.CostUsd, Input: OMap{{"state", state}, {"questions", questions}}, Output: output,
	})
	if !outcome.OK {
		return jevFailed(outcome)
	}
	kind, _ := outcome.Answers.Get("kind")
	workP, given := kind.Probabilities["work"]
	if !given {
		workP = 0
		if kind.Choice == "work" {
			workP = 1
		}
	}
	source, prefix := "jev", ""
	if outcome.Model == LocalModelInfo.ID {
		source, prefix = "local", "local model, "
	}
	why := prefix + "work p=" + ToFixed(workP, 2)
	if isMediaSite(s) {
		if workP >= Rules.Media.MinWorkP {
			return *decide(ruleMedia, "working", workP, source, why)
		}
		return *decide(ruleMedia, "drifting", 1-workP, source, why)
	}
	if kind.Choice == "work" {
		return *decide(ruleJev, "working", workP, source, why)
	}
	return *decide(ruleJev, "drifting", 1-workP, source, why)
}

// jevFailed: rule jev-failed: unknown, so Moku keeps its state; never a guess.
func jevFailed(outcome JudgeOutcome) FocusDecision {
	status := ""
	if outcome.HTTPStatus != 0 {
		status = fmt.Sprintf(" %d", outcome.HTTPStatus)
	}
	why := fmt.Sprintf("%s%s after %d attempt(s)", outcome.ErrorCode, status, outcome.Attempts)
	if outcome.ErrorCode == "unavailable" {
		why = "Jev keeps failing; skipped until a retry succeeds"
	}
	return *decide(ruleJevFailed, "unknown", 0, "fallback", why)
}

// judgeOutput: what a Jev call returned, as stored: {answers, confidence} (confidence only when given).
func judgeOutput(o JudgeOutcome, withConfidence bool) OMap {
	out := OMap{{"answers", o.Answers}}
	if withConfidence && o.Confidence != nil {
		out = append(out, KV{"confidence", o.Confidence})
	}
	return out
}

func errorCodePtr(ok bool, code string) *string {
	if ok {
		return nil
	}
	return &code
}

// quickCheck: rules meeting, system-screen and away, decided in code before anything else.
func quickCheck(sample ActivitySample, s Screen, previous *SampleRow, config CompanionConfig) *FocusDecision {
	c := sample.Context
	if c.InCall || c.SharingScreen {
		why := "in a call"
		if c.SharingScreen {
			why = "sharing the screen"
		}
		return decide(ruleMeeting, "meeting", 1, "shortcut", why)
	}
	if slices.Contains(Rules.SystemScreenBundleIDs, sample.App.BundleID) {
		return decide(ruleSystemScreen, "unknown", 1, "shortcut", sample.App.Name+": neither work nor drift")
	}
	if sample.App.BundleID == Rules.Away.LockedScreen {
		return decide(ruleAway, "away", 1, "shortcut", "the screen is locked")
	}
	// Idle is away, whatever the screen does by itself, except watchable media that is changing.
	idle := sample.Activity.IdleSeconds
	if idle >= config.AwayAfterIdleSec {
		changing := previous != nil && !sameScreen(s, previous.Screen)
		if !changing {
			return decide(ruleAway, "away", 1, "shortcut", fmt.Sprintf("idle %ds on an unchanged screen", int64(Round(idle))))
		}
		if !isWatchable(s) {
			return decide(ruleAway, "away", 1, "shortcut", fmt.Sprintf("idle %ds; the screen changes by itself", int64(Round(idle))))
		}
	}
	return nil
}

// knownFeed: feed and home pages of content sites, and streaming sites, drift with no model call.
func knownFeed(s Screen) *FocusDecision {
	kind, page, ok := knownFeedPage(s.URL)
	if !ok {
		return nil
	}
	what := "feed"
	if kind == "streaming" {
		what = "streaming site"
	}
	return decide(ruleKnownFeed, "drifting", 1, "shortcut", fmt.Sprintf("%s is a %s", page, what))
}

// neutralApp: utilities are neither work nor drift, so the state before stands.
func neutralApp(s Screen) *FocusDecision {
	if slices.Contains(Rules.NeutralAppBundleIDs, s.BundleID) {
		return decide(ruleNeutralApp, "unknown", 1, "shortcut", s.AppName+": neither work nor drift")
	}
	return nil
}

// frontPageDrift: a news front page or a shop's home page drifts, with no model call.
func frontPageDrift(s Screen) *FocusDecision {
	kind, page, ok := frontPage(s.URL)
	if !ok {
		return nil
	}
	what := "a news front page"
	if kind != "news" {
		what = "a shop's home page"
	}
	return decide(ruleFrontPage, "drifting", 1, "shortcut", page+" is "+what)
}

// driftingApp: games, and video or music apps in front, drift, with no model call.
func driftingApp(s Screen) *FocusDecision {
	kind := driftApp(s.BundleID)
	if kind == "" {
		return nil
	}
	what := "a " + kind + " app"
	if kind == "game" {
		what = "a game"
	}
	return decide(ruleDriftApp, "drifting", 1, "shortcut", s.AppName+" is "+what)
}

// workApp: tools people work in are work, whatever they show, with no model call.
func workApp(s Screen) *FocusDecision {
	tool := ""
	if slices.Contains(Rules.WorkApp.BundleIDs, s.BundleID) {
		tool = s.AppName
	} else {
		site := siteOf(s.URL)
		for _, candidate := range Rules.WorkApp.Sites {
			if onSite(site, candidate) {
				tool = candidate
				break
			}
		}
	}
	if tool == "" {
		return nil
	}
	return decide(ruleWorkApp, "working", 1, "shortcut", tool+" is a work tool")
}
