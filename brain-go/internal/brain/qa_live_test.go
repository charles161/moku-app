package brain

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
)

// Records the real Jev's answer to "work or a distraction?" for every QA screen the rules don't decide, into
// testdata/qa/jev-tape.json. Run by hand, once (2026-10-04: 83 screens + a few text variations, about $0.003):
//
//	MOKU_LIVE=1 MOKU_QA_RECORD=1 MOKU_DEV_ENV=…/bunny/.env go test ./internal/brain -run QARecordJevTape -v
//
// Only the focus question goes out (the pipeline friends' builds run). Labeling questions and Luna are skipped, so the
// call count is the number of screens. MOKU_QA_MAX_CALLS (default 96) stops the run before it passes a budget.

type tapeEntry struct {
	Key       string  `json:"key"`
	ID        string  `json:"id"`
	App       string  `json:"app"`
	Title     string  `json:"title"`
	Site      string  `json:"site,omitempty"`
	Choice    string  `json:"choice"`
	PWork     float64 `json:"pWork"`
	LatencyMs int64   `json:"latencyMs"`
	Model     string  `json:"model"`
	// Variant: the same page with its words changed (scrolled, typed into), asked again; the answer must not flip.
	Variants []tapeVariant `json:"variants,omitempty"`
}

type tapeVariant struct {
	Kind  string  `json:"kind"`
	PWork float64 `json:"pWork"`
}

// recordingJev lets only the focus question through to the real Jev, and counts every call that goes out.
type recordingJev struct {
	inner    Models
	calls    int
	maxCalls int
	last     JudgeOutcome
}

func (r *recordingJev) Health() *CloudHealth { return nil }

func (r *recordingJev) Judge(state any, questions QuestionSet, local bool) JudgeOutcome {
	if len(questions) != 1 || questions[0].Key != "kind" {
		return JudgeOutcome{ErrorCode: "skipped"}
	}
	if r.calls >= r.maxCalls {
		return JudgeOutcome{ErrorCode: "budget"}
	}
	out := r.inner.Judge(state, questions, false)
	r.calls += max(1, out.Attempts)
	r.last = out
	return out
}

func (r *recordingJev) Write(WriteRequest) WriteOutcome { return WriteOutcome{ErrorCode: "skipped"} }

