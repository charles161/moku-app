package brain

import (
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"math"
	"net/http"
	"regexp"
	"slices"
	"sort"
	"strings"
)

// Charles's calibration of goal-aware judging (docs/specs/goal-aware-judging.md, "Calibration"), in his calibration
// build only (MOKU_CALIBRATE=1): a page the brain serves at http://127.0.0.1:8020/calibrate. It's local: nothing on
// it leaves the Mac.
//
// He rates moments, not samples. A moment is a run of time on one window with one answer, e.g. "14:02–14:09 · Chrome ·
// Two Sum – LeetCode → practicing coding problems". ✓ or ✗, and on ✗ what it really was: one of his goals or a new one
// (typed), a drift, or personal but fine. About 5 minutes a day: every drift, switch and new goal is shown, plus a
// random fifth of the rest; "Show all" shows everything. The scores are the spec's exit bar, per day and overall,
// with calibration (of the calls made at p ≈ 0.8, are about 80% right?) and the worst apps and sites. His ratings are
// the test set the replay tool scores new rules and prompts against (cmd/moku-replay).

const (
	momentGapMs      = 2 * minute // a longer silence between verdicts ends a moment
	momentTailMs     = minute     // a moment's last verdict covers at most this
	momentShownMinMs = 20_000     // shorter moments show only with "Show all"
	onGoalShownOneIn = 5          // a random fifth of the other moments are shown
)

// Moment: a run of time on one window (a site, or an app) with one answer. Away, a meeting or a neutral app for less
// than momentGapMs pauses it; the same answer after that carries on.
type Moment struct {
	ID    string `json:"id"` // its first sample's id
	Start int64  `json:"start"`
	End   int64  `json:"end"`
	App   string `json:"app"`
	Place string `json:"place"` // the site, or else the app
	Title string `json:"title"`
	State string `json:"state"` // working or drifting
	// Kind: goal (the current goal), switch (another goal), new (a new goal), unclear (work, no goal sure enough), drift.
	Kind      string   `json:"kind"`
	GoalID    *string  `json:"goalId"`
	GoalTitle *string  `json:"goalTitle"`
	FromGoal  *string  `json:"fromGoal"` // a switch: the goal before
	P         *float64 `json:"p"`        // the probability of what Moku said, when a model said it
	Rule      string   `json:"rule"`
	Nudged    bool     `json:"nudged"` // Moku asked to come back during it
	Shown     bool     `json:"shown"`
	Rating    *Rating  `json:"rating"`
}

// Rating: Charles's ✓ or ✗, and on ✗ what it really was.
type Rating struct {
	OK     bool    `json:"ok"`
	Truth  *string `json:"truth"` // goal, new, drift or personal
	GoalID *string `json:"goalId"`
	Title  *string `json:"title"`
}

var ruleOfReason = regexp.MustCompile(`^\[([\w-]+)\]`)

