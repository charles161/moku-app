package brain

import (
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// Launch QA, lens 2: what realistic sessions found in the brain, each kept as the smallest scenario that fails without its
// fix. The sessions themselves: scripts/qa-behaviour.sh.

func oracleWork(goal string) func(window, site, text string) screenTruth {
	return func(string, string, string) screenTruth {
		return screenTruth{goal: goal, p: 0.95, category: "learning"}
	}
}

// judgeSeries: a screen judged every 3 s for `samples` samples, its words changing each time (a lecture's captions, a page's
// clock), the person's last input `idle` seconds ago and growing. Returns the verdicts.
func judgeSeries(b *Brain, start int64, s screen, samples int, idle float64) []Verdict {
	var out []Verdict
	// The sample before: they had just switched here (input, so idle 0) with other words on screen.
	prime := s
	prime.text, prime.idle = "just opened", 0
	judgeAt(b, start-3_000, prime)
	for i := 0; i < samples; i++ {
		s.text = strings.Join([]string{"lecture captions", pseudoWords("cap", i, 12)[len(pseudoWords("cap", i, 12))-1], "line", pseudoWords("x", i, 3)[0]}, " ")
		s.idle = idle + float64(i*3)
		out = append(out, judgeAt(b, start+int64(i)*3_000, s))
	}
	return out
}

// A class on a course site, watched hands-free: the page's clock and captions change, nobody touches the keys for ten minutes.
// It is judged like the YouTube lecture next to it (work), not away: away earns no focus.
func TestALectureOnACourseSiteWatchedHandsFreeIsNotAway(t *testing.T) {
	b := newTestBrain(t, &fakeModels{oracle: oracleWork("studying machine learning")}, false)
	lecture := screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Gradient descent | Coursera",
		url: "https://www.coursera.org/learn/machine-learning/lecture/GFFPB/gradient-descent"}
	for i, v := range judgeSeries(b, baseTs, lecture, 20, 400) {
		if v.State != "working" {
			t.Fatalf("sample %d on a course lecture, idle %ds: %s (%s)", i, 400+i*3, v.State, v.Reason)
		}
	}
}

// The same hands-free idle on a page that isn't a lecture or a video is still away (the person left their desk).
func TestTheSameIdleOnAnOrdinaryPageIsStillAway(t *testing.T) {
	b := newTestBrain(t, &fakeModels{oracle: oracleWork("studying machine learning")}, false)
	page := screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Gradient descent - Wikipedia", url: "https://en.wikipedia.org/wiki/Gradient_descent"}
	vs := judgeSeries(b, baseTs, page, 5, 400)
	if v := vs[len(vs)-1]; v.State != "away" {
		t.Fatalf("an ordinary page, idle 400 s with its words changing: %s (%s)", v.State, v.Reason)
	}
}

// A page on the fence: Jev's answer moved with the words on it (the real one did for a Product Hunt page, 0.60 then 0.22
// with half the text, and for a Reddit thread, 0.61 then 0.38). Each new text was a new call, so a scrolled thread flipped
// between work and drift every few samples, and Moku flickered between a nod and a frown. The same window with mostly the
// same words keeps its answer for a few minutes, as goal-aware judging's reuse already does.
func fenceOracle(window, site, text string) screenTruth {
	if strings.Contains(text, "tippingword") { // the words that tip it
		return screenTruth{goal: "researching", p: 0.7, category: "learning"}
	}
	return screenTruth{goal: goalNone, p: 0.7, category: "reading"}
}

func TestAPageOnTheFenceKeepsItsAnswerWhileItsWordsBarelyChange(t *testing.T) {
	jev := &fakeModels{oracle: fenceOracle}
	b := newTestBrain(t, jev, false)
	thread := screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "Anyone else hit this bug? : r/golang", url: "https://www.reddit.com/r/golang/comments/1x2y3z/anyone_else_hit_this_bug/"}
	base := strings.Repeat("handler keeps returning context canceled after the client disconnects check whether you pass the request context ", 3)
	var states []string
	for i := 0; i < 20; i++ {
		s := thread
		s.text = base + pseudoWords("scroll", i, 1)[0] // one new word each time
		if i%2 == 1 {
			s.text += " tippingword"
		}
		states = append(states, judgeAt(b, baseTs+int64(i)*3_000, s).State)
	}
	for i, state := range states {
		if state != states[0] {
			t.Fatalf("the same thread flipped at sample %d: %v", i, states)
		}
	}
	if calls := jevCalls(b.Store)["judge"]; calls != 1 {
		t.Fatalf("%d Jev calls for one thread whose words barely changed", calls)
	}
}

