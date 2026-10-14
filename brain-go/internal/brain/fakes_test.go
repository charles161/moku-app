package brain

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"
)

// A scripted Jev and Luna for judging tests. The oracle says what a screen is, by goal title ("none" for not work,
// "new" for work that's none of the goals); the fake answers whatever question it's asked from that, so the same
// script drives the old pipeline (work or distraction, then which thread) and goal-aware judging.

// verdictOf: a screen's truth for the oracle. dist, when set, is the full distribution (by goal title, "new", "none");
// otherwise goal gets p and the rest is shared.
type screenTruth struct {
	goal     string
	p        float64
	category string
	dist     map[string]float64
}

type fakeModels struct {
	mu     sync.Mutex
	oracle func(window, site, text string) screenTruth
	// same: whether a newly named goal repeats an existing one (by title), and how sure.
	same  func(newTitle string) (existing string, p float64)
	names func(window string) (title, summary, activity string)
	asked []string // every Jev call's question ids, in order ("goal+category", "kind", …)
	// during: runs while a call is out (the brain's lock let go), as the dashboard or a background task might.
	during func()
}

func (m *fakeModels) Health() *CloudHealth { return nil }

func get(state OMap, key string) string {
	v, _ := state.Get(key)
	s, _ := v.(string)
	return s
}

// Jev's usage as the gateway reports it: 2.7 characters a token and $0.042 per million input tokens, as measured on
// Charles's real calls (2026-10-03).
func fakeUsage(state any, questions QuestionSet) CallMeta {
	in := int64(float64(len(JSON(state))+len(JSON(questions))) / 2.7)
	return CallMeta{Model: "typesafe-ai/jev", LatencyMs: 500, Attempts: 1, Usage: Usage{TokensIn: in, TokensOut: 20, CostUsd: ptr(float64(in) * 0.042e-6)}}
}

func (m *fakeModels) Judge(state any, questions QuestionSet, local bool) JudgeOutcome {
	m.mu.Lock()
	defer m.mu.Unlock()
	st := state.(OMap)
	m.asked = append(m.asked, strings.Join(questions.Keys(), "+"))
	if m.during != nil {
		m.during()
	}
	truth := screenTruth{goal: goalNone, p: 1, category: "other"}
	if m.oracle != nil {
		truth = m.oracle(get(st, "window"), get(st, "site"), get(st, "screen_contents"))
	}
	answers := Answers{byID: map[string]EvaluationAnswer{}}
	for _, q := range questions {
		question := q.Value.(EvaluationQuestion)
		var a EvaluationAnswer
		switch q.Key {
		case "goal", "thread":
			a = distribution(question.Criteria, truth, q.Key == "thread")
		case "kind":
			workP := 1 - truth.weight(goalNone)
			choice := "work"
			if workP < 0.5 {
				choice = "distraction"
			}
			a = EvaluationAnswer{Type: "choice", Choice: choice, Probabilities: map[string]float64{"work": workP, "distraction": 1 - workP}, order: []string{"work", "distraction"}}
		case "category":
			a = EvaluationAnswer{Type: "choice", Choice: truth.category}
		case "same":
			thread, _ := st.Get("thread")
			title := get(thread.(OMap), "name")
			existing, p := "", 0.0
			if m.same != nil {
				existing, p = m.same(title)
			}
			pickTitle := goalDifferent
			if existing != "" {
				pickTitle = existing
			} else {
				p = 1
			}
			a = distribution(question.Criteria, screenTruth{goal: pickTitle, p: p}, false)
		default:
			a = EvaluationAnswer{Type: "boolean", Probability: ptr(0.0)}
		}
		answers.byID[q.Key] = a
		answers.order = append(answers.order, q.Key)
	}
	return JudgeOutcome{OK: true, Answers: answers, CallMeta: fakeUsage(state, questions)}
}

// weight: the truth's probability for one option, by title or "new"/"none".
func (t screenTruth) weight(option string) float64 {
	if t.dist != nil {
		return t.dist[option]
	}
	if option == t.goal {
		return t.p
	}
	return 0
}