// moments: the moments in [since, until).
func (b *Brain) moments(since, until int64) []Moment {
	store := b.Store
	titleOf := goalTitles(store)
	created := map[string]int64{}
	createdAt := func(id string) int64 {
		if at, ok := created[id]; ok {
			return at
		}
		at := int64(-1)
		if t := store.Thread(id); t != nil {
			at = t.CreatedAt
		}
		created[id] = at
		return at
	}
	nudges := store.EventTimes("nudged", since, until+momentTailMs)
	within := int64(Rules.Goal.CurrentWithinMinutes) * minute
	var lastGoal *string
	var lastGoalAt int64
	if id, at, ok := store.LastWorkThread(since-1, since-within, ""); ok {
		lastGoal, lastGoalAt = &id, at
	}

	var out []Moment
	var m *Moment
	var key string
	var last, pausedAt int64
	var pSum float64
	var pN int
	anyNew := false
	flush := func(next int64) {
		if m == nil {
			return
		}
		if pausedAt > last {
			next = min(next, pausedAt)
		}
		m.End = max(last, min(last+momentTailMs, next))
		if pN > 0 {
			m.P = ptr(Round(pSum/float64(pN)*100) / 100)
		}
		if anyNew && m.GoalID != nil {
			if at := createdAt(*m.GoalID); at >= m.Start-10_000 && at <= m.End {
				m.Kind, m.FromGoal = "new", nil
			}
		}
		for _, at := range nudges {
			if at >= m.Start && at <= m.End {
				m.Nudged = true
			}
		}
		h := fnv.New32a()
		h.Write([]byte(m.ID))
		picked := m.Kind == "drift" || m.Kind == "switch" || m.Kind == "new" || h.Sum32()%onGoalShownOneIn == 0
		m.Shown = picked && m.End-m.Start >= momentShownMinMs
		out = append(out, *m)
		m, pSum, pN, anyNew = nil, 0, 0, false
	}
	for _, r := range store.CalibrationRows(since, until) {
		// Away, a meeting or a neutral app (unknown) pauses a moment: the same answer within momentGapMs carries on.
		if r.State != "working" && r.State != "drifting" {
			if pausedAt <= last {
				pausedAt = r.TS
			}
			continue
		}
		// One window: the site, or else the app (its title can change, as a show's or a chat's does).
		place := placeOf(Screen{AppName: r.AppName, URL: r.URL})
		k := JSON([]any{r.State, r.ThreadID, r.BundleID, place})
		if m != nil && (k != key || r.TS-last > momentGapMs) {
			flush(r.TS)
		}
		if m == nil {
			rule := ""
			if found := ruleOfReason.FindStringSubmatch(r.Reason); found != nil {
				rule = found[1]
			}
			m = &Moment{ID: r.SampleID, Start: r.TS, App: r.AppName, Place: place, Title: r.Title, State: r.State, Rule: rule}
			switch {
			case r.State == "drifting":
				m.Kind = "drift"
			case r.ThreadID == nil:
				m.Kind = "unclear"
			default:
				m.GoalID, m.GoalTitle, m.Kind = r.ThreadID, ptr(titleOf(*r.ThreadID)), "goal"
				if lastGoal != nil && *lastGoal != *r.ThreadID && r.TS-lastGoalAt <= within {
					m.Kind, m.FromGoal = "switch", ptr(titleOf(*lastGoal))
				}
			}
			key = k
		}
		last = r.TS
		anyNew = anyNew || r.IsNew
		if r.Source == "jev" || r.Source == "local" || strings.HasPrefix(r.Reason, "["+ruleReuse+"]") || strings.HasPrefix(r.Reason, "["+ruleSameScreen+"]") {
			pSum += r.Confidence
			pN++
		}
		if r.State == "working" && r.ThreadID != nil {
			lastGoal, lastGoalAt = r.ThreadID, r.TS
		}
	}
	flush(until)
	return out
}

// ── Scores ──────────────────────────────────────────────────────────────────────────────────────────────────────

// Scores: the spec's success criteria over a set of rated moments. Shares are nil when there's nothing to score.
type Scores struct {
	Rated     int      `json:"rated"`
	Days      int      `json:"days"`
	WorkRated int      `json:"workRated"` // moments that were work (by his rating)
	GoalRight *float64 `json:"goalRight"` // of those, Moku had the right goal
	// Drifts: precision (when Moku said drift, he agreed) and recall (drifts he marked, Moku caught).
	DriftsSaid     int      `json:"driftsSaid"`
	DriftPrecision *float64 `json:"driftPrecision"`
	DriftsTrue     int      `json:"driftsTrue"`
	DriftRecall    *float64 `json:"driftRecall"`
	NudgesOnWork   int      `json:"nudgesOnWork"` // Moku asked to come back during real work
	// Personal but fine: how many, and how many Moku called a drift (the data decides whether it becomes a calm goal).
	Personal          int `json:"personal"`
	PersonalSaidDrift int `json:"personalSaidDrift"`
}

// ratedRight: whether Moku was right about a rated moment (a ✗ that names Moku's own goal counts as right).
func ratedRight(r GoalRating, said Moment) bool {
	if r.OK {
		return true
	}
	return deref(r.Truth) == "goal" && said.State == "working" && said.GoalID != nil && eqStr(r.TruthGoalID, said.GoalID)
}

func share(n, of int) *float64 {
	if of == 0 {
		return nil
	}
	return ptr(Round(float64(n)/float64(of)*1000) / 1000)
}

