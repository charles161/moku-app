package brain

import (
	"fmt"
	"strings"
	"unicode"
)

// Reuse (goal-aware judging, docs/specs/goal-aware-judging.md): the same window with mostly the same words reuses its
// last answer instead of asking Jev again. The rule came from shadow mode (2026-10-01): on Charles's Mac about half of
// the judgments repeated a window whose words had barely changed (a video's subtitles, a chat's next message).
//
// Anchors live in memory only: each holds a window's word set, never its text, and they're gone when the brain stops.

// goalAnchor: a window's last answer from a goal call, with the words it was given.
type goalAnchor struct {
	ts       int64
	textHash *string
	words    map[string]struct{}
	decision FocusDecision
}

// anchor remembers a goal call's answer for its window.
func (f *focusPipeline) anchor(s Screen, ts int64, text *string, d FocusDecision) {
	f.anchors[windowKey(s)] = goalAnchor{ts: ts, textHash: s.TextHash, words: wordSet(text), decision: d}
	if len(f.anchors) > 500 {
		for key, old := range f.anchors {
			if ts-old.ts >= int64(Rules.Goal.Reuse.SameScreenMinutes)*minute {
				delete(f.anchors, key)
			}
		}
	}
}

// reusedGoal: rule reuse. The exact same screen within Rules.Goal.Reuse.SameScreenMinutes, or the same window with
// mostly the same words within MaxAgeMinutes, takes the window's last answer with no call. Anything else (another
// chat, another page, a big change) asks again at once. The time counts from the last real call, so a window that
// keeps changing a little is still asked every few minutes.
func (f *focusPipeline) reusedGoal(s Screen, ts int64, text *string) *FocusDecision {
	a, ok := f.anchors[windowKey(s)]
	if !ok || ts < a.ts {
		return nil
	}
	age, reuse := ts-a.ts, Rules.Goal.Reuse
	why := ""
	switch {
	case s.TextHash != nil && eqStr(a.textHash, s.TextHash) && age < int64(reuse.SameScreenMinutes)*minute:
		why = "the same screen"
	case age < int64(reuse.MaxAgeMinutes)*minute && similarWords(a.words, wordSet(text), reuse.MinSimilarity):
		why = "mostly the same words"
	default:
		return nil
	}
	d := a.decision
	if d.labels != nil {
		labels := *d.labels
		labels.IsNewThread = false
		if labels.Thread != nil {
			goal := f.b.resolveGoal(labels.Thread.ID)
			if goal == nil {
				return nil // the goal was forgotten since: ask again
			}
			labels.Thread = ref(goal)
			if labels.Activity == nil {
				labels.Activity = goal.Activity // a new goal's phrase and bucket arrive with its name
			}
			if labels.Category == nil && isFocusBucket(goal.Category) {
				labels.Category = goal.Category
			}
		}
		d.labels = &labels
	}
	ago := int64(Round(float64(age) / 1000))
	return &FocusDecision{State: d.State, Confidence: d.Confidence, Source: "shortcut", labels: d.labels,
		Reason: because(ruleReuse, fmt.Sprintf("%s as %ds ago: %s", why, ago, d.Reason))}
}

// windowKey: the app, window title and address, whatever the text.
func windowKey(s Screen) string { return JSON([]any{s.BundleID, s.Title, s.URL}) }

// similarWords: whether two screens' words overlap enough. No text on either side counts as the same screen; text on
// one side only counts as a big change.
func similarWords(a, b map[string]struct{}, min float64) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return jaccard(a, b) >= min
}

// wordSet: the distinct words of three or more letters or digits, lowercased. Nil for no text.
func wordSet(text *string) map[string]struct{} {
	if text == nil {
		return nil
	}
	words := map[string]struct{}{}
	for _, w := range strings.FieldsFunc(strings.ToLower(*text), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) }) {
		if len([]rune(w)) >= 3 {
			words[w] = struct{}{}
		}
	}
	return words
}

// jaccard: the share of words two sets have in common, from 0 (none) to 1 (the same words). Two empty sets are the same.
func jaccard(a, b map[string]struct{}) float64 {
	if len(a) == 0 && len(b) == 0 {
		return 1
	}
	shared := 0
	for w := range a {
		if _, ok := b[w]; ok {
			shared++
		}
	}
	return float64(shared) / float64(len(a)+len(b)-shared)
}
