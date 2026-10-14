package brain

import "fmt"

// Goal-aware judging (docs/specs/goal-aware-judging.md). The question becomes "does this screen serve one of your
// goals right now?", and one Jev call answers the state and the goal together (with the bucket), replacing the
// separate judge and label calls. Three answers:
//
//	the current goal             working: quiet, the house grows
//	another goal, or a new one   working, a switch: calm, never a nudge
//	no goal                      drifting: the drift ladder, whose line names the goal you left (the app does that)
//
// A goal is a thread (threads.go): found without being told, named by Luna in the person's words. The order of
// decisions: the rules first, as without goals (meeting, away, learned, neutral apps, known feeds, front pages, work
// apps, drift apps); then reuse (reuse.go); then the goal call. Media sites keep their stricter bar. Work the rules
// decide only needs its goal, which the labeler asks once per window and caches (labeler.go).
//
// It runs when the brain starts with MOKU_GOAL_JUDGING=1, or with MOKU_CALIBRATE=1 in Charles's calibration build.
// Otherwise the brain judges as before and verdicts carry no goal.

const (
	goalNew       = "new"
	goalNone      = "none"
	goalDifferent = "different"
)

// calibrationBuild is "1" only in a brain linked for Charles's calibration build: scripts/build-app.sh with
// MOKU_CALIBRATE=1 (which refuses MOKU_RELEASE=1) passes -ldflags "-X moku/brain/internal/brain.calibrationBuild=1".
// Every other brain, every release among them, ignores MOKU_CALIBRATE: no /calibrate dashboard (which answers without
// the brain token) and no 14 days of screen text, whatever its environment says (security review 2026-10-05).
var calibrationBuild = ""

// GoalModes reads the switches: MOKU_CALIBRATE=1 is Charles's calibration (goal-aware judging with it), in a
// calibration build only; MOKU_GOAL_JUDGING=1 is goal-aware judging alone.
func GoalModes(getenv func(string) string) (goalJudging, calibrate bool) {
	calibrate = calibrationBuild == "1" && getenv("MOKU_CALIBRATE") == "1"
	return calibrate || getenv("MOKU_GOAL_JUDGING") == "1", calibrate
}

// goalQuestion: which goal the screen serves. The offered goals' ids, "new" and "none" are the choices.
func goalQuestion(goals []ThreadRow) EvaluationQuestion {
	var criteria OMap
	for _, t := range goals {
		criteria = criteria.Set(t.ID, t.Title+": "+t.Summary)
	}
	criteria = criteria.Set(goalNew, Questions.GoalNew)
	criteria = criteria.Set(goalNone, Questions.GoalNone)
	return EvaluationQuestion{Type: "choice", Instructions: Questions.GoalInstructions, Criteria: criteria}
}

// sameGoalQuestion: whether a goal just named repeats one of these.
func sameGoalQuestion(goals []ThreadRow) EvaluationQuestion {
	var criteria OMap
	for _, t := range goals {
		criteria = criteria.Set(t.ID, t.Title+": "+t.Summary)
	}
	criteria = criteria.Set(goalDifferent, Questions.SameGoalDifferent)
	return EvaluationQuestion{Type: "choice", Instructions: Questions.SameGoalInstructions, Criteria: criteria}
}

// goalState: the screen as focus sees it, plus the title of the goal the person was just on.
func goalState(in ScreenInput, current *ThreadRow) OMap {
	state := focusState(in)
	if current != nil {
		state = append(state, KV{"current_goal", current.Title})
	}
	return state
}

// currentGoal: the goal of the last work in the last Rules.Goal.CurrentWithinMinutes, if any.
func (b *Brain) currentGoal(ts int64, sampleID string) *ThreadRow {
	id, _, ok := b.Store.LastWorkThread(ts, ts-int64(Rules.Goal.CurrentWithinMinutes)*minute, sampleID)
	if !ok {
		return nil
	}
	return b.resolveGoal(id)
}

// offeredGoals: the current goal first, then the most recently active goals, Rules.Goal.Offered in all.
func (b *Brain) offeredGoals(current *ThreadRow, ts int64) []ThreadRow {
	var goals []ThreadRow
	if current != nil {
		goals = append(goals, *current)
	}
	for _, t := range b.Store.Threads(ts-int64(Rules.Goal.ActiveWithinDays)*24*60*minute, Rules.Goal.Offered+12) {
		if len(goals) == Rules.Goal.Offered {
			break
		}
		if (current == nil || t.ID != current.ID) && t.CreatedAt <= ts { // only goals that existed then (replays)
			goals = append(goals, t)
		}
	}
	return goals
}