func scoreRatings(ratings []GoalRating) Scores {
	var s Scores
	var goalRight, precisionRight, recallRight int
	days := map[string]bool{}
	for _, r := range ratings {
		var said Moment
		if json.Unmarshal(r.Said, &said) != nil {
			continue
		}
		s.Rated++
		days[localDate(r.Start)] = true
		right, truth := ratedRight(r, said), deref(r.Truth)
		isWork := (right && said.State == "working") || (!right && (truth == "goal" || truth == "new"))
		isDrift := (right && said.State == "drifting") || (!right && truth == "drift")
		if isWork {
			s.WorkRated++
			if right {
				goalRight++
			}
			if said.Nudged {
				s.NudgesOnWork++
			}
		}
		if said.State == "drifting" {
			s.DriftsSaid++
			if right {
				precisionRight++
			}
		}
		if isDrift {
			s.DriftsTrue++
			if said.State == "drifting" {
				recallRight++
			}
		}
		if !right && truth == "personal" {
			s.Personal++
			if said.State == "drifting" {
				s.PersonalSaidDrift++
			}
		}
	}
	s.Days = len(days)
	s.GoalRight, s.DriftPrecision, s.DriftRecall = share(goalRight, s.WorkRated), share(precisionRight, s.DriftsSaid), share(recallRight, s.DriftsTrue)
	return s
}

// Bin: calibration: of the rated moments Moku said at p in [From, To), how many were right.
type Bin struct {
	From  float64  `json:"from"`
	To    float64  `json:"to"`
	N     int      `json:"n"`
	MeanP *float64 `json:"meanP"`
	Right *float64 `json:"right"`
}

func calibrationBins(ratings []GoalRating) []Bin {
	bins := make([]Bin, 5)
	sums, rights := make([]float64, 5), make([]int, 5)
	for i := range bins {
		bins[i].From, bins[i].To = float64(5+i)/10, float64(6+i)/10
	}
	for _, r := range ratings {
		var said Moment
		if json.Unmarshal(r.Said, &said) != nil || said.P == nil {
			continue
		}
		i := min(4, max(0, int(math.Floor((*said.P-0.5)*10+1e-9)))) // 0.7 is in 0.7–0.8, not 0.6–0.7
		bins[i].N++
		sums[i] += *said.P
		if ratedRight(r, said) {
			rights[i]++
		}
	}
	for i := range bins {
		if bins[i].N > 0 {
			bins[i].MeanP = ptr(Round(sums[i]/float64(bins[i].N)*100) / 100)
			bins[i].Right = share(rights[i], bins[i].N)
		}
	}
	return bins
}

type PlaceScore struct {
	Place string `json:"place"`
	Rated int    `json:"rated"`
	Wrong int    `json:"wrong"`
}

func worstPlaces(ratings []GoalRating, n int) []PlaceScore {
	by := map[string]*PlaceScore{}
	for _, r := range ratings {
		var said Moment
		if json.Unmarshal(r.Said, &said) != nil {
			continue
		}
		p := by[said.Place]
		if p == nil {
			p = &PlaceScore{Place: said.Place}
			by[said.Place] = p
		}
		p.Rated++
		if !ratedRight(r, said) {
			p.Wrong++
		}
	}
	out := []PlaceScore{}
	for _, p := range by {
		if p.Wrong > 0 {
			out = append(out, *p)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Wrong != out[j].Wrong {
			return out[i].Wrong > out[j].Wrong
		}
		return out[i].Place < out[j].Place
	})
	return out[:min(n, len(out))]
}

// JevPurposes: every Jev call that judging and labeling make.
var JevPurposes = []string{"judge", "label", "category", "completion", "goal", "dedupe"}

// Cost: Jev's cost per active hour before goal-aware judging (the week before its first goal call) and since.
type Cost struct {
	Since         int64    `json:"since"` // the first goal call, 0 before any
	BeforePerHour *float64 `json:"beforePerHour"`
	NowPerHour    *float64 `json:"nowPerHour"`
	Ratio         *float64 `json:"ratio"`
	// Speed: Jev's latency in ms (p50, p90; the slowest now), before (judge calls) and since (goal calls).
	BeforeP50 int64 `json:"beforeP50"`
	BeforeP90 int64 `json:"beforeP90"`
	NowP50    int64 `json:"nowP50"`
	NowP90    int64 `json:"nowP90"`
	NowMax    int64 `json:"nowMax"`
}

func quantile(ms []int64, q float64) int64 {
	if len(ms) == 0 {
		return 0
	}
	sorted := slices.Clone(ms)
	slices.Sort(sorted)
	return sorted[min(len(sorted)-1, int(math.Ceil(q*float64(len(sorted))))-1)]
}

