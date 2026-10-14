package brain

import (
	"encoding/json"
	"regexp"
	"slices"
	"strings"
)

// EvaluationQuestion is one Jev question: a bounded choice (criteria are the options) or a yes/no probability.
type EvaluationQuestion struct {
	Type         string `json:"type"`
	Instructions string `json:"instructions"`
	Criteria     OMap   `json:"criteria,omitempty"`
}

// Questions for Jev are a map in insertion order (JavaScript objects keep it; the request body shows it).
type QuestionSet = OMap

const noneChoice = "none"

// threadQuestion: which of the person's threads this screen belongs to (thread ids are the choices).
func threadQuestion(threads []ThreadRow) EvaluationQuestion {
	var criteria OMap
	for _, t := range threads {
		criteria = criteria.Set(t.ID, t.Title+": "+t.Summary)
	}
	criteria = criteria.Set(noneChoice, Questions.ThreadNone)
	return EvaluationQuestion{Type: "choice", Instructions: Questions.ThreadInstructions, Criteria: criteria}
}

var kindQuestion = EvaluationQuestion{Type: "choice", Instructions: Questions.KindInstructions, Criteria: Questions.KindCriteria}

func categoryQuestion() EvaluationQuestion {
	return EvaluationQuestion{Type: "choice", Instructions: Questions.CategoryInstructions, Criteria: append(append(OMap{}, Rules.Category.Focus...), Rules.Category.Drift...)}
}

func completionQuestion(p CompletionPattern) EvaluationQuestion {
	return EvaluationQuestion{Type: "boolean", Instructions: completionInstructions(p.What)}
}

func threadCategoryQuestion() EvaluationQuestion {
	return EvaluationQuestion{Type: "choice", Instructions: Questions.ThreadCategoryInstructions, Criteria: append(OMap{}, Rules.Category.Focus...)}
}

// EvaluationAnswer is one of Jev's answers: a choice (with its distribution, when given) or P(true).
type EvaluationAnswer struct {
	Type          string             `json:"type"`
	Choice        string             `json:"choice,omitempty"`
	Probabilities map[string]float64 `json:"probabilities,omitempty"`
	Probability   *float64           `json:"probability,omitempty"`
	// ProbabilityOrder keeps the distribution's keys as Jev sent them (for the stored call).
	order []string
}

// MarshalJSON writes the answer as Jev sent it: the distribution's keys in their order.
func (a EvaluationAnswer) MarshalJSON() ([]byte, error) {
	out := OMap{{"type", a.Type}}
	if a.Type == "boolean" {
		if a.Probability != nil {
			out = append(out, KV{"probability", *a.Probability})
		}
	} else {
		out = append(out, KV{"choice", a.Choice})
		if a.Probabilities != nil {
			var dist OMap
			for _, k := range a.order {
				dist = append(dist, KV{k, a.Probabilities[k]})
			}
			out = append(out, KV{"probabilities", dist})
		}
	}
	return out.MarshalJSON()
}

func (a *EvaluationAnswer) UnmarshalJSON(data []byte) error {
	type plain EvaluationAnswer
	var p plain
	if err := json.Unmarshal(data, &p); err != nil {
		return err
	}
	*a = EvaluationAnswer(p)
	var raw struct {
		Probabilities json.RawMessage `json:"probabilities"`
	}
	if json.Unmarshal(data, &raw) == nil && len(raw.Probabilities) > 0 {
		var m map[string]any
		if json.Unmarshal(raw.Probabilities, &m) == nil {
			a.order = ordered(raw.Probabilities, m)
		}
	}
	return nil
}

// Answers keep Jev's key order too.
type Answers struct {
	byID  map[string]EvaluationAnswer
	order []string
}

func (a Answers) Get(id string) (EvaluationAnswer, bool) { v, ok := a.byID[id]; return v, ok }

func (a Answers) MarshalJSON() ([]byte, error) {
	var out OMap
	for _, k := range a.order {
		out = append(out, KV{k, a.byID[k]})
	}
	if out == nil {
		return []byte("{}"), nil
	}
	return out.MarshalJSON()
}

// choiceOf: the chosen option and its probability ("" when the question wasn't answered).
func (a Answers) choiceOf(id string) (choice string, p float64, ok bool) {
	ans, found := a.byID[id]
	if !found {
		return "", 0, false
	}
	return ans.Choice, ans.Probabilities[ans.Choice], true
}

// ── Learned rules ───────────────────────────────────────────────────────────────────────────────────────────────

// Scope is where a learned rule applies: app and host, and on content sites the page (by title or path prefix).
type Scope struct {
	BundleID   string  `json:"bundleId"`
	AppName    string  `json:"appName"`
	Host       *string `json:"host"`
	PathPrefix *string `json:"pathPrefix"`
	Title      *string `json:"title"`
}

func scopeOf(s Screen) Scope {
	host := siteOf(s.URL)
	base := Scope{BundleID: s.BundleID, AppName: s.AppName, Host: host}
	if host == nil {
		base.Title = ptr(pageTitle(s, nil))
		return base
	}
	switch contentScope(*host) {
	case "title":
		base.Title = ptr(pageTitle(s, host))
	case "path":
		base.PathPrefix = ptr(pathPrefix(learnedPath(s.URL)))
	}
	return base
}