func TestQARecordJevTape(t *testing.T) {
	if os.Getenv("MOKU_LIVE") != "1" || os.Getenv("MOKU_QA_RECORD") != "1" {
		t.Skip("live: MOKU_LIVE=1 MOKU_QA_RECORD=1")
	}
	t.Setenv("MOKU_HOME", t.TempDir())
	LoadEnv(DevEnvPath())
	if ModelAccess() != "key" {
		t.Fatalf("no development key")
	}
	maxCalls := 96
	if v := os.Getenv("MOKU_QA_MAX_CALLS"); v != "" {
		fmt.Sscan(v, &maxCalls)
	}
	screens := loadQAScreens(t)
	_, asked := qaRuleVerdicts(t, screens)
	jev := &recordingJev{inner: NewModels(ModelOptions{Transport: NewGateway()}), maxCalls: maxCalls}

	judgeFresh := func(i int, s screen) Verdict {
		store, err := OpenStore(":memory:")
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		b := NewBrain(BrainOptions{Store: store, Models: jev, Config: func() CompanionConfig { return DefaultConfig }, Now: func() int64 { return baseTs }})
		return judgeAt(b, baseTs+int64(i)*20*minute, s)
	}

	var tape []tapeEntry
	byID := map[string]int{}
	for i, s := range screens {
		if !asked[s.ID] {
			continue
		}
		v := judgeFresh(i, s.screen())
		if v.State == "unknown" {
			t.Fatalf("%s: Jev failed (%s) after %d calls; stopping so a breaker doesn't skew the rest", s.ID, v.Reason, jev.calls)
		}
		kind, _ := jev.last.Answers.Get("kind")
		pWork, given := kind.Probabilities["work"]
		if !given && kind.Choice == "work" {
			pWork = 1
		}
		entry := tapeEntry{Key: s.tapeKey(), ID: s.ID, App: s.App, Title: s.Title, Choice: kind.Choice, PWork: pWork,
			LatencyMs: jev.last.LatencyMs, Model: jev.last.Model}
		if s.URL != "" {
			entry.Site = deref(hostAndPath(ptr(s.URL)))
		}
		byID[s.ID] = len(tape)
		tape = append(tape, entry)
		mark := "✓"
		if (v.State == "working") != (s.Truth == "work") {
			mark = "✗"
		}
		t.Logf("%s %-20s truth %-7s → %-8s p(work)=%.2f %4d ms  %s", mark, s.ID, s.Truth, v.State, pWork, jev.last.LatencyMs, Clip(s.Title, 52))
	}

	// Consistency: a page whose words change (scrolled, typed into) must not flip. The borderline answers are asked
	// again with half the text, and with the text plus the noise a page picks up (a banner, ads), within the budget.
	borderline := []tapeEntry{}
	for _, e := range tape {
		if e.PWork > 0.2 && e.PWork < 0.85 {
			borderline = append(borderline, e)
		}
	}
	sort.SliceStable(borderline, func(i, j int) bool { return abs(borderline[i].PWork-0.5) < abs(borderline[j].PWork-0.5) })
	for _, e := range borderline {
		if jev.calls+2 > maxCalls {
			break
		}
		var s qaScreen
		for _, c := range screens {
			if c.ID == e.ID {
				s = c
			}
		}
		half := s.screen()
		half.text = s.Text[:len(s.Text)/2]
		noisy := s.screen()
		noisy.text = s.Text + " Accept all cookies. Subscribe to our newsletter. Advertisement. Related stories. Sign in."
		for k, variant := range []struct {
			kind string
			s    screen
		}{{"half the words", half}, {"cookie banner and ads", noisy}} {
			v := judgeFresh(1000+k, variant.s)
			if v.State == "unknown" {
				break
			}
			kind, _ := jev.last.Answers.Get("kind")
			pWork := kind.Probabilities["work"]
			tape[byID[e.ID]].Variants = append(tape[byID[e.ID]].Variants, tapeVariant{Kind: variant.kind, PWork: pWork})
			flip := (pWork >= 0.5) != (e.PWork >= 0.5)
			t.Logf("variant %-20s %-22s p(work)=%.2f (was %.2f) flip=%v", e.ID, variant.kind, pWork, e.PWork, flip)
		}
	}

	data, err := json.MarshalIndent(tape, "", " ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile("testdata/qa/jev-tape.json", append(data, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("recorded %d screens; %d Jev calls in all (budget %d)", len(tape), jev.calls, maxCalls)
	var wrong []string
	for _, e := range tape {
		for _, s := range screens {
			if s.ID == e.ID && (e.PWork >= 0.5) != (s.Truth == "work") && s.Truth != "meeting" && s.Truth != "neutral" {
				wrong = append(wrong, fmt.Sprintf("%s (%s, p=%.2f)", e.ID, s.Truth, e.PWork))
			}
		}
	}
	t.Logf("Jev disagrees with the default truth on %d of %d: %s", len(wrong), len(tape), strings.Join(wrong, ", "))
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}

// Permission states (launch QA parameter 8), asked of the real Jev: what it says when Moku can see very little. Three calls:
// the browser alone (no Accessibility, no Screen Recording: only the app's name), and a browser with only its window title
// (Screen Recording on, Accessibility off: no address, no text).
//
//	MOKU_LIVE=1 MOKU_QA_PERM=1 MOKU_DEV_ENV=…/bunny/.env go test ./internal/brain -run QAPermissionStatesLive -v
func TestQAPermissionStatesLive(t *testing.T) {
	if os.Getenv("MOKU_LIVE") != "1" || os.Getenv("MOKU_QA_PERM") != "1" {
		t.Skip("live: MOKU_LIVE=1 MOKU_QA_PERM=1")
	}
	t.Setenv("MOKU_HOME", t.TempDir())
	LoadEnv(DevEnvPath())
	if ModelAccess() != "key" {
		t.Fatalf("no development key")
	}
	jev := &recordingJev{inner: NewModels(ModelOptions{Transport: NewGateway()}), maxCalls: 3}
	for i, s := range []screen{
		{app: "Google Chrome", bundle: "com.google.Chrome"},
		{app: "Google Chrome", bundle: "com.google.Chrome", title: "Home / X"},
		{app: "Google Chrome", bundle: "com.google.Chrome", title: "I Beat the HARDEST Elden Ring Boss With a Guitar - YouTube"},
	} {
		store, err := OpenStore(":memory:")
		if err != nil {
			t.Fatal(err)
		}
		b := NewBrain(BrainOptions{Store: store, Models: jev, Config: func() CompanionConfig { return DefaultConfig }, Now: func() int64 { return baseTs }})
		v := judgeAt(b, baseTs+int64(i)*20*minute, s)
		store.Close()
		t.Logf("title %q → %s (%s)", s.title, v.State, v.Reason)
	}
	t.Logf("%d Jev calls", jev.calls)
}