func (b *Brain) cost(now int64) Cost {
	store := b.Store
	first := store.FirstCall("goal")
	before := Window{now - 7*24*60*minute, now}
	if first > 0 {
		before = Window{first - 7*24*60*minute, first}
	}
	perHour := func(w Window) *float64 {
		cost, _ := store.CallStats(w.Start, w.End, JevPurposes)
		active := store.ActiveMs(w.Start, w.End)
		if active == 0 {
			return nil
		}
		return ptr(cost / (float64(active) / 3_600_000))
	}
	c := Cost{Since: first, BeforePerHour: perHour(before)}
	_, beforeMs := store.CallStats(before.Start, before.End, []string{"judge"})
	c.BeforeP50, c.BeforeP90 = quantile(beforeMs, 0.5), quantile(beforeMs, 0.9)
	if first > 0 {
		c.NowPerHour = perHour(Window{first, now + 1})
		_, nowMs := store.CallStats(first, now+1, []string{"goal"})
		c.NowP50, c.NowP90, c.NowMax = quantile(nowMs, 0.5), quantile(nowMs, 0.9), quantile(nowMs, 1)
		if c.NowPerHour != nil && c.BeforePerHour != nil && *c.BeforePerHour > 0 {
			c.Ratio = ptr(Round(*c.NowPerHour / *c.BeforePerHour * 1000) / 1000)
		}
	}
	return c
}

// BarLine: one of the spec's exit criteria, with where it stands.
type BarLine struct {
	What   string `json:"what"`
	Target string `json:"target"`
	Value  string `json:"value"`
	Pass   bool   `json:"pass"`
}

func percent(p *float64) string {
	if p == nil {
		return "–"
	}
	return fmt.Sprintf("%.0f%%", *p*100)
}

func atLeast(p *float64, min float64) bool { return p != nil && *p >= min }

func exitBar(s Scores, c Cost) []BarLine {
	ratio := "no goal calls yet"
	if c.Ratio != nil {
		ratio = fmt.Sprintf("%.0f%% of before", *c.Ratio*100)
	}
	speed := fmt.Sprintf("p90 %.1f s (before %.1f s)", float64(c.NowP90)/1000, float64(c.BeforeP90)/1000)
	return []BarLine{
		{"Rated moments", "200 or more, over 3 or more days", fmt.Sprintf("%d over %d days", s.Rated, s.Days), s.Rated >= 200 && s.Days >= 3},
		{"Goal right", "90% or more of work moments", percent(s.GoalRight) + fmt.Sprintf(" of %d", s.WorkRated), atLeast(s.GoalRight, 0.9)},
		{"Drift precision", "90% or more", percent(s.DriftPrecision) + fmt.Sprintf(" of %d", s.DriftsSaid), atLeast(s.DriftPrecision, 0.9)},
		{"Drift recall", "85% or more", percent(s.DriftRecall) + fmt.Sprintf(" of %d", s.DriftsTrue), atLeast(s.DriftRecall, 0.85)},
		{"Nudges on real work", "none", fmt.Sprint(s.NudgesOnWork), s.NudgesOnWork == 0 && s.Rated > 0},
		{"Jev cost per active hour", "60% of before or less", ratio, c.Ratio != nil && *c.Ratio <= 0.6},
		{"Verdicts as fast as before", "p90 within 20% of before, under 7 s", speed,
			c.NowP90 > 0 && c.NowMax < 7_000 && float64(c.NowP90) <= 1.2*float64(max(c.BeforeP90, 1))},
	}
}

// Report: everything the dashboard scores, over every rating so far.
type Report struct {
	Overall Scores       `json:"overall"`
	Days    []DayScores  `json:"days"`
	Bins    []Bin        `json:"bins"`
	Worst   []PlaceScore `json:"worst"`
	Cost    Cost         `json:"cost"`
	Bar     []BarLine    `json:"bar"`
}

type DayScores struct {
	Date string `json:"date"`
	Scores
}

func (b *Brain) calibrationReport() Report {
	ratings := b.Store.GoalRatings(0, MaxSafeInteger)
	byDay := map[string][]GoalRating{}
	var dates []string
	for _, r := range ratings {
		d := localDate(r.Start)
		if byDay[d] == nil {
			dates = append(dates, d)
		}
		byDay[d] = append(byDay[d], r)
	}
	days := []DayScores{}
	for _, d := range dates {
		days = append(days, DayScores{Date: d, Scores: scoreRatings(byDay[d])})
	}
	overall, cost := scoreRatings(ratings), b.cost(b.now())
	return Report{Overall: overall, Days: days, Bins: calibrationBins(ratings), Worst: worstPlaces(ratings, 8), Cost: cost, Bar: exitBar(overall, cost)}
}

