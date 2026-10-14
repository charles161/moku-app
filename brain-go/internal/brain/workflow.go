package brain

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

// Your day by task (docs/specs/next-wave.md §4): each goal's workflow, read from the same spans as its minutes.
//   workflow  its apps in the order the work reached them, with their minutes, and the detours where they happened:
//             "Cursor 58m → Ghostty 22m → ↩ YouTube 4m → Stripe docs 16m". A quick hop into an app (under a minute)
//             doesn't count as reaching it.
//   sittings  how many separate stretches of the day it was worked on. Real days hop between goals all day (a 65-minute
//             goal spread over 12 hours, 2026-10-04), so a goal's hours come with "on and off" when there are several.
//   steps     what was done, in plain words and in the order it was done: from the windows' titles ("edited
//             Today.swift", "ran swift test", "read Webhooks in the Stripe docs"), else Moku's words ("configured MCP").
//             Made on the Mac from what Your day already has, shown only to the person, never sent anywhere.

const (
	flowWork   = "work"
	flowDetour = "detour"
	// flowJoinMs: a pause this short (other work, a glance away) doesn't end a stretch.
	flowJoinMs = 2 * 60_000
	// flowHopMs: time in an app shorter than this is a hop, not the work reaching it.
	flowHopMs = 60_000
	// sittingGapMs: a pause this long between two stretches of a goal parts two sittings.
	sittingGapMs = 30 * 60_000
	// goalChainApps apps at most in a workflow (its longest); goalStepsShown steps at most, each naming at most
	// stepObjects things.
	goalChainApps  = 4
	goalStepsShown = 4
	stepObjects    = 2
)

// flowPiece: a stretch of a goal's time in one app (work), or a drift that came back to it (detour: its drifting ms,
// and the places it went).
type flowPiece struct {
	kind, appID string
	start, end  int64
	ms          int64
	places      map[string]int64
}

// addWork: work on the goal in one app or site, from start to end.
func (g *goalAcc) addWork(appID string, start, end int64) {
	if n := len(g.flow); n > 0 {
		last := &g.flow[n-1]
		if start-last.end <= flowJoinMs {
			if last.kind == flowWork && last.appID == appID {
				last.end = max(last.end, end)
				return
			}
			start = last.end
		}
	}
	g.flow = append(g.flow, flowPiece{kind: flowWork, appID: appID, start: start, end: end})
}

// addDetour: a drift from start to end (ms of it drifting, at places) that came back to the goal.
func (g *goalAcc) addDetour(start, end, ms int64, places map[string]int64) {
	if n := len(g.flow); n > 0 && start-g.flow[n-1].end <= flowJoinMs {
		start = g.flow[n-1].end
	}
	g.flow = append(g.flow, flowPiece{kind: flowDetour, start: start, end: end, ms: ms, places: places})
}

// firstReached: each app's FirstAt is when the work first stayed in it a minute or more (else its first hop).
func firstReached(flow []flowPiece, apps []GoalApp) {
	first, hop := map[string]int64{}, map[string]int64{}
	for _, p := range flow {
		if p.kind != flowWork {
			continue
		}
		if _, seen := hop[p.appID]; !seen {
			hop[p.appID] = p.start
		}
		if _, seen := first[p.appID]; !seen && p.end-p.start >= flowHopMs {
			first[p.appID] = p.start
		}
	}
	for i := range apps {
		if at, ok := first[apps[i].id()]; ok {
			apps[i].FirstAt = at
		} else if at, ok := hop[apps[i].id()]; ok {
			apps[i].FirstAt = at
		}
	}
}

// workflow: the goal's longest apps (at most goalChainApps) in the order the work reached them, each followed by the
// detours that happened once the work had reached it and before it reached the next.
func workflow(flow []flowPiece, apps []GoalApp) []WorkflowStep {
	shown := append([]GoalApp{}, apps...) // longest first
	if len(shown) > goalChainApps {
		shown = shown[:goalChainApps]
	}
	sort.SliceStable(shown, func(i, j int) bool { return shown[i].FirstAt < shown[j].FirstAt })
	type slot struct {
		count, ms int64
		places    map[string]int64
	}
	slots := make([]slot, len(shown))
	for _, p := range flow {
		if p.kind != flowDetour || len(shown) == 0 {
			continue
		}
		k := 0
		for i, a := range shown {
			if a.FirstAt <= p.start {
				k = i
			}
		}
		if slots[k].places == nil {
			slots[k].places = map[string]int64{}
		}
		slots[k].count++
		slots[k].ms += p.ms
		for place, ms := range p.places {
			slots[k].places[place] += ms
		}
	}
	out := []WorkflowStep{}
	for i, a := range shown {
		out = append(out, WorkflowStep{Kind: "app", AppID: a.id(), Minutes: a.Minutes})
		if s := slots[i]; s.count > 0 {
			place := topPlace(s.places)
			out = append(out, WorkflowStep{Kind: "detour", Minutes: max(1, roundMinutes(s.ms)), Count: s.count, Place: &place})
		}
	}
	return out
}