func TestAnotherChatInTheSameWindowIsAskedAtOnce(t *testing.T) {
	jev := &fakeModels{oracle: func(window, site, text string) screenTruth {
		if strings.Contains(text, "potluck") {
			return screenTruth{goal: "building Potluck", p: 0.95, category: "communicating"}
		}
		return screenTruth{goal: goalNone, p: 0.95, category: "chatting"}
	}}
	b := newTestBrain(t, jev, false)
	chat := screen{app: "WhatsApp", bundle: "net.whatsapp.WhatsApp", title: "WhatsApp"}
	work, friends := chat, chat
	work.text = "potluck team pushed the settle up screen rounding bug fixed tests are green demo on sunday review the expense split logic tonight"
	friends.text = "weekend crew goa or pondy this weekend beaches and cafes booking the bus tonight which cafe first the french one near the promenade"
	if v := judgeAt(b, baseTs, work); v.State != "working" {
		t.Fatalf("the project chat: %s (%s)", v.State, v.Reason)
	}
	if v := judgeAt(b, baseTs+3_000, friends); v.State != "drifting" {
		t.Fatalf("another chat in the same window: %s (%s)", v.State, v.Reason)
	}
}

func TestAWindowIsAskedAgainAfterFiveMinutes(t *testing.T) {
	jev := &fakeModels{oracle: fenceOracle}
	b := newTestBrain(t, jev, false)
	s := screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "A long thread", url: "https://www.reddit.com/r/golang/comments/9/a_long_thread/"}
	base := strings.Repeat("a long discussion about context cancellation in handlers ", 4)
	s.text = base
	judgeAt(b, baseTs, s)
	s.text = base + " scrolled"
	judgeAt(b, baseTs+4*minute, s)
	if calls := jevCalls(b.Store)["judge"]; calls != 1 {
		t.Fatalf("%d calls within five minutes", calls)
	}
	s.text = base + " scrolled again"
	judgeAt(b, baseTs+6*minute, s)
	if calls := jevCalls(b.Store)["judge"]; calls != 2 {
		t.Fatalf("%d calls after five minutes", calls)
	}
}

// Permissions (parameter 8): with neither Accessibility nor Screen Recording, a browser is only its name. The real Jev, asked
// about a bare "Google Chrome", said drifting (p(work) 0.25), and the exact same screen reused that for ten minutes, so
// everything the person did in Chrome counted as a drift: sad, angry, standing, the ask. Moku "never guesses": nothing to go
// on is `unknown`, which changes nothing.
func TestAScreenWithNothingToGoOnIsUnknownNotAGuess(t *testing.T) {
	jev := &fakeModels{oracle: func(string, string, string) screenTruth {
		return screenTruth{goal: goalNone, p: 0.75, category: "other"}
	}}
	b := newTestBrain(t, jev, false)
	for i := 0; i < 5; i++ {
		v := judgeAt(b, baseTs+int64(i)*3_000, screen{app: "Google Chrome", bundle: "com.google.Chrome"})
		if v.State != "unknown" || v.Source != "fallback" {
			t.Fatalf("a browser with no title, address or words: %s, source %s (%s)", v.State, v.Source, v.Reason)
		}
	}
	if calls := jevCalls(b.Store)["judge"]; calls != 0 {
		t.Fatalf("%d Jev calls with nothing to show it", calls)
	}
}

func TestAWindowTitleAloneIsStillWorthAskingAbout(t *testing.T) {
	jev := &fakeModels{oracle: func(string, string, string) screenTruth {
		return screenTruth{goal: goalNone, p: 0.95, category: "watching"}
	}}
	b := newTestBrain(t, jev, false)
	v := judgeAt(b, baseTs, screen{app: "Google Chrome", bundle: "com.google.Chrome", title: "I Beat the HARDEST Elden Ring Boss With a Guitar - YouTube"})
	if v.State != "drifting" {
		t.Fatalf("a title with no address (Screen Recording on, Accessibility off): %s (%s)", v.State, v.Reason)
	}
}

// ── The clock (parameter 7): midnight, a time-zone change, daylight saving ──────────────────────────────────────────────

// atZone runs fn with the brain's local zone set to `name`, as the Mac's would be.
func atZone(t *testing.T, name string, fn func(loc *time.Location)) {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Skipf("no zone database for %s: %v", name, err)
	}
	// The brain's days go through Zone() (zone.go), which follows the Mac's zone; Go's own Local is set too.
	was, wasZone := time.Local, Zone()
	time.Local = loc
	zone.Store(loc)
	defer func() { time.Local = was; zone.Store(wasZone) }()
	fn(loc)
}