// ── The day's moments and goals ─────────────────────────────────────────────────────────────────────────────────

type CalibrationDay struct {
	Date    string       `json:"date"`
	Moments []Moment     `json:"moments"`
	Goals   []GoalOption `json:"goals"`
	Shown   int          `json:"shown"`
	Rated   int          `json:"rated"`
}

// GoalOption: a goal he can pick, rename, merge or mark as not a real goal.
type GoalOption struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Summary string `json:"summary"`
	Minutes int64  `json:"minutes"` // on this day, from its moments
}

func (b *Brain) calibrationDay(date string, all bool) (CalibrationDay, error) {
	w, ok := dayWindow(date)
	if !ok {
		return CalibrationDay{}, &RangeError{"date must be YYYY-MM-DD"}
	}
	ratings := map[string]GoalRating{}
	for _, r := range b.Store.GoalRatings(w.Start, w.End) {
		ratings[r.MomentID] = r
	}
	day := CalibrationDay{Date: date, Moments: []Moment{}, Goals: []GoalOption{}}
	minutes := map[string]int64{}
	for _, m := range b.moments(w.Start, w.End) {
		if m.GoalID != nil {
			minutes[*m.GoalID] += m.End - m.Start
		}
		if r, rated := ratings[m.ID]; rated {
			m.Rating = &Rating{OK: r.OK, Truth: r.Truth, GoalID: r.TruthGoalID, Title: r.TruthTitle}
			day.Rated++
		}
		if m.Shown {
			day.Shown++
		}
		if all || m.Shown || m.Rating != nil {
			day.Moments = append(day.Moments, m)
		}
	}
	for _, t := range b.Store.Threads(w.Start-int64(Rules.Goal.ActiveWithinDays)*24*60*minute, 60) {
		day.Goals = append(day.Goals, GoalOption{ID: t.ID, Title: t.Title, Summary: t.Summary, Minutes: roundMinutes(minutes[t.ID])})
	}
	sort.SliceStable(day.Goals, func(i, j int) bool { return day.Goals[i].Minutes > day.Goals[j].Minutes })
	return day, nil
}

// rateMoment stores his rating of a moment, with what Moku said then.
func (b *Brain) rateMoment(date, momentID string, rating Rating) error {
	w, ok := dayWindow(date)
	if !ok {
		return &RangeError{"date must be YYYY-MM-DD"}
	}
	for _, m := range b.moments(w.Start, w.End) {
		if m.ID != momentID {
			continue
		}
		m.Rating, m.Shown = nil, false
		said, _ := json.Marshal(m)
		b.Store.SetGoalRating(GoalRating{MomentID: m.ID, Start: m.Start, End: m.End, Said: said, OK: rating.OK, Truth: rating.Truth,
			TruthGoalID: rating.GoalID, TruthTitle: rating.Title, RatedAt: b.now()})
		return nil
	}
	return errNoMoment
}

var errNoMoment = fmt.Errorf("no such moment")

// ── HTTP ────────────────────────────────────────────────────────────────────────────────────────────────────────

//go:embed calibrate.html
var calibratePage string

// calibrationOrigin: the dashboard's own origin. Its requests are the only ones with an Origin the brain accepts.
func calibrationOrigin(r *http.Request, port int) bool {
	origin := r.Header.Get("Origin")
	return strings.HasPrefix(r.URL.Path, "/calibrate") &&
		(origin == fmt.Sprintf("http://127.0.0.1:%d", port) || origin == fmt.Sprintf("http://localhost:%d", port))
}

type rateBody struct {
	Date     string  `json:"date"`
	MomentID string  `json:"momentId"`
	OK       *bool   `json:"ok"`
	Truth    *string `json:"truth"`
	GoalID   *string `json:"goalId"`
	Title    *string `json:"title"`
}

type goalBody struct {
	ID        string  `json:"id"`
	Title     *string `json:"title"`
	MergeInto *string `json:"mergeInto"`
	NotAGoal  bool    `json:"notAGoal"`
}

