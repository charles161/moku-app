package brain

// POST /v1/judge: one sample in, one verdict out, from two separate pipelines.
//  1. FOCUS decides the state: working, drifting, away, meeting or unknown.
//  2. LABELING adds whatever is already known for this context (thread, activity, bucket; nil at first) and labels
//     the context in the background. It never changes the state.
//  3. For work that just changed on screen, completion detection (rare: only on a pattern hit).
//
// Everything keys on the sample's own timestamp, so a replayed day judges like the live one.
func (b *Brain) Judge(sample ActivitySample) Verdict {
	started := nowMs()
	store := b.Store
	previous := store.PreviousSample(sample.Ts(), sample.ID)
	store.InsertSample(sample)

	// Text arrives only when it changed: reuse the last text (and its hash) seen on this window.
	screen := screenOf(sample)
	text := sample.Text
	if text == nil {
		if last, hash, ok := store.LastText(screen, sample.Ts(), sample.ID); ok {
			text = &last
			if screen.TextHash == nil {
				screen.TextHash = hash
			}
		}
	}

	decision := b.focus.decide(focusInput{sample: sample, screen: screen, text: text, previous: previous})
	var labels Labels
	if decision.labels != nil {
		// Goal-aware judging: the goal call answered the labels with the state.
		labels = *decision.labels
		if labels.Thread != nil {
			store.TouchThread(labels.Thread.ID, sample.Ts())
		}
	} else {
		labels = b.labeler.labelsFor(sample.ID, screen, text, decision.State, sample.Ts())
	}
	var completion *Completion
	if decision.State == "working" {
		var threadID *string
		if labels.Thread != nil {
			threadID = &labels.Thread.ID
		}
		completion = b.complete.detect(sample, screen, text, threadID)
	}
	verdict := Verdict{
		SampleID: sample.ID, State: decision.State, Confidence: decision.Confidence, Source: decision.Source, Reason: decision.Reason,
		Thread: labels.Thread, Activity: labels.Activity, Category: labels.Category, IsNewThread: labels.IsNewThread,
		Completion: completion, LatencyMs: nowMs() - started,
	}
	b.markGoal(&verdict, sample.Ts())
	store.InsertVerdict(verdict, sample.Ts())
	return verdict
}

// ── Privacy ─────────────────────────────────────────────────────────────────────────────────────────────────────

// Screen text is needed for minutes, not days. After TextKeepMs it's deleted from the samples (text still on screen
// stays until it isn't), and model calls that carried it keep their outcome, not their input. MOKU_KEEP_SCREEN_TEXT=1
// keeps everything (development only).
//
// Charles's calibration build keeps it CalibrationTextKeepMs (14 days), so his rated moments can be replayed through a
// new version of the rules (spec decision 1). Any other build deletes it after an hour again, from its first start.
const (
	TextKeepMs            = 60 * 60_000
	CalibrationTextKeepMs = 14 * 24 * 60 * 60_000
)

var TextPurposes = []string{"judge", "label", "name", "completion", "activity", "category", "goal"}

// TextKeepMs: how long this brain keeps screen text.
func (b *Brain) TextKeepMs() int64 {
	if b.calibrate {
		return CalibrationTextKeepMs
	}
	return TextKeepMs
}

func ForgetScreenText(store *Store, now, keepMs int64) (samples, calls int64) {
	cutoff := now - keepMs
	samples, calls = store.ForgetText(cutoff), store.ForgetCallInputs(cutoff, TextPurposes)
	if samples+calls > 0 {
		store.SettleAfterForgetting()
	}
	return
}