// workThrough: a coding session judged every 3 s from start to end, then the brain asked about it as of `asOf`.
func workThrough(t *testing.T, start, end, asOf int64) *Brain {
	t.Helper()
	store, err := OpenStore(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.Close)
	b := NewBrain(BrainOptions{Store: store, Models: &fakeModels{}, Config: func() CompanionConfig { return DefaultConfig }, Now: func() int64 { return asOf }})
	cursor := screen{app: "Cursor", bundle: "com.todesktop.230313mzl4w4u92", title: "handler.go - api", text: "package api"}
	for ts := start; ts < end; ts += 30_000 {
		cursor.text = "package api " + pseudoWords("typed", int(ts/30_000)%50, 1)[0]
		judgeAt(b, ts, cursor)
	}
	return b
}

// The day the clocks go back is 25 hours long and the one they go forward 23; four hours of work across either is four hours
// of focus, split between the two days when it crosses midnight, and the minutes add up.
func TestAFocusedSessionAcrossDaylightSavingAddsUp(t *testing.T) {
	for _, c := range []struct {
		zone       string
		start      [5]int // y m d h min
		dayHours   map[string]int
		firstDay   string
		secondDay  string
		wantFirst  int64
		wantSecond int64
	}{
		// New York, fall back on 2026-11-01 (02:00 EDT → 01:00 EST): 22:30 on Halloween to 02:30 EST on the 1st is 5 h of work
		// (22:30 → 02:00 EDT is 3.5 h, then 01:00 → 02:30 EST is 1.5 h).
		{zone: "America/New_York", start: [5]int{2026, 10, 31, 22, 30}, firstDay: "2026-10-31", secondDay: "2026-11-01", wantFirst: 90, wantSecond: 210},
		// Spring forward on 2026-03-08 (02:00 EST → 03:00 EDT): 22:30 on the 7th to 04:30 EDT is 5 h of work.
		{zone: "America/New_York", start: [5]int{2026, 3, 7, 22, 30}, firstDay: "2026-03-07", secondDay: "2026-03-08", wantFirst: 90, wantSecond: 210},
	} {
		atZone(t, c.zone, func(loc *time.Location) {
			start := time.Date(c.start[0], time.Month(c.start[1]), c.start[2], c.start[3], c.start[4], 0, 0, loc)
			end := start.Add(5 * time.Hour)
			b := workThrough(t, start.UnixMilli(), end.UnixMilli(), end.Add(time.Hour).UnixMilli())
			var total int64
			for i, day := range []struct {
				date string
				want int64
			}{{c.firstDay, c.wantFirst}, {c.secondDay, c.wantSecond}} {
				b.Lock()
				today, err := b.Today(day.date)
				b.Unlock()
				if err != nil {
					t.Fatal(err)
				}
				total += today.FocusedMinutes
				if abs64(today.FocusedMinutes-day.want) > 1 {
					t.Errorf("%s day %d (%s): %d focused minutes, want about %d", c.zone, i+1, day.date, today.FocusedMinutes, day.want)
				}
				if want := today.FocusedMinutes / 10; today.UnitsToday != want {  // a piece per 10 focused minutes, as the popover's house
					t.Errorf("%s %s: %d house pieces for %d minutes", c.zone, day.date, today.UnitsToday, today.FocusedMinutes)
				}
			}
			if abs64(total-300) > 2 {
				t.Errorf("%s: the two days add up to %d minutes of a five-hour session", c.zone, total)
			}
		})
	}
}

func abs64(x int64) int64 {
	if x < 0 {
		return -x
	}
	return x
}

// A day is the zone's calendar day, whatever its length.
func TestADayIsTheZonesCalendarDayWhateverItsLength(t *testing.T) {
	atZone(t, "America/New_York", func(*time.Location) {
		for date, hours := range map[string]int64{"2026-11-01": 25, "2026-03-08": 23, "2026-10-03": 24} {
			w, ok := dayWindow(date)
			if !ok {
				t.Fatalf("%s isn't a day", date)
			}
			if got := (w.End - w.Start) / (60 * minute); got != hours {
				t.Errorf("%s is %d hours long, want %d", date, got, hours)
			}
		}
	})
}

// ── Your day: what was done, in plain words ────────────────────────────────────────────────────────────────────────────