// findLearnedRule: the newest, most specific active rule that covers this screen, if any.
func findLearnedRule(store *Store, s Screen) *LearnedRuleRow {
	host := siteOf(s.URL)
	path := learnedPath(s.URL)
	title := pageTitle(s, host)
	var matching []LearnedRuleRow
	for _, r := range store.LearnedRulesFor(s.BundleID, host) {
		if (r.PathPrefix == nil || coversPath(*r.PathPrefix, path)) && (r.Title == nil || *r.Title == title) {
			matching = append(matching, r)
		}
	}
	if len(matching) == 0 {
		return nil
	}
	slices.SortStableFunc(matching, func(a, b LearnedRuleRow) int {
		if d := specificity(b) - specificity(a); d != 0 {
			return d
		}
		if b.CreatedAt != a.CreatedAt {
			return cmpInt64(b.CreatedAt, a.CreatedAt)
		}
		return cmpInt64(b.ID, a.ID)
	})
	return &matching[0]
}

func cmpInt64(a, b int64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

type lesson struct {
	Screen   Screen
	Effect   string
	ThreadID *string
	Source   string
	SampleID *string
	At       int64
}

// learn records what the person taught, replacing any earlier rule with exactly the same scope.
func learn(store *Store, l lesson) *LearnedRuleRow {
	scope := scopeOf(l.Screen)
	for _, old := range store.LearnedRulesFor(scope.BundleID, scope.Host) {
		if eqStr(old.PathPrefix, scope.PathPrefix) && eqStr(old.Title, scope.Title) {
			store.RemoveLearnedRule(old.ID, l.At)
		}
	}
	return store.InsertLearnedRule(LearnedRuleRow{
		BundleID: scope.BundleID, AppName: scope.AppName, Host: scope.Host, PathPrefix: scope.PathPrefix, Title: scope.Title,
		Effect: l.Effect, ThreadID: l.ThreadID, Source: l.Source, SampleID: l.SampleID, CreatedAt: l.At,
	})
}

// describeScope: "linkedin.com/feed", "youtube.com: morris traversal explained…", "Telegram: dsa study group".
func describeScope(appName string, host, pathPrefix, title *string) string {
	place := appName
	if host != nil {
		place = *host
		if pathPrefix != nil && *pathPrefix != "/" {
			place += *pathPrefix
		}
	}
	if title != nil && *title != "" {
		return place + ": " + Clip(*title, 60)
	}
	return place
}

func (s Scope) describe() string { return describeScope(s.AppName, s.Host, s.PathPrefix, s.Title) }
func (r LearnedRuleRow) describe() string { return describeScope(r.AppName, r.Host, r.PathPrefix, r.Title) }

// pageTitle: the normalized window title, without the site's own name ("… - YouTube" → "…").
func pageTitle(s Screen, host *string) string {
	title := normalizeTitle(s.Title, s.AppName)
	if host == nil {
		return title
	}
	parts := strings.Split(*host, ".")
	siteName := ""
	if len(parts) >= 2 {
		siteName = parts[len(parts)-2]
	} else {
		siteName = parts[0]
	}
	if siteName == "" {
		return title
	}
	return regexp.MustCompile(jsSpace+`+[-|–—·/]`+jsSpace+`+`+regexp.QuoteMeta(siteName)+`$`).ReplaceAllString(title, "")
}

func specificity(r LearnedRuleRow) int {
	n := 0
	if r.Title != nil {
		n += 1000
	}
	if r.PathPrefix != nil {
		n += Len16(*r.PathPrefix)
	}
	return n
}

// contentScope: youtube.com, m.youtube.com and old.reddit.com resolve to their content-site entry.
func contentScope(host string) string {
	for h := host; strings.Contains(h, "."); h = h[strings.Index(h, ".")+1:] {
		if by, ok := Rules.Learned.ContentSites[h]; ok {
			return by
		}
	}
	return ""
}

// learnedPath: the path without a trailing slash, "/" for none (and for a URL that doesn't parse).
func learnedPath(raw *string) string {
	if raw == nil {
		return "/"
	}
	u := parseAnyURL(*raw)
	if u == "" {
		return "/"
	}
	p := trailingSlashes.ReplaceAllString(u, "")
	if p == "" {
		return "/"
	}
	return p
}

func pathPrefix(path string) string {
	var segments []string
	for _, s := range strings.Split(path, "/") {
		if s != "" {
			segments = append(segments, s)
		}
	}
	if len(segments) > Rules.Learned.PathSegments {
		segments = segments[:Rules.Learned.PathSegments]
	}
	if len(segments) == 0 {
		return "/"
	}
	return "/" + strings.Join(segments, "/")
}

// coversPath: "/feed" covers "/feed" and "/feed/update/1", not "/feedback"; "/" covers only the root page.
func coversPath(prefix, path string) bool {
	if prefix == "/" {
		return path == "/"
	}
	return path == prefix || strings.HasPrefix(path, prefix+"/")
}
