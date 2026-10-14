package brain

import (
	"regexp"
	"sort"
)

// POST /v1/feedback. Every piece of feedback is stored (it labels the eval set). Three kinds teach:
//
//	pat            the context of the feedback's sample (else the latest one) becomes work, on the thread active then
//	               (else a new thread from that screen).
//	markedWork     "This was work": the named segments are relabeled working, and each distinct context inside them
//	               becomes work (on the thread active then).
//	markedNotWork  "This wasn't work": relabeled drifting, and those contexts become not work.
//
// A correction names Your day's segments, or a time (`since`, from the companion's right-click: every moment from then
// until the correction), or else one sample.

type LearnedRuleView struct {
	ID         int64      `json:"id"`
	Scope      string     `json:"scope"`
	Effect     string     `json:"effect"`
	Source     string     `json:"source"`
	CreatedAt  int64      `json:"createdAt"`
	Thread     *ThreadRef `json:"thread"`
	BundleID   string     `json:"bundleId"`
	Host       *string    `json:"host"`
	PathPrefix *string    `json:"pathPrefix"`
	Title      *string    `json:"title"`
}

type FeedbackResult struct {
	OK        bool              `json:"ok"`
	Learned   []LearnedRuleView `json:"learned"`
	Relabeled int               `json:"relabeled"`
}

const (
	maxContextsPerCorrection = 10
	threadAtWindowMs         = 60 * 60_000
)

func (b *Brain) Feedback(f Feedback) FeedbackResult {
	store := b.Store
	now := b.now()
	store.InsertFeedback(f)
	none := FeedbackResult{OK: true, Learned: []LearnedRuleView{}}
	// A lesson changes both pipelines' view of that context: focus reads the rule at once, labeling labels it again.
	teach := func(l lesson) *LearnedRuleRow {
		rule := learn(store, l)
		store.ForgetContextLabels(rule.BundleID + "|" + rule.describe())
		return rule
	}
	ts := int64(f.TS)

	if f.Kind == "pat" {
		sample := b.target(f.SampleID)
		if sample == nil {
			return none
		}
		var thread *ThreadRow
		if f.ThreadID != nil {
			thread = store.Thread(*f.ThreadID)
		}
		if thread == nil {
			if current, _, _, ok := store.CurrentThread(sample.TS, 0, ""); ok {
				thread = current
			}
		}
		if thread == nil {
			text := sample.Text
			if text == nil {
				if last, _, ok := store.LastText(sample.Screen, sample.TS, sample.ID); ok {
					text = &last
				}
			}
			thread, _ = b.startThread(sample.Screen, text, sample.TS, &sample.ID)
		}
		rule := teach(lesson{Screen: sample.Screen, Effect: "work", ThreadID: &thread.ID, Source: "pat", SampleID: &sample.ID, At: ts})
		return FeedbackResult{OK: true, Learned: []LearnedRuleView{ruleView(store, rule)}}
	}

	if f.Kind != "markedWork" && f.Kind != "markedNotWork" {
		return none
	}
	work := f.Kind == "markedWork"

	// What was corrected: the named segments, or else one sample.
	var spans []Span
	if len(f.SegmentIDs) > 0 {
		spans = b.segmentSpans(f.SegmentIDs, now)
	} else if f.Since != nil {
		spans = toSpans(store.Timeline(int64(*f.Since), ts+1), now)
	} else if sample := b.target(f.SampleID); sample != nil {
		var rows []TimelineRow
		for _, r := range store.Timeline(sample.TS, sample.TS+1) {
			if r.SampleID == sample.ID {
				rows = append(rows, r)
			}
		}
		spans = toSpans(rows, now)
	}
	if len(spans) == 0 {
		return none
	}
	ids := make([]string, len(spans))
	for i, s := range spans {
		ids[i] = s.SampleID
	}
	state := "drifting"
	if work {
		state = "working"
	}
	store.Relabel(ids, state, ts)

	// One learned rule per distinct context, the ones they spent longest on first.
	type context struct {
		span Span
		ms   int64
	}
	var order []string
	contexts := map[string]*context{}
	for _, span := range spans {
		key := JSON(scopeOf(span.screen()))
		c := contexts[key]
		if c == nil {
			c = &context{span: span}
			contexts[key] = c
			order = append(order, key)
		}
		c.ms += span.End - span.Start
	}
	list := make([]*context, len(order))
	for i, k := range order {
		list[i] = contexts[k]
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].ms > list[j].ms })
	if len(list) > maxContextsPerCorrection {
		list = list[:maxContextsPerCorrection]
	}
	learned := []LearnedRuleView{}
	for _, c := range list {
		var threadID *string
		if work {
			threadID = f.ThreadID
			if threadID == nil {
				threadID = c.span.ThreadID
			}
			if threadID == nil {
				if current, _, _, ok := store.CurrentThread(c.span.Start, c.span.Start-threadAtWindowMs, ""); ok {
					threadID = &current.ID
				}
			}
		}
		effect := "notWork"
		if work {
			effect = "work"
		}
		sampleID := c.span.SampleID
		rule := teach(lesson{Screen: c.span.screen(), Effect: effect, ThreadID: threadID, Source: f.Kind, SampleID: &sampleID, At: ts})
		learned = append(learned, ruleView(store, rule))
	}
	return FeedbackResult{OK: true, Learned: learned, Relabeled: len(spans)}
}

// target: the feedback's sample, else the latest one.
func (b *Brain) target(sampleID *string) *SampleRow {
	if sampleID != nil {
		if s := b.Store.Sample(*sampleID); s != nil {
			return s
		}
	}
	return b.Store.LatestSample()
}

var segPrefix = regexp.MustCompile(`^seg-`)

// segmentSpans: the verdicts inside Today-window segments (seg-<first sample id>), found by rebuilding that day.
func (b *Brain) segmentSpans(segmentIDs []string, now int64) []Span {
	var out []Span
	days := map[string]map[string][]Span{}
	for _, id := range segmentIDs {
		first := b.Store.Sample(segPrefix.ReplaceAllString(id, ""))
		if first == nil {
			continue
		}
		date := localDate(first.TS)
		segments, ok := days[date]
		if !ok {
			bounds, _ := dayWindow(date)
			spans, window := daySpans(b.Store, bounds, now)
			segments = map[string][]Span{}
			for _, s := range daySegments(spans, window, labelResolver(b.Store, spans)) {
				segments[s.ID] = s.Spans
			}
			days[date] = segments
		}
		out = append(out, segments[id]...)
	}
	return out
}

func ruleView(store *Store, rule *LearnedRuleRow) LearnedRuleView {
	var thread *ThreadRef
	if rule.ThreadID != nil {
		thread = ref(store.Thread(*rule.ThreadID))
	}
	return LearnedRuleView{ID: rule.ID, Scope: rule.describe(), Effect: rule.Effect, Source: rule.Source, CreatedAt: rule.CreatedAt,
		Thread: thread, BundleID: rule.BundleID, Host: rule.Host, PathPrefix: rule.PathPrefix, Title: rule.Title}
}
