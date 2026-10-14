package brain

import (
	"encoding/json"
	"fmt"
	"strings"
)

// The replay tool's core (cmd/moku-replay; docs/specs/goal-aware-judging.md, "Tuning loop"): Charles's rated moments
// are the test set. Each moment's first screen is judged again, afresh, by the current rules and prompts (and any
// judge model), in the situation it was in then (the goals and the current goal as they were), and the new answer is
// scored against his rating. Only a version that scores better reaches his Mac.
//
// It runs on a copy of his database, never the live file. Writing (Luna) is skipped: a new goal stays unnamed, which
// doesn't change its score, and the replay costs only Jev's calls.

type ReplayChange struct {
	MomentID string `json:"momentId"`
	Start    int64  `json:"start"`
	Place    string `json:"place"`
	Title    string `json:"title"`
	Was      string `json:"was"` // "drift", "switch: practicing coding problems", …
	Now      string `json:"now"`
	Truth    string `json:"truth"`
	RightNow bool   `json:"rightNow"`
}

type ReplayReport struct {
	Moments    int            `json:"moments"`
	NoText     int            `json:"noText"` // moments whose screen text was no longer kept
	Before     Scores         `json:"before"`
	After      Scores         `json:"after"`
	BeforeBins []Bin          `json:"beforeBins"`
	AfterBins  []Bin          `json:"afterBins"`
	Changed    []ReplayChange `json:"changed"`
	Calls      int            `json:"calls"`
	CostUsd    float64        `json:"costUsd"`
	P50Ms      int64          `json:"p50Ms"`
	P90Ms      int64          `json:"p90Ms"`
}

// noWriting: the replay's models: Jev as given, Luna skipped.
type noWriting struct{ Models }

func (noWriting) Write(WriteRequest) WriteOutcome { return WriteOutcome{ErrorCode: "skipped"} }

// truthOf: what a rated moment really was, as (state, goal id, kind): from his ✗, or Moku's own answer when he ✓'d it.
func truthOf(r GoalRating, said Moment) (state string, goalID *string, kind string) {
	if ratedRight(r, said) {
		if said.State == "drifting" {
			return "drifting", nil, "drift"
		}
		return "working", said.GoalID, said.Kind
	}
	switch deref(r.Truth) {
	case "drift":
		return "drifting", nil, "drift"
	case "goal":
		return "working", r.TruthGoalID, "goal"
	case "new":
		return "working", nil, "new"
	}
	return "working", nil, "personal"
}

// rightAgainst: whether a new answer matches what the moment really was.
func rightAgainst(now Moment, state string, goalID *string, kind string) bool {
	switch kind {
	case "drift":
		return now.State == "drifting"
	case "personal", "unclear":
		return now.State == "working" // calm; no particular goal is expected
	case "new":
		return now.State == "working" && (now.Kind == "new" || (goalID != nil && eqStr(now.GoalID, goalID)))
	}
	return now.State == "working" && goalID != nil && eqStr(now.GoalID, goalID)
}

func describeAnswer(m Moment) string {
	switch {
	case m.State == "drifting":
		return "drift"
	case m.Kind == "new":
		return "new goal"
	case m.GoalTitle != nil:
		return m.Kind + ": " + *m.GoalTitle
	}
	return "work, no goal"
}