// sittings: the goal's separate stretches of the day: a pause of sittingGapMs or more between two parts them.
func sittings(flow []flowPiece) int64 {
	var n int64
	for i, p := range flow {
		if i == 0 || p.start-flow[i-1].end >= sittingGapMs {
			n++
		}
	}
	return n
}

func (a GoalApp) id() string {
	if a.Host != nil {
		return "site:" + *a.Host
	}
	return "app:" + a.BundleID
}

// ── Names ───────────────────────────────────────────────────────────────────────────────────────────────────────

// siteNames: sites with a name people use for them (NeutralWords.PlaceNames has the rest). The first match wins.
var siteNames = []siteValue{
	{"github.com", "GitHub"}, {"gitlab.com", "GitLab"}, {"stackoverflow.com", "Stack Overflow"}, {"chatgpt.com", "ChatGPT"},
	{"claude.ai", "Claude"}, {"gemini.google.com", "Gemini"}, {"perplexity.ai", "Perplexity"}, {"docs.google.com", "Google Docs"},
	{"sheets.google.com", "Google Sheets"}, {"slides.google.com", "Google Slides"}, {"mail.google.com", "Gmail"},
	{"calendar.google.com", "Google Calendar"}, {"drive.google.com", "Google Drive"}, {"notion.so", "Notion"}, {"linear.app", "Linear"},
	{"figma.com", "Figma"}, {"leetcode.com", "LeetCode"}, {"vercel.com", "Vercel"}, {"posthog.com", "PostHog"}, {"app.slack.com", "Slack"},
	{"developer.apple.com", "Apple Developer"}, {"developer.mozilla.org", "MDN"}, {"web.whatsapp.com", "WhatsApp"},
	{"web.telegram.org", "Telegram"}, {"wikipedia.org", "Wikipedia"},
}

// docsLabels: a site under one of these is a brand's documentation: docs.stripe.com is "Stripe docs".
var docsLabels = map[string]bool{"docs": true, "developer": true, "developers": true, "dev": true, "learn": true, "devdocs": true, "api": true}

// appName: what Your day calls an app or a site: "Stripe docs", "GitHub", "YouTube", else the host, or the app's name.
func appName(app string, host *string) string {
	if host == nil {
		return app
	}
	for _, list := range [][]siteValue{siteNames, NeutralWords.PlaceNames} {
		for _, p := range list {
			if onSite(host, p.Site) {
				return p.Value
			}
		}
	}
	if brand, ok := docsBrand(*host); ok {
		return brand + " docs"
	}
	return *host
}

// docsBrand: "Stripe" for docs.stripe.com, or false when the site isn't a brand's documentation.
func docsBrand(host string) (string, bool) {
	labels := strings.Split(host, ".")
	if len(labels) < 3 || !docsLabels[labels[0]] {
		return "", false
	}
	brand := []rune(labels[len(labels)-2])
	if len(brand) == 0 {
		return "", false
	}
	brand[0] = unicode.ToUpper(brand[0])
	return string(brand), true
}

// ── Steps ───────────────────────────────────────────────────────────────────────────────────────────────────────