// docs.google.com looks like a brand's documentation to the docs-site rule (docs.<brand>.com), so three hours of writing in
// Google Docs showed as "read The Press That Remade Europe - Google Docs in the Google docs". A place people make things in is
// "worked on", whatever its address looks like.
func TestAStepInAWebEditorSaysWorkedOnNotRead(t *testing.T) {
	for _, c := range []struct {
		host, name, title, want string
	}{
		{"docs.google.com", "Google Docs", "The Press That Remade Europe - Google Docs", "worked on The Press That Remade Europe"},
		{"overleaf.com", "overleaf.com", "Lab Report 3 - Overleaf, Online LaTeX Editor", "worked on Lab Report 3"},
		{"figma.com", "Figma", "Roastery brand - Logo explorations - Figma", "worked on Roastery brand - Logo explorations"},
		// Documentation is still read.
		{"docs.stripe.com", "Stripe docs", "Webhooks | Stripe Documentation", "read Webhooks | Stripe Documentation in the Stripe docs"},
	} {
		a := GoalApp{App: "Google Chrome", BundleID: "com.google.Chrome", Host: ptr(c.host), Name: c.name}
		if got := stepFor(a, []string{c.title}, nil, "a goal"); got != c.want {
			t.Errorf("%s: %q, want %q", c.host, got, c.want)
		}
	}
}

// ── Text (parameter 13): very long titles, emoji, right-to-left, CJK ─────────────────────────────────────────────────────

// A window title can be anything a page names itself: an article's whole headline, a data: address, a chat with a hundred
// emoji. The screen text is clipped to 1,500 characters before a model sees it, the address to 160; the title was sent whole,
// so one huge title was a huge request, paid for on every sample.
func TestAHugeWindowTitleIsClippedBeforeAModelSeesIt(t *testing.T) {
	titles := map[string]string{
		"CJK":           strings.Repeat("日本語のウィンドウタイトルです🙂", 4_000),
		"right to left": strings.Repeat("مرحبا بالعالم، هذا عنوان نافذة طويل جدا ", 3_000),
		"emoji":         strings.Repeat("👨‍👩‍👧‍👦🏳️‍🌈", 5_000),
		"plain":         strings.Repeat("a very long headline ", 5_000),
	}
	for name, title := range titles {
		var seen string
		jev := &fakeModels{oracle: func(window, site, text string) screenTruth {
			seen = window
			return screenTruth{goal: "reading", p: 0.9, category: "learning"}
		}}
		b := newTestBrain(t, jev, false)
		v := judgeAt(b, baseTs, screen{app: "Google Chrome", bundle: "com.google.Chrome", title: title, url: "https://example.com/a-page", text: "some words on the page"})
		if v.State != "working" {
			t.Errorf("%s: %s (%s)", name, v.State, v.Reason)
		}
		if n := Len16(seen); n == 0 || n > 300 {
			t.Errorf("%s: the model saw a window title of %d characters", name, n)
		}
		if !utf8.ValidString(seen) {
			t.Errorf("%s: the model saw a title that isn't valid UTF-8", name)
		}
		// What the person sees in Your day is the stored title, untouched.
		rows := b.Store.Timeline(0, MaxSafeInteger)
		if len(rows) != 1 || rows[0].Title != title {
			t.Errorf("%s: the stored title changed", name)
		}
	}
}

// A title that already says where it is ("… by Mira Okafor on Dribbble") doesn't need telling again: Your day read
// "Coffee Roaster Branding by Mira Okafor on Dribbble on dribbble.com".
func TestAStepDoesNotSayWhereTwice(t *testing.T) {
	for _, c := range []struct{ host, name, title, want string }{
		{"dribbble.com", "dribbble.com", "Coffee Roaster Branding by Mira Okafor on Dribbble", "Coffee Roaster Branding by Mira Okafor on Dribbble"},
		{"behance.net", "behance.net", "Ember Coffee Brand Identity on Behance", "Ember Coffee Brand Identity on Behance"},
		{"pinterest.com", "pinterest.com", "Coffee packaging inspiration - Pinterest", "Coffee packaging inspiration - Pinterest"},
		// A title that doesn't says it.
		{"coursera.org", "coursera.org", "Gradient descent", "Gradient descent on coursera.org"},
	} {
		a := GoalApp{App: "Google Chrome", BundleID: "com.google.Chrome", Host: ptr(c.host), Name: c.name}
		if got := stepFor(a, []string{c.title}, nil, "a goal"); got != c.want {
			t.Errorf("%s: %q, want %q", c.host, got, c.want)
		}
	}
}