// ReplayRatings judges every rated moment's first screen again with goal-aware judging and scores the answers.
// store must be a copy: the replay writes verdicts, goals and model calls into it.
func ReplayRatings(store *Store, models Models, limit int) ReplayReport {
	ratings := store.GoalRatings(0, MaxSafeInteger)
	if limit > 0 && len(ratings) > limit {
		ratings = ratings[len(ratings)-limit:]
	}
	report := ReplayReport{Changed: []ReplayChange{}}
	var replayed []GoalRating
	var latencies []int64
	callsBefore := len(store.ModelCalls(""))
	store.exec(`DELETE FROM context_labels`) // work the rules decide asks its goal again too
	for _, r := range ratings {
		var said Moment
		sample := store.Sample(r.MomentID)
		if json.Unmarshal(r.Said, &said) != nil || sample == nil {
			continue
		}
		report.Moments++
		// A fresh brain for each moment: no reuse, no call shared with another moment.
		b := NewBrain(BrainOptions{Store: store, Models: noWriting{models}, Config: func() CompanionConfig { return DefaultConfig },
			Now: func() int64 { return sample.TS }, GoalJudging: true})
		text := sample.Text
		if text == nil {
			if last, _, ok := store.LastText(sample.Screen, sample.TS, sample.ID); ok {
				text = &last
			}
		}
		if text == nil && sample.TextHash != nil {
			report.NoText++
		}
		in := ActivitySample{ID: sample.ID, TS: float64(sample.TS), App: AppInfo{BundleID: sample.BundleID, Name: sample.AppName},
			Window: &WindowInfo{Title: sample.Title, URL: sample.URL}, Text: text, TextHash: sample.TextHash}
		b.Lock()
		v := b.Judge(in)
		b.Unlock()
		b.Settle()
		if v.Source == "jev" || v.Source == "local" {
			latencies = append(latencies, v.LatencyMs)
		}
		now := Moment{ID: said.ID, Start: said.Start, End: said.End, App: said.App, Place: said.Place, Title: said.Title, State: v.State,
			Rule: strings.TrimSuffix(strings.TrimPrefix(ruleOfReason.FindString(v.Reason), "["), "]")}
		switch {
		case v.State == "drifting":
			now.Kind = "drift"
		case v.Goal == nil:
			now.Kind = "unclear"
		case v.IsNewThread:
			now.Kind, now.GoalID = "new", &v.Goal.ID
		case v.Switch:
			now.Kind, now.GoalID, now.GoalTitle = "switch", &v.Goal.ID, &v.Goal.Title
		default:
			now.Kind, now.GoalID, now.GoalTitle = "goal", &v.Goal.ID, &v.Goal.Title
		}
		if v.Source == "jev" || v.Source == "local" {
			now.P = ptr(Round(v.Confidence*100) / 100)
		}
		state, goalID, kind := truthOf(r, said)
		right := rightAgainst(now, state, goalID, kind)
		saidNow, _ := json.Marshal(now)
		// What it really was, in a rating's terms, so a ✓ moment that comes out wrong still counts as work or a drift.
		truth, truthGoal := r.Truth, r.TruthGoalID
		if ratedRight(r, said) {
			switch {
			case kind == "drift":
				truth, truthGoal = ptr("drift"), nil
			case goalID != nil && (kind == "goal" || kind == "switch"):
				truth, truthGoal = ptr("goal"), goalID
			default: // a new goal, or work with no goal
				truth, truthGoal = ptr("new"), goalID
			}
		}
		replayed = append(replayed, GoalRating{MomentID: r.MomentID, Start: r.Start, End: r.End, Said: saidNow, OK: right,
			Truth: truth, TruthGoalID: truthGoal, TruthTitle: r.TruthTitle})
		if was, is := describeAnswer(said), describeAnswer(now); was != is || right != ratedRight(r, said) {
			truth := kind
			if kind == "goal" && goalID != nil {
				if g := store.Thread(*goalID); g != nil {
					truth = "goal: " + g.Title
				}
			}
			report.Changed = append(report.Changed, ReplayChange{MomentID: r.MomentID, Start: r.Start, Place: said.Place, Title: said.Title,
				Was: was, Now: is, Truth: truth, RightNow: right})
		}
	}
	report.Before, report.After = scoreRatings(ratings), scoreRatings(replayed)
	report.BeforeBins, report.AfterBins = calibrationBins(ratings), calibrationBins(replayed)
	for _, c := range store.ModelCalls("")[callsBefore:] {
		if c.ErrorCode != nil && *c.ErrorCode == "skipped" {
			continue
		}
		report.Calls++
		if c.CostUsd != nil {
			report.CostUsd += *c.CostUsd
		}
	}
	report.P50Ms, report.P90Ms = quantile(latencies, 0.5), quantile(latencies, 0.9)
	return report
}

// ReplayTable: the report as plain text, the scores as rated against the scores replayed.
func ReplayTable(r ReplayReport) string {
	var b strings.Builder
	line := func(what, before, after string) { fmt.Fprintf(&b, "%-26s %14s %14s\n", what, before, after) }
	fmt.Fprintf(&b, "%d rated moments replayed (%d without their screen text)\n\n", r.Moments, r.NoText)
	line("", "as rated", "replayed")
	line("Goal right", percent(r.Before.GoalRight), percent(r.After.GoalRight))
	line("Drift precision", percent(r.Before.DriftPrecision), percent(r.After.DriftPrecision))
	line("Drift recall", percent(r.Before.DriftRecall), percent(r.After.DriftRecall))
	line("Drifts said", fmt.Sprint(r.Before.DriftsSaid), fmt.Sprint(r.After.DriftsSaid))
	line("Personal called a drift", fmt.Sprint(r.Before.PersonalSaidDrift), fmt.Sprint(r.After.PersonalSaidDrift))
	fmt.Fprintf(&b, "\nCalibration (p: moments, right)\n")
	for i := range r.AfterBins {
		was, now := r.BeforeBins[i], r.AfterBins[i]
		line(fmt.Sprintf("  %.1f–%.1f", now.From, now.To), fmt.Sprintf("%d, %s", was.N, percent(was.Right)), fmt.Sprintf("%d, %s", now.N, percent(now.Right)))
	}
	fmt.Fprintf(&b, "\nJev: %d calls, $%.5f, p50 %d ms, p90 %d ms\n", r.Calls, r.CostUsd, r.P50Ms, r.P90Ms)
	if len(r.Changed) > 0 {
		fmt.Fprintf(&b, "\nChanged answers (%d):\n", len(r.Changed))
		for _, c := range r.Changed {
			mark := "✗"
			if c.RightNow {
				mark = "✓"
			}
			fmt.Fprintf(&b, "  %s %s %s · %s: %s → %s (really %s)\n", mark, localClock(c.Start), c.Place, Clip(c.Title, 50), c.Was, c.Now, c.Truth)
		}
	}
	return b.String()
}