// serveCalibration answers /calibrate and its API. Only a calibrating brain serves it; the caller checks.
func (b *Brain) serveCalibration(w http.ResponseWriter, r *http.Request, body []byte) {
	w.Header().Set("x-content-type-options", "nosniff")
	w.Header().Set("cache-control", "no-store")
	w.Header().Set("referrer-policy", "no-referrer")
	path, method := r.URL.Path, r.Method
	bad := func(msg string) { errorJSON(w, 400, msg) }
	switch {
	case method == "GET" && path == "/calibrate":
		var nonce [16]byte
		rand.Read(nonce[:])
		n := base64.StdEncoding.EncodeToString(nonce[:])
		w.Header().Set("content-type", "text/html; charset=utf-8")
		w.Header().Set("x-frame-options", "DENY")
		w.Header().Set("content-security-policy", "default-src 'none'; script-src 'nonce-"+n+"'; style-src 'nonce-"+n+"'; connect-src 'self'; "+
			"img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
		w.WriteHeader(200)
		io.WriteString(w, strings.ReplaceAll(calibratePage, "{{nonce}}", n))

	case method == "GET" && path == "/calibrate/day":
		date := r.URL.Query().Get("date")
		if date == "" {
			date = localDate(b.now())
		}
		day, err := locked2(b, func() (CalibrationDay, error) { return b.calibrationDay(date, r.URL.Query().Get("all") == "1") })
		if err != nil {
			bad(err.Error())
			return
		}
		writeJSON(w, 200, day)

	case method == "GET" && path == "/calibrate/report":
		writeJSON(w, 200, locked(b, b.calibrationReport))

	case method == "POST" && path == "/calibrate/rate":
		var in rateBody
		if json.Unmarshal(body, &in) != nil || in.MomentID == "" || in.OK == nil {
			bad("momentId, date and ok are needed")
			return
		}
		rating := Rating{OK: *in.OK}
		if !*in.OK {
			truth := deref(in.Truth)
			if !slices.Contains([]string{"goal", "new", "drift", "personal"}, truth) {
				bad("truth must be goal, new, drift or personal")
				return
			}
			rating.Truth = &truth
			switch truth {
			case "goal":
				if in.GoalID == nil || locked(b, func() *ThreadRow { return b.Store.Thread(*in.GoalID) }) == nil {
					bad("no such goal")
					return
				}
				rating.GoalID = in.GoalID
			case "new":
				title := Trim(OneLine(deref(in.Title)))
				if Len16(title) < 1 || Len16(title) > PersonTitleMax {
					bad("a new goal needs a title of 1 to 60 characters")
					return
				}
				rating.Title = &title
			}
		}
		if err := locked(b, func() error { return b.rateMoment(in.Date, in.MomentID, rating) }); err != nil {
			errorJSON(w, 404, err.Error())
			return
		}
		writeJSON(w, 200, OMap{{"ok", true}})

	case method == "POST" && path == "/calibrate/unrate":
		var in rateBody
		if json.Unmarshal(body, &in) != nil || in.MomentID == "" {
			bad("momentId is needed")
			return
		}
		writeJSON(w, 200, OMap{{"ok", locked(b, func() bool { return b.Store.DeleteGoalRating(in.MomentID) })}})

	case method == "POST" && path == "/calibrate/goal":
		var in goalBody
		if json.Unmarshal(body, &in) != nil || in.ID == "" {
			bad("id is needed")
			return
		}
		b.Lock()
		defer b.Unlock()
		now := b.now()
		switch {
		case in.Title != nil:
			title := Trim(OneLine(*in.Title))
			if Len16(title) < 1 || Len16(title) > PersonTitleMax || !b.retitleByPerson(in.ID, title) {
				bad("no such goal, or a title that isn't 1 to 60 characters")
				return
			}
			b.Store.RecordGoalEdit(now, "rename", in.ID, nil, &title)
		case in.MergeInto != nil:
			if !b.Store.MergeThread(in.ID, *in.MergeInto) {
				bad("both goals must exist and differ")
				return
			}
			b.merged[in.ID] = *in.MergeInto
			b.Store.RecordGoalEdit(now, "merge", in.ID, in.MergeInto, nil)
		case in.NotAGoal:
			goal := b.Store.Thread(in.ID)
			if goal == nil {
				bad("no such goal")
				return
			}
			b.Store.ForgetThread(in.ID)
			b.Store.RecordGoalEdit(now, "notAGoal", in.ID, nil, &goal.Title)
		default:
			bad("title, mergeInto or notAGoal")
			return
		}
		writeJSON(w, 200, OMap{{"ok", true}})

	default:
		errorJSON(w, 404, "not found")
	}
}
