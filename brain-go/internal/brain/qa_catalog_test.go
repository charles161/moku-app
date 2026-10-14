package brain

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
)

// Launch QA, lens 2 (docs/specs/launch-qa.md): realistic screens for a writer, a designer, a coder, a student, meetings,
// dictation, research that looks like browsing and real drifts (scripts/qa-screens.py writes testdata/qa/screens.json).
// This file loads them and finds which ones the rules decide and which reach Jev. qa_live_test.go records Jev's real
// answer for each of those, once, into testdata/qa/jev-tape.json; the QA brain (qa_serve_test.go) replays the tape, so a
// session of any length costs no model calls.

type qaScreen struct {
	ID     string   `json:"id"`
	App    string   `json:"app"`
	Bundle string   `json:"bundle"`
	Title  string   `json:"title"`
	URL    string   `json:"url,omitempty"`
	Text   string   `json:"text"`
	Truth  string   `json:"truth"`
	Who    []string `json:"who"`
	Note   string   `json:"note,omitempty"`
	// Task: the goal a work screen belongs to ("studying organic chemistry"); Bucket: where Your day files it.
	Task   string `json:"task,omitempty"`
	Bucket string `json:"bucket,omitempty"`
}

func (s qaScreen) screen() screen {
	return screen{app: s.App, bundle: s.Bundle, title: s.Title, url: s.URL, text: s.Text}
}

// tapeKey: what Jev is shown to tell screens apart (the app, the window and the site's host and path), so two samples of
// one page with different words get one answer, as a model that sees the same page would give.
func tapeKey(app, title, site string) string { return app + "\x1f" + title + "\x1f" + site }

func (s qaScreen) tapeKey() string {
	var site string
	if s.URL != "" {
		site = deref(hostAndPath(ptr(s.URL)))
	}
	return tapeKey(s.App, s.Title, site)
}

func loadQAScreens(t testing.TB) []qaScreen {
	t.Helper()
	data, err := os.ReadFile("testdata/qa/screens.json")
	if err != nil {
		t.Fatalf("the QA screens: %v (python3 scripts/qa-screens.py)", err)
	}
	var screens []qaScreen
	if err := json.Unmarshal(data, &screens); err != nil {
		t.Fatal(err)
	}
	return screens
}

// countingJev: a Jev that says "work" and counts the screens it was asked about, by the app, window and site it saw.
type countingJev struct {
	fakeModels
	mu2    sync.Mutex
	judged []string
}

func (c *countingJev) Judge(state any, questions QuestionSet, local bool) JudgeOutcome {
	st := state.(OMap)
	if len(questions) == 1 && questions[0].Key == "kind" {
		c.mu2.Lock()
		c.judged = append(c.judged, tapeKey(get(st, "user_app"), get(st, "window"), get(st, "site")))
		c.mu2.Unlock()
	}
	return c.fakeModels.Judge(state, questions, local)
}

// qaWhoJudged: the focus rulebook's verdict for each screen alone, and whether it needed Jev.
func qaRuleVerdicts(t *testing.T, screens []qaScreen) (rule map[string]Verdict, askedJev map[string]bool) {
	rule, askedJev = map[string]Verdict{}, map[string]bool{}
	for i, s := range screens {
		jev := &countingJev{fakeModels: fakeModels{oracle: func(window, site, text string) screenTruth {
			return screenTruth{goal: goalNone, p: 0.5, category: "other"}
		}}}
		b := newTestBrain(t, jev, false)
		// Every screen alone, 20 minutes apart, so nothing is reused from another.
		v := judgeAt(b, baseTs+int64(i)*20*minute, s.screen())
		rule[s.ID] = v
		askedJev[s.ID] = len(jev.judged) > 0
	}
	return
}

func TestQAScreensThatReachJev(t *testing.T) {
	screens := loadQAScreens(t)
	rule, asked := qaRuleVerdicts(t, screens)
	byWho := map[string][2]int{}
	var viaJev []string
	for _, s := range screens {
		for _, who := range s.Who {
			c := byWho[who]
			if asked[s.ID] {
				c[1]++
			} else {
				c[0]++
			}
			byWho[who] = c
		}
		if asked[s.ID] {
			viaJev = append(viaJev, s.ID)
		}
	}
	whos := make([]string, 0, len(byWho))
	for w := range byWho {
		whos = append(whos, w)
	}
	sort.Strings(whos)
	for _, w := range whos {
		t.Logf("%-10s rules %2d, Jev %2d", w, byWho[w][0], byWho[w][1])
	}
	t.Logf("%d screens, %d decided by the rules, %d reach Jev", len(screens), len(screens)-len(viaJev), len(viaJev))
	for _, s := range screens {
		if !asked[s.ID] {
			v := rule[s.ID]
			t.Logf("rule  %-20s %-9s truth %-8s %s", s.ID, v.State, s.Truth, v.Reason)
		}
	}
	if os.Getenv("MOKU_QA_LIST") != "" {
		t.Logf("via Jev: %s", strings.Join(viaJev, " "))
	}
}
