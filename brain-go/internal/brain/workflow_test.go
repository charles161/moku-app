package brain

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"
)

// A scripted day in apps: one verdict every 30 s. Each move is (state, thread, app, title, url, activity, seconds).
type move struct {
	state, thread, app, title, url, activity string
	seconds                                  int
}

var bundles = map[string]string{
	"Cursor": "com.todesktop.230313mzl4w4u92", "Ghostty": "com.mitchellh.ghostty", "Chrome": "com.google.Chrome",
	"Claude": "com.anthropic.claudefordesktop", "Telegram": "ru.keepcoder.Telegram", "Mail": "com.apple.mail", "Notion": "notion.id",
}

func movedSpans(moves []move) ([]Span, Window) {
	var rows []TimelineRow
	ts := int64(1_000_000_000)
	start := ts
	for i, m := range moves {
		for k := 0; k < m.seconds/30; k++ {
			row := TimelineRow{SampleID: fmt.Sprintf("m%d-%d", i, k), TS: ts, State: m.state, AppName: m.app, BundleID: bundles[m.app], Title: m.title}
			if m.thread != "" {
				row.ThreadID = ptr(m.thread)
			}
			if m.url != "" {
				row.URL = ptr("https://" + m.url)
			}
			if m.activity != "" {
				row.Activity = ptr(m.activity)
			}
			rows = append(rows, row)
			ts += 30_000
		}
	}
	return toSpans(rows, ts), Window{start, ts}
}

func work(thread, app, title, url string, minutes float64) move {
	return move{"working", thread, app, title, url, "", int(minutes * 60)}
}

func drift(url string, minutes float64) move {
	return move{"drifting", "", "Chrome", "", url, "", int(minutes * 60)}
}

func chainOf(g *GoalDay) string {
	var links []string
	for _, step := range g.Workflow {
		if step.Kind == "detour" {
			links = append(links, fmt.Sprintf("↩ %s %dm ×%d", *step.Place, step.Minutes, step.Count))
		} else {
			links = append(links, fmt.Sprintf("%s %dm", step.AppID, step.Minutes))
		}
	}
	return strings.Join(links, " → ")
}

// The workflow: the apps in the order the work reached them (a hop under a minute doesn't count), and the detour
// after the app the work had reached when it happened.
func TestTheWorkflowGoesInOrderWithTheDetourWhereItHappened(t *testing.T) {
	spans, w := movedSpans([]move{
		work("a", "Cursor", "SettingsWindow.swift — bunny", "", 20),
		work("a", "Ghostty", "swift test", "", 0.5), // a hop
		work("a", "Cursor", "Onboarding.swift — bunny", "", 10),
		drift("youtube.com/watch?v=1", 4),
		work("a", "Ghostty", "swift test — MokuVisual", "", 8),
		work("a", "Chrome", "Subscriptions overview", "docs.stripe.com/billing/subscriptions", 6),
	})
	a := goalByID(goalsOf(spans, w), "a")
	want := "app:com.todesktop.230313mzl4w4u92 30m → ↩ YouTube 4m ×1 → app:com.mitchellh.ghostty 9m → site:docs.stripe.com 6m"
	if got := chainOf(a); got != want {
		t.Fatalf("workflow: %s\nwant:     %s", got, want)
	}
	if a.Sittings != 1 {
		t.Fatalf("one sitting: %d", a.Sittings)
	}
	names := map[string]string{}
	for _, app := range a.Apps {
		names[app.id()] = app.Name
	}
	if names["site:docs.stripe.com"] != "Stripe docs" || names["app:com.mitchellh.ghostty"] != "Ghostty" {
		t.Fatalf("names: %v", names)
	}
}

// Real days hop between goals all day: a pause of half an hour or more on other things parts two sittings.
func TestAGoalPickedUpAgainLaterIsAnotherSitting(t *testing.T) {
	for _, between := range []struct {
		minutes  float64
		sittings int64
	}{{20, 1}, {45, 2}} {
		spans, w := movedSpans([]move{
			work("a", "Cursor", "Today.swift — bunny", "", 10),
			work("b", "Chrome", "Pricing", "stripe.com/pricing", between.minutes),
			work("a", "Cursor", "Today.swift — bunny", "", 5),
		})
		a := goalByID(goalsOf(spans, w), "a")
		if a.Sittings != between.sittings || a.Detours != 0 {
			t.Fatalf("%v minutes on b between: %d sittings, %d detours", between.minutes, a.Sittings, a.Detours)
		}
	}
}

// Whatever the timeline: at most goalChainApps apps, each once, in the order reached, with its own minutes, and every
// detour in some link.
func TestTheWorkflowHoldsOnAnyTimeline(t *testing.T) {
	r := rand.New(rand.NewSource(11))
	apps := []string{"Cursor", "Ghostty", "Chrome", "Claude", "Notion", "Telegram"}
	for round := 0; round < 150; round++ {
		var moves []move
		for i := 0; i < 20+r.Intn(200); i++ {
			switch r.Intn(6) {
			case 0:
				moves = append(moves, drift("x.com/home", float64(1+r.Intn(6))/2))
			case 1:
				moves = append(moves, work("b", "Notion", "Plan", "", float64(1+r.Intn(80))/2))
			default:
				moves = append(moves, work("a", apps[r.Intn(len(apps))], "Today.swift", "", float64(1+r.Intn(10))/2))
			}
		}
		spans, w := movedSpans(moves)
		for _, g := range goalsOf(spans, w) {
			minutes := map[string]int64{}
			for _, app := range g.Apps {
				minutes[app.id()] = app.Minutes
			}
			var detours, shown int64
			var last int64 = -1 << 62
			seen := map[string]bool{}
			for _, step := range g.Workflow {
				if step.Kind == "detour" {
					detours += step.Count
					continue
				}
				shown++
				first := int64(-1)
				for _, app := range g.Apps {
					if app.id() == step.AppID {
						first = app.FirstAt
					}
				}
				if seen[step.AppID] || minutes[step.AppID] != step.Minutes || first < last {
					t.Fatalf("round %d, goal %s: %s", round, g.ID, chainOf(&g))
				}
				seen[step.AppID], last = true, first
			}
			if shown > goalChainApps || (len(g.Apps) > 0 && detours != g.Detours) || g.Sittings < 1 {
				t.Fatalf("round %d, goal %s: %d apps shown, %d of %d detours, %d sittings", round, g.ID, shown, detours, g.Detours, g.Sittings)
			}
		}
	}
}

