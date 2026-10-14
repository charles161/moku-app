package brain

import (
	"crypto/sha256"
	"encoding/hex"
)

// Completion detection (rule completion): meaningful work finishing on screen, like a push, a green test run,
// "Accepted", a merge, a deploy or an important email. Precise and cheap:
//  1. only for a working verdict on a changed screen (the sample carries new text);
//  2. a deterministic prefilter (CompletionPatterns) must match;
//  3. the screen must not have fired before, nor the same kind on the same thread or in the same app within 10 min;
//  4. Jev confirms with one yes/no question at p ≥ 0.9.
//
// A screen is asked about at most once per brain, whatever the answer.
type completionDetector struct {
	b     *Brain
	asked map[string]bool
}

func newCompletionDetector(b *Brain) *completionDetector {
	return &completionDetector{b: b, asked: map[string]bool{}}
}

func (d *completionDetector) detect(sample ActivitySample, s Screen, text *string, threadID *string) *Completion {
	if sample.Text == nil || text == nil || *text == "" {
		return nil
	}
	pattern, label, ok := prefilter(*text, s.Title, s.URL)
	if !ok {
		return nil
	}
	key := ""
	if s.TextHash != nil {
		key = *s.TextHash
	} else {
		sum := sha256.Sum256([]byte(*text))
		key = hex.EncodeToString(sum[:])[:16]
	}
	since := sample.Ts() - int64(Rules.Completion.RepeatAfterMinutes)*60_000
	if d.asked[key] || d.b.Store.CompletionSeen(&key, pattern.Kind, threadID, s.BundleID, since) {
		return nil
	}
	d.asked[key] = true

	state := labelState(ScreenInput{App: s.AppName, WindowTitle: s.Title, Site: hostAndPath(s.URL), ScreenContents: ptr(Slice16(*text, TextExcerpt))}, nil)
	questions := QuestionSet{{"done", completionQuestion(pattern)}}
	outcome := d.b.judgeModel(state, questions, false)
	var p *float64
	var output any
	if outcome.OK {
		answer, _ := outcome.Answers.Get("done")
		p = answer.Probability
		output = judgeOutput(outcome, false)
	}
	d.b.Store.InsertModelCall(ModelCallRecord{
		Purpose: "completion", SampleID: &sample.ID, Model: outcome.Model, OK: outcome.OK, ErrorCode: errorCodePtr(outcome.OK, outcome.ErrorCode),
		LatencyMs: outcome.LatencyMs, Attempts: outcome.Attempts, TokensIn: outcome.TokensIn, TokensOut: outcome.TokensOut, CostUsd: outcome.CostUsd,
		Input:  OMap{{"state", state}, {"questions", questions}, {"candidate", OMap{{"kind", pattern.Kind}, {"label", label}}}},
		Output: output,
	})
	// Jev not answering isn't a no: the same screen is asked again on a later sample.
	if !outcome.OK && outcome.ErrorCode != "schema" {
		delete(d.asked, key)
	}
	if p == nil || *p < Rules.Completion.MinP {
		return nil
	}
	d.b.Store.InsertCompletion(sample.ID, sample.Ts(), pattern.Kind, label, threadID, &key)
	return &Completion{Kind: pattern.Kind, Label: label}
}

// prefilter: the first completion pattern the screen matches, with its label.
func prefilter(text, title string, rawURL *string) (CompletionPattern, string, bool) {
	site := siteOf(rawURL)
	for _, p := range CompletionPatterns {
		if p.Site != "" && !onSite(site, p.Site) {
			continue
		}
		match := p.Pattern.FindStringSubmatch(text)
		if match == nil || (p.Unless != nil && p.Unless.MatchString(text)) {
			continue
		}
		return p, Clip(OneLine(p.Label(match, title, text)), 60), true
	}
	return CompletionPattern{}, "", false
}