var (
	editorApps = map[string]bool{
		"com.todesktop.230313mzl4w4u92": true, "com.microsoft.VSCode": true, "com.microsoft.VSCodeInsiders": true, "com.vscodium": true,
		"com.apple.dt.Xcode": true, "dev.zed.Zed": true, "dev.zed.Zed-Preview": true, "com.sublimetext.4": true, "com.sublimetext.3": true,
		"com.panic.Nova": true, "com.exafunction.windsurf": true, "com.google.android.studio": true, "com.barebones.bbedit": true,
	}
	terminalApps = map[string]bool{
		"com.apple.Terminal": true, "com.googlecode.iterm2": true, "dev.warp.Warp-Stable": true, "dev.warp.Warp": true,
		"com.mitchellh.ghostty": true, "io.alacritty": true, "org.alacritty": true, "net.kovidgoyal.kitty": true,
		"com.github.wez.wezterm": true, "co.zeit.hyper": true,
	}
	assistantApps = map[string]bool{"com.anthropic.claudefordesktop": true, "com.openai.chat": true}
	messageApps   = map[string]bool{
		"com.tinyspeck.slackmacgap": true, "ru.keepcoder.Telegram": true, "org.telegram.desktop": true, "net.whatsapp.WhatsApp": true,
		"com.apple.MobileSMS": true, "com.hnc.Discord": true, "com.microsoft.teams2": true, "com.microsoft.teams": true,
	}
	mailApps       = map[string]bool{"com.apple.mail": true, "com.microsoft.Outlook": true, "com.readdle.smartemail-Mac": true, "com.superhuman.electron": true}
	assistantSites = []string{"chatgpt.com", "claude.ai", "gemini.google.com", "perplexity.ai"}
	messageSites   = []string{"app.slack.com", "web.whatsapp.com", "web.telegram.org", "discord.com", "teams.microsoft.com"}
	mailSites      = []string{"mail.google.com", "outlook.office.com", "outlook.office365.com", "outlook.live.com"}
	videoSites     = []string{"youtube.com", "youtu.be", "vimeo.com", "loom.com"}
	// editorSites: places on the web people make things in. What they did there isn't "reading", and docs.google.com is no
	// brand's documentation (docs.<brand>.com), whatever its address looks like.
	editorSites = []string{"docs.google.com", "sheets.google.com", "slides.google.com", "forms.google.com", "notion.so", "figma.com",
		"canva.com", "miro.com", "overleaf.com", "airtable.com", "coda.io", "framer.com", "webflow.com"}
	readingSites   = []string{"stackoverflow.com", "developer.mozilla.org", "developer.apple.com", "medium.com", "wikipedia.org", "dev.to", "substack.com"}

	// titleParts: a title's parts, "SettingsWindow.swift — bunny" or "general | Lightslips".
	titleParts = regexp.MustCompile(jsSpace + `+[-–—|·]` + jsSpace + `+`)
	// fileName: "Today.swift", ".env", "goals_test.go"; not "1.2.3".
	fileName = regexp.MustCompile(`^(?:\.?[\p{L}\p{N}_+-]+(?:\.[\p{L}\p{N}_+-]+)*\.[A-Za-z][A-Za-z0-9]{0,9}|\.[A-Za-z][\p{L}\p{N}_-]*)$`)
	// command: what a terminal's title shows while something runs: "swift test", "npm run dev", "go test ./...".
	command      = regexp.MustCompile(`^[a-z][a-z0-9._+-]*(?:` + jsSpace + `+[^\s]+){0,3}$`)
	shells       = map[string]bool{"zsh": true, "bash": true, "fish": true, "sh": true, "login": true, "nu": true, "tmux": true}
	leadingMarks = regexp.MustCompile(`^[^\p{L}\p{N}~/.]+`)
	parenthetic  = regexp.MustCompile(jsSpace + `*\([^)]*\)$`)
)

func inSites(host *string, sites []string) bool {
	for _, site := range sites {
		if onSite(host, site) {
			return true
		}
	}
	return false
}

// steps: what was done toward the goal, in the order it was done: a step from each of its longest apps.
func (g *goalAcc) steps(day GoalDay) []string {
	apps := append([]GoalApp{}, day.Apps...)
	if len(apps) > goalStepsShown {
		apps = apps[:goalStepsShown] // the longest (Apps is longest first)
	}
	sort.SliceStable(apps, func(i, j int) bool { return apps[i].FirstAt < apps[j].FirstAt })
	out := []string{}
	seen := map[string]bool{strings.ToLower(day.Title): true}
	for _, a := range apps {
		acc := g.apps[a.id()]
		if acc == nil {
			continue
		}
		step := stepFor(a, rankedTitles(acc.titles), acc.activities, day.Title)
		if step == "" || seen[strings.ToLower(step)] {
			continue
		}
		seen[strings.ToLower(step)] = true
		out = append(out, Clip(step, 80))
	}
	return out
}

// rankedTitles: the titles, longest time first (ties by title).
func rankedTitles(ms map[string]int64) []string {
	titles := make([]string, 0, len(ms))
	for t := range ms {
		titles = append(titles, t)
	}
	sort.SliceStable(titles, func(i, j int) bool {
		if ms[titles[i]] != ms[titles[j]] {
			return ms[titles[i]] > ms[titles[j]]
		}
		return titles[i] < titles[j]
	})
	return titles
}