// distribution: the truth as a choice among the question's criteria (goal ids by their titles). A title that isn't
// offered counts as "new" (or "none", for the old thread question, which has no "new").
func distribution(criteria OMap, truth screenTruth, threadQuestion bool) EvaluationAnswer {
	titleOf := map[string]string{}
	for _, kv := range criteria {
		title, _, _ := strings.Cut(kv.Value.(string), ": ")
		titleOf[kv.Key] = title
	}
	want := map[string]float64{}
	options := []string{truth.goal}
	if truth.dist != nil {
		options = nil
		for option := range truth.dist {
			options = append(options, option)
		}
		sort.Strings(options)
	}
	special := func(k string) bool { return k == goalNew || k == goalNone || k == goalDifferent }
	keyFor := func(option string) string {
		if _, offered := titleOf[option]; offered && special(option) {
			return option
		}
		for k, title := range titleOf {
			if title == option && !special(k) {
				return k
			}
		}
		for _, fallback := range []string{goalNew, goalDifferent} {
			if _, offered := titleOf[fallback]; offered && !threadQuestion && option != goalNone {
				return fallback
			}
		}
		return noneChoice
	}
	for _, option := range options {
		want[keyFor(option)] += truth.weight(option)
	}
	rest, free := 1.0, []string{}
	for _, kv := range criteria {
		rest -= want[kv.Key]
		if _, set := want[kv.Key]; !set {
			free = append(free, kv.Key)
		}
	}
	probs, order, choice, best := map[string]float64{}, []string{}, "", -1.0
	for _, kv := range criteria {
		p, set := want[kv.Key]
		if !set && len(free) > 0 {
			p = max(0, rest) / float64(len(free))
		}
		probs[kv.Key] = p
		order = append(order, kv.Key)
		if p > best {
			choice, best = kv.Key, p
		}
	}
	return EvaluationAnswer{Type: "choice", Choice: choice, Probabilities: probs, order: order}
}

func (m *fakeModels) Write(req WriteRequest) WriteOutcome {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := OMap{}
	for _, f := range req.Schema {
		out = append(out, KV{f.Name, "x"})
	}
	if req.System == namingSystem {
		window := req.Prompt
		title, summary, activity := "a goal", "A goal", "working"
		if m.names != nil {
			title, summary, activity = m.names(window)
		}
		out = OMap{{"title", title}, {"summary", summary}, {"activity", activity}}
	} else if req.System == activitySystem {
		out = OMap{{"activity", "doing things"}}
	}
	return WriteOutcome{OK: true, Output: out, CallMeta: CallMeta{Model: "openai/gpt-6-luna", LatencyMs: 800, Attempts: 1}}
}

func newTestBrain(t *testing.T, models Models, goalJudging bool) *Brain {
	t.Helper()
	store, err := OpenStore(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.Close)
	return NewBrain(BrainOptions{Store: store, Models: models, Config: func() CompanionConfig { return DefaultConfig },
		Now: func() int64 { return baseTs }, GoalJudging: goalJudging})
}

// baseTs: 2026-10-03 10:00 in India (the tests' day).
const baseTs = int64(1_759_465_800_000)

type screen struct {
	app, bundle, title, url, text string
	idle                          float64
}

var sampleSeq int

// judgeAt: one sample through the brain at ts, then any background work. Text goes with every sample.
func judgeAt(b *Brain, ts int64, s screen) Verdict {
	sampleSeq++
	sample := ActivitySample{ID: fmt.Sprintf("s%06d", sampleSeq), TS: float64(ts), App: AppInfo{BundleID: s.bundle, Name: s.app},
		Window: &WindowInfo{Title: s.title}, Activity: InputActivity{KeysPerMinute: 30, IdleSeconds: s.idle}}
	if s.url != "" {
		sample.Window.URL = ptr(s.url)
	}
	if s.text != "" {
		sum := sha1.Sum([]byte(s.text))
		sample.Text, sample.TextHash, sample.TextSource = ptr(s.text), ptr(hex.EncodeToString(sum[:8])), ptr("accessibility")
	}
	b.Lock()
	v := b.Judge(sample)
	b.Unlock()
	b.Settle()
	return v
}

// jevCalls: Jev calls made so far, by purpose.
func jevCalls(store *Store) map[string]int {
	out := map[string]int{}
	for _, c := range store.ModelCalls("") {
		switch c.Purpose {
		case "judge", "label", "goal", "category", "dedupe", "completion":
			out[c.Purpose]++
		}
	}
	return out
}

func total(calls map[string]int) int {
	n := 0
	for _, c := range calls {
		n += c
	}
	return n
}

// seedGoal: a named goal, active at ts.
func seedGoal(store *Store, title, summary string, ts int64) *ThreadRow {
	id := newThreadID()
	store.CreateThread(id, title, summary, ts, nil)
	store.NameThread(id, title, summary, ptr(title))
	return store.Thread(id)
}

// workedOn: a working verdict on a goal at ts, so it's the current goal.
func workedOn(store *Store, goal *ThreadRow, ts int64) {
	sampleSeq++
	id := fmt.Sprintf("seed%06d", sampleSeq)
	store.InsertSample(ActivitySample{ID: id, TS: float64(ts), App: AppInfo{BundleID: "com.todesktop.230313mzl4w4u92", Name: "Cursor"}, Window: &WindowInfo{Title: "seed"}})
	store.InsertVerdict(Verdict{SampleID: id, State: "working", Thread: ref(goal), Source: "shortcut", Reason: "[seed]"}, ts)
}