// resolveGoal: the goal by id, following a merge (a duplicate folded into another since the id was handed out).
func (b *Brain) resolveGoal(id string) *ThreadRow {
	for range 8 {
		if goal := b.Store.Thread(id); goal != nil {
			return goal
		}
		into, ok := b.merged[id]
		if !ok {
			return nil
		}
		id = into
	}
	return nil
}

// goalPick: what one goal answer decides.
type goalPick struct {
	state      string // working or drifting
	goal       *ThreadRow
	isNew      bool
	confidence float64 // the probability of what was decided
	rule, why  string
}

// decideGoal: Jev's distribution over the offered goals, "new" and "none", turned into a state and a goal.
//   - Working when P(not none) ≥ Rules.Goal.MinWorkP; else drifting.
//   - On the most likely offered goal when its p ≥ Rules.Goal.MinGoalP (ties go to the current goal, offered first).
//   - Else a new goal when P(new) ≥ Rules.Goal.MinNewP.
//   - Else work with no goal sure enough: still working time, no guess, no duplicate goal.
//
// Media sites keep their stricter bar: working at P(work) ≥ Rules.Media.MinWorkP, a goal at p ≥ Rules.MediaThreadMinP,
// and never a new goal.
func decideGoal(answer EvaluationAnswer, goals []ThreadRow, media bool) goalPick {
	p := func(choice string) float64 {
		if answer.Probabilities != nil {
			return answer.Probabilities[choice]
		}
		if answer.Choice == choice {
			return 1
		}
		return 0
	}
	rule, minWork, minGoal, where := ruleGoal, Rules.Goal.MinWorkP, Rules.Goal.MinGoalP, ""
	if media {
		rule, minWork, minGoal, where = ruleMedia, Rules.Media.MinWorkP, Rules.MediaThreadMinP, " on a media site"
	}
	workP := 1 - p(goalNone)
	if workP < minWork {
		return goalPick{state: "drifting", confidence: 1 - workP, rule: rule, why: "none p=" + ToFixed(1-workP, 2) + where}
	}
	var best *ThreadRow
	bestP := -1.0
	for i := range goals {
		if q := p(goals[i].ID); q > bestP {
			best, bestP = &goals[i], q
		}
	}
	if best != nil && bestP >= minGoal {
		return goalPick{state: "working", goal: best, confidence: bestP, rule: rule, why: fmt.Sprintf("p=%s \"%s\"", ToFixed(bestP, 2), best.Title) + where}
	}
	if newP := p(goalNew); !media && newP >= Rules.Goal.MinNewP {
		return goalPick{state: "working", isNew: true, confidence: newP, rule: rule, why: "new p=" + ToFixed(newP, 2)}
	}
	return goalPick{state: "working", confidence: workP, rule: rule, why: "work p=" + ToFixed(workP, 2) + ", no goal sure enough" + where}
}

// askGoal: rules goal and media: one Jev call for the state and the goal. Buckets stay as without goals, so the call
// stays small: a drift's comes from the labeler (well-known places at once, others asked once per context and cached),
// and work takes its goal's (a new goal's is asked once, with its duplicate check: checkNewGoal).
func (f *focusPipeline) askGoal(sample ActivitySample, s Screen, text *string) FocusDecision {
	b, store, ts := f.b, f.b.Store, sample.Ts()
	current := b.currentGoal(ts, sample.ID)
	goals := b.offeredGoals(current, ts)
	var excerpt *string
	if text != nil {
		excerpt = ptr(Slice16(*text, TextExcerpt))
	}
	state := goalState(ScreenInput{App: s.AppName, WindowTitle: s.Title, Site: hostAndPath(s.URL), ScreenContents: excerpt}, current)
	questions := QuestionSet{{"goal", goalQuestion(goals)}}
	outcome := b.judgeModel(state, questions, false)
	var output any
	if outcome.OK {
		output = judgeOutput(outcome, true)
	}
	store.InsertModelCall(ModelCallRecord{
		Purpose: "goal", SampleID: &sample.ID, Model: outcome.Model, OK: outcome.OK, ErrorCode: errorCodePtr(outcome.OK, outcome.ErrorCode),
		LatencyMs: outcome.LatencyMs, Attempts: outcome.Attempts, TokensIn: outcome.TokensIn, TokensOut: outcome.TokensOut,
		CostUsd: outcome.CostUsd, Input: OMap{{"state", state}, {"questions", questions}}, Output: output,
	})
	if !outcome.OK {
		return jevFailed(outcome)
	}
	answer, _ := outcome.Answers.Get("goal")
	pick := decideGoal(answer, goals, isMediaSite(s))
	source := "jev"
	if outcome.Model == LocalModelInfo.ID {
		source = "local"
	}
	decision := FocusDecision{State: pick.state, Confidence: pick.confidence, Source: source, Reason: because(pick.rule, pick.why)}
	if pick.state == "working" {
		goal := pick.goal
		category := ptr("working")
		if pick.isNew {
			var naming *Task
			goal, naming = b.startThread(s, text, ts, &sample.ID)
			category = nil // its bucket comes with its name (checkNewGoal), and fills in then
			id := goal.ID
			b.background(func() {
				b.await(naming)
				if named := b.resolveGoal(id); named != nil {
					store.FillThreadLabels(named.ID)
				}
			})
		} else if goal != nil && isFocusBucket(goal.Category) {
			category = goal.Category
		}
		decision.labels = &Labels{Thread: ref(goal), Activity: b.activity.phrase(goal, s, text), Category: category, IsNewThread: pick.isNew}
	}
	f.anchor(s, ts, text, decision)
	return decision
}