// stepFor: one app's step, in plain words: what its titles say was done there, else Moku's words for it, else "".
func stepFor(a GoalApp, titles []string, activities map[string]int64, goal string) string {
	titles = telling(titles, a)
	host := a.Host
	switch {
	case host == nil && editorApps[a.BundleID]:
		if files := filesIn(titles); len(files) > 0 {
			return "edited " + listed(files, "files")
		}
		if len(titles) > 0 {
			return "edited " + titleParts.Split(titles[0], -1)[0]
		}
	case host == nil && terminalApps[a.BundleID]:
		if commands := commandsIn(titles); len(commands) > 0 {
			return "ran " + listed(commands, "commands")
		}
	case host == nil && mailApps[a.BundleID], inSites(host, mailSites):
		// A mail window's title is a subject line or an address: Moku's words say it better.
	case host == nil && assistantApps[a.BundleID], inSites(host, assistantSites):
		if len(titles) > 0 {
			return "asked " + a.Name + " about " + titles[0]
		}
	case host == nil && messageApps[a.BundleID], inSites(host, messageSites):
		var names []string
		for _, t := range titles {
			names = append(names, parenthetic.ReplaceAllString(titleParts.Split(t, -1)[0], ""))
		}
		if names = distinct(names); len(names) > 0 {
			return "messaged " + listed(names, "chats")
		}
	case inSites(host, videoSites):
		if len(titles) > 0 {
			return "watched " + titles[0]
		}
	case inSites(host, editorSites):
		if len(titles) > 0 {
			return "worked on " + withoutProductName(titles[0], a)
		}
	case host != nil:
		if len(titles) > 0 {
			if brand, ok := docsBrand(*host); ok {
				return "read " + titles[0] + " in the " + brand + " docs"
			}
			if inSites(host, readingSites) {
				return "read " + titles[0]
			}
			if namesTheSite(titles[0], a) {
				return titles[0]
			}
			return titles[0] + " on " + a.Name
		}
	default:
		if len(titles) > 0 {
			return titles[0] + " in " + a.Name
		}
	}
	for _, what := range topActivities(activities, len(activities)) {
		if what != NeutralWords.Work && !strings.EqualFold(what, goal) {
			return pastTense(what)
		}
	}
	return ""
}

// namesTheSite: whether a title already ends with the site's name ("… on Dribbble", "… - Pinterest"), so Your day needn't add where.
func namesTheSite(title string, a GoalApp) bool {
	title = strings.ToLower(Trim(title))
	names := []string{strings.ToLower(a.Name)}
	if a.Host != nil {
		if labels := strings.Split(*a.Host, "."); len(labels) >= 2 {
			names = append(names, labels[len(labels)-2])
		}
	}
	for _, name := range names {
		if name != "" && strings.HasSuffix(title, name) {
			return true
		}
	}
	return false
}

// withoutProductName: "The Press That Remade Europe - Google Docs" is "The Press That Remade Europe": the last part of a title
// that only names the product it was made in goes.
func withoutProductName(title string, a GoalApp) string {
	parts := titleParts.Split(title, -1)
	if len(parts) < 2 {
		return title
	}
	last := strings.ToLower(parts[len(parts)-1])
	names := []string{strings.ToLower(a.Name), strings.ToLower(a.App)}
	if a.Host != nil {
		if labels := strings.Split(*a.Host, "."); len(labels) >= 2 {
			names = append(names, labels[len(labels)-2])
		}
	}
	for _, name := range names {
		if name != "" && strings.Contains(last, name) {
			return strings.Join(parts[:len(parts)-1], " - ")
		}
	}
	return title
}

// telling: the titles that say something beyond the app's or site's own name.
func telling(titles []string, a GoalApp) []string {
	plain := map[string]bool{strings.ToLower(a.App): true, strings.ToLower(a.Name): true}
	if a.Host != nil {
		plain[*a.Host] = true
		if labels := strings.Split(*a.Host, "."); len(labels) >= 2 {
			plain[labels[len(labels)-2]] = true
		}
	}
	var out []string
	for _, t := range titles {
		if !plain[strings.ToLower(t)] && strings.IndexFunc(t, func(r rune) bool { return unicode.IsLetter(r) }) >= 0 {
			out = append(out, t)
		}
	}
	return out
}