func TestStepsSayWhatWasDoneInPlainWords(t *testing.T) {
	spans, w := movedSpans([]move{
		work("a", "Cursor", "● SettingsWindow.swift — bunny", "", 20),
		work("a", "Cursor", "Onboarding.swift — bunny", "", 10),
		work("a", "Ghostty", "✳ swift test — MokuVisual", "", 6),
		work("a", "Chrome", "Subscriptions overview - Stripe", "docs.stripe.com/billing/subscriptions", 6),
		work("a", "Chrome", "Designing a rate limiter - YouTube", "youtube.com/watch?v=2", 4),
	})
	a := goalByID(goalsOf(spans, w), "a")
	want := []string{
		"edited SettingsWindow.swift and Onboarding.swift",
		"ran swift test",
		"read Subscriptions overview in the Stripe docs",
		"watched Designing a rate limiter",
	}
	if strings.Join(a.Steps, " · ") != strings.Join(want, " · ") {
		t.Fatalf("steps:\n%q\nwant:\n%q", a.Steps, want)
	}
}

func TestStepsFallBackToMokusWordsWhenTitlesSayNothing(t *testing.T) {
	spans, w := movedSpans([]move{
		{"working", "a", "Claude", "Claude", "", "configuring MCP", 600},
		{"working", "a", "Mail", "Inbox — Work", "", "studying the invoices", 300},
		{"working", "a", "Ghostty", "~/mj/lightslips.ai/bunny", "", "building Moku", 300},
		{"working", "a", "Telegram", "Founders (3)", "", "", 240},
		{"working", "a", "Notion", "Research Prompts", "", "", 180},
	})
	got := goalByID(goalsOf(spans, w), "a").Steps
	want := []string{"configured MCP", "studied the invoices", "built Moku", "messaged Founders"}
	if strings.Join(got, " · ") != strings.Join(want, " · ") {
		t.Fatalf("steps:\n%q\nwant:\n%q", got, want)
	}
}

func TestAStepThatOnlyRepeatsTheGoalIsLeftOut(t *testing.T) {
	spans, w := movedSpans([]move{{"working", "a", "Claude", "Claude", "", "Goal a", 600}})
	if steps := goalByID(goalsOf(spans, w), "a").Steps; len(steps) != 0 {
		t.Fatalf("steps: %q", steps)
	}
}

func TestStepHelpers(t *testing.T) {
	for in, want := range map[string]string{
		"configuring MCP": "configured MCP", "planning app testing": "planned app testing", "studying system design": "studied system design",
		"reading an analysis": "read an analysis", "writing fiction": "wrote fiction", "playing chess": "played chess",
		"onboarding flow": "onboarding flow", "email": "email", "DSA practice": "DSA practice", "agreeing terms": "agreed terms",
		"chatting with Claude": "chatted with Claude", "debugging the relay": "debugged the relay",
	} {
		if got := pastTense(in); got != want {
			t.Errorf("pastTense(%q) = %q, want %q", in, got, want)
		}
	}
	for host, want := range map[string]string{
		"docs.stripe.com": "Stripe docs", "eu.posthog.com": "PostHog", "youtube.com": "YouTube", "github.com": "GitHub",
		"example.com": "example.com", "developer.apple.com": "Apple Developer",
	} {
		if got := appName("Chrome", ptr(host)); got != want {
			t.Errorf("appName(%q) = %q, want %q", host, got, want)
		}
	}
	if got := filesIn([]string{"Today.swift, goals_test.go — bunny", "v1.2.3 notes", ".env — bunny"}); strings.Join(got, " ") != "Today.swift goals_test.go .env" {
		t.Errorf("filesIn: %q", got)
	}
	if got := commandsIn([]string{"zsh", "charles@mac: ~/bunny", "~/mj/bunny", "npm run dev — website", "Fix the welcome"}); strings.Join(got, "|") != "npm run dev" {
		t.Errorf("commandsIn: %q", got)
	}
	if got := listed([]string{"a.swift", "b.swift", "c.swift", "d.swift"}, "files"); got != "a.swift, b.swift and 2 more files" {
		t.Errorf("listed: %q", got)
	}
}

// The wire shape: a goal always has a workflow and steps (never null), and a detour names its place as Your day does.
func TestTheWorkflowsWireShape(t *testing.T) {
	spans, w := movedSpans([]move{work("a", "Cursor", "", "", 5), drift("x.com/home", 2), work("a", "Cursor", "", "", 5)})
	text := JSON(goalsOf(spans, w))
	for _, want := range []string{`"steps":[]`, `"sittings":1`, `{"kind":"app","appId":"app:com.todesktop.230313mzl4w4u92","minutes":10,"count":0,"place":null}`,
		`{"kind":"detour","appId":"","minutes":2,"count":1,"place":"X"}`} {
		if !strings.Contains(text, want) {
			t.Fatalf("no %s in %s", want, text)
		}
	}
}