// checkNewGoal: a goal Luna just named is checked against the existing ones, so "drafting the Acme handbook" doesn't
// become a second "writing the onboarding doc". One Jev call (goal names and summaries only, no screen) asks whether it repeats one
// of them, and its bucket. At p ≥ Rules.Goal.SameGoalMinP it folds into the old goal, which keeps its name.
func (b *Brain) checkNewGoal(id string) {
	goal := b.Store.Thread(id)
	if goal == nil || goal.Provisional {
		return
	}
	var others []ThreadRow
	for _, t := range b.Store.Threads(goal.CreatedAt-int64(Rules.Goal.ActiveWithinDays)*24*60*minute, 21) {
		if t.ID != id && !t.Provisional && len(others) < 20 {
			others = append(others, t)
		}
	}
	questions := QuestionSet{}
	if len(others) > 0 {
		questions = append(questions, KV{"same", sameGoalQuestion(others)})
	}
	if goal.Category == nil {
		questions = append(questions, KV{"category", threadCategoryQuestion()})
	}
	if len(questions) == 0 {
		return
	}
	state := OMap{{"thread", OMap{{"name", goal.Title}, {"summary", goal.Summary}}}}
	outcome := b.judgeModel(state, questions, false)
	var output any
	if outcome.OK {
		output = judgeOutput(outcome, false)
	}
	b.Store.InsertModelCall(ModelCallRecord{
		Purpose: "dedupe", ThreadID: &id, Model: outcome.Model, OK: outcome.OK, ErrorCode: errorCodePtr(outcome.OK, outcome.ErrorCode),
		LatencyMs: outcome.LatencyMs, Attempts: outcome.Attempts, TokensIn: outcome.TokensIn, TokensOut: outcome.TokensOut,
		CostUsd: outcome.CostUsd, Input: OMap{{"state", state}, {"questions", questions}}, Output: output,
	})
	if !outcome.OK {
		return
	}
	if same, asked := outcome.Answers.Get("same"); asked && same.Choice != goalDifferent {
		p, given := same.Probabilities[same.Choice]
		if !given {
			p = 1
		}
		if into := b.Store.Thread(same.Choice); into != nil && p >= Rules.Goal.SameGoalMinP && b.Store.MergeThread(id, into.ID) {
			b.merged[id] = into.ID
			logf("moku: goal %q is %q (p=%s): merged", goal.Title, into.Title, ToFixed(p, 2))
			return
		}
	}
	if bucket, asked := outcome.Answers.Get("category"); asked && isFocusBucket(&bucket.Choice) {
		b.Store.SetThreadCategory(id, bucket.Choice)
	}
}

// markGoal: in goal-aware judging, work on a goal names it, and work on another goal than the current one is a switch.
func (b *Brain) markGoal(v *Verdict, ts int64) {
	if !b.goalJudging || v.Thread == nil {
		return
	}
	// The goal may have been merged or forgotten while Jev was being asked (the lock is let go during a call): follow
	// a merge, and drop a forgotten one, so no verdict points at a goal that's gone.
	goal := b.resolveGoal(v.Thread.ID)
	if goal == nil {
		v.Thread, v.IsNewThread = nil, false
		return
	}
	if goal.ID != v.Thread.ID {
		v.Thread, v.IsNewThread = ref(goal), false
	}
	if v.State != "working" {
		return
	}
	v.Goal = v.Thread
	current := b.currentGoal(ts, v.SampleID)
	v.Switch = current != nil && current.ID != v.Thread.ID
}

// isMediaSite: rule media's sites (video and social).
func isMediaSite(s Screen) bool {
	host := siteOf(s.URL)
	for _, site := range Rules.Media.Sites {
		if onSite(host, site) {
			return true
		}
	}
	return false
}