// filesIn: the file names in an editor's titles, in order, each once.
func filesIn(titles []string) []string {
	var files []string
	for _, t := range titles {
		for _, part := range titleParts.Split(t, -1) {
			for _, word := range strings.Fields(part) {
				if word = strings.Trim(word, `,;:()[]"'`); fileName.MatchString(word) {
					files = append(files, word)
				}
			}
		}
	}
	return distinct(files)
}

// commandsIn: what ran in a terminal: the part of each title that reads as a command (not a shell, a prompt or a path).
func commandsIn(titles []string) []string {
	var commands []string
	for _, t := range titles {
		for _, part := range titleParts.Split(leadingMarks.ReplaceAllString(t, ""), -1) {
			words := strings.Fields(part)
			if len(words) == 0 {
				continue
			}
			part, first := strings.Join(words, " "), words[0]
			if command.MatchString(part) && !shells[strings.TrimPrefix(first, "-")] && !strings.Contains(first, "@") {
				commands = append(commands, Clip(part, 32))
				break
			}
		}
	}
	return distinct(commands)
}

func distinct(items []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, it := range items {
		if it = Trim(it); it != "" && !seen[strings.ToLower(it)] {
			seen[strings.ToLower(it)] = true
			out = append(out, it)
		}
	}
	return out
}

// listed: "A", "A and B", or "A, B and 3 more files".
func listed(items []string, kind string) string {
	switch {
	case len(items) == 1:
		return items[0]
	case len(items) <= stepObjects:
		return strings.Join(items[:len(items)-1], ", ") + " and " + items[len(items)-1]
	}
	return strings.Join(items[:stepObjects], ", ") + fmt.Sprintf(" and %d more %s", len(items)-stepObjects, kind)
}

// ── Past tense ──────────────────────────────────────────────────────────────────────────────────────────────────

var irregularPast = map[string]string{
	"reading": "read", "writing": "wrote", "rewriting": "rewrote", "building": "built", "rebuilding": "rebuilt", "making": "made",
	"running": "ran", "doing": "did", "thinking": "thought", "buying": "bought", "setting": "set", "getting": "got", "taking": "took",
	"sending": "sent", "speaking": "spoke", "seeing": "saw", "paying": "paid", "putting": "put", "giving": "gave", "finding": "found",
	"teaching": "taught", "spending": "spent", "leading": "led", "drawing": "drew", "choosing": "chose", "hearing": "heard",
	"telling": "told", "selling": "sold", "keeping": "kept", "understanding": "understood", "breaking": "broke", "bringing": "brought",
	"catching": "caught", "feeling": "felt", "holding": "held", "laying": "laid", "leaving": "left", "letting": "let", "losing": "lost",
	"going": "went", "coming": "came", "beginning": "began", "having": "had", "saying": "said", "standing": "stood", "knowing": "knew",
	"seeking": "sought", "shooting": "shot", "splitting": "split", "spreading": "spread", "sweeping": "swept", "cutting": "cut",
	"meaning": "meant", "sitting": "sat", "winning": "won", "upsetting": "upset", "overseeing": "oversaw",
}

// gerundNouns: words in "-ing" that start an activity as a noun, not a verb ("onboarding flow", "meeting notes").
var gerundNouns = map[string]bool{
	"onboarding": true, "marketing": true, "branding": true, "pricing": true, "billing": true, "hiring": true, "funding": true,
	"meeting": true, "morning": true, "evening": true, "string": true, "thing": true, "something": true, "nothing": true,
	"anything": true, "everything": true, "networking": true, "accounting": true, "banking": true, "housing": true, "spring": true,
	"wedding": true, "ceiling": true, "during": true, "king": true, "ring": true, "ping": true, "sing": true, "wing": true,
}

// pastTense: Moku's words for the work as a step, "configuring MCP" → "configured MCP". Anything that doesn't start
// with a verb in "-ing" stays as it is.
func pastTense(activity string) string {
	words := strings.SplitN(activity, " ", 2)
	verb := strings.ToLower(words[0])
	if verb != words[0] || !strings.HasSuffix(verb, "ing") || len(verb) < 5 || gerundNouns[verb] {
		return activity
	}
	past, ok := irregularPast[verb]
	if !ok {
		stem := strings.TrimSuffix(verb, "ing")
		last := stem[len(stem)-1]
		switch {
		case last == 'y' && !strings.ContainsRune("aeiou", rune(stem[len(stem)-2])):
			past = stem[:len(stem)-1] + "ied"
		case last == 'e':
			past = stem + "d"
		default:
			past = stem + "ed"
		}
	}
	words[0] = past
	return strings.Join(words, " ")
}
