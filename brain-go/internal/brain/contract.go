package brain

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"slices"
	"strings"
)

// The wire contract between the Mac app and the brain (http://127.0.0.1:8020). Mirrors
// app/MokuKit/Sources/MokuKit/{Perception,Brain}.swift: camelCase keys, dates as epoch
// milliseconds. Numbers the schema calls integers arrive as float64 and are checked to be whole.

var (
	VerdictStates      = []string{"working", "drifting", "away", "meeting", "unknown"}
	ActivityCategories = []string{"building", "learning", "working", "communicating", "career", "watching", "scrolling", "chatting", "reading", "shopping", "playing", "other"}
	CompletionKinds    = []string{"codePushed", "testsPassed", "prMerged", "problemAccepted", "deployed", "messageSent", "documentShipped", "other"}
	VerdictSources     = []string{"shortcut", "jev", "local", "override", "fallback"}
	VoiceKinds         = []string{"nudge", "callName", "remindFocus", "comeOn", "welcomeBack", "celebrate", "proud", "water", "stretch", "lookAway", "walk", "greeting"}
	FeedbackKinds      = []string{"pat", "returnedAfterNudge", "ignoredNudge", "markedWork", "markedNotWork"}
	EventTypes         = []string{"focusGrowth", "returnGrowth", "shortDrift", "longDriftStarted", "nudged", "approached", "calledName", "annoyed", "returned", "celebrated", "breakSuggested", "patted", "milestone", "completed", "breakStarted", "breakEnded"}
	CallErrorKinds     = []string{"timeout", "schema", "provider", "aborted", "credentials"}
)

type AppInfo struct {
	BundleID string `json:"bundleId"`
	Name     string `json:"name"`
}

type WindowInfo struct {
	Title string  `json:"title"`
	URL   *string `json:"url"`
}

type InputActivity struct {
	KeysPerMinute    float64 `json:"keysPerMinute"`
	ClicksPerMinute  float64 `json:"clicksPerMinute"`
	ScrollsPerMinute float64 `json:"scrollsPerMinute"`
	IdleSeconds      float64 `json:"idleSeconds"`
}

type MeetingContext struct {
	InCall        bool `json:"inCall"`
	SharingScreen bool `json:"sharingScreen"`
	MicInUse      bool `json:"micInUse"`
	CameraInUse   bool `json:"cameraInUse"`
}

type ActivitySample struct {
	ID         string         `json:"id"`
	TS         float64        `json:"ts"`
	App        AppInfo        `json:"app"`
	Window     *WindowInfo    `json:"window"`
	Text       *string        `json:"text"`
	TextSource *string        `json:"textSource"`
	TextHash   *string        `json:"textHash"`
	Activity   InputActivity  `json:"activity"`
	Context    MeetingContext `json:"context"`
}

func (s ActivitySample) Ts() int64 { return int64(s.TS) }

type ThreadRef struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Provisional bool   `json:"provisional"`
}

type Completion struct {
	Kind  string `json:"kind"`
	Label string `json:"label"`
}

type Verdict struct {
	SampleID    string      `json:"sampleId"`
	State       string      `json:"state"`
	Thread      *ThreadRef  `json:"thread"`
	IsNewThread bool        `json:"isNewThread"`
	Confidence  float64     `json:"confidence"`
	Source      string      `json:"source"`
	Reason      string      `json:"reason"`
	LatencyMs   int64       `json:"latencyMs"`
	Activity    *string     `json:"activity"`
	Completion  *Completion `json:"completion"`
	Category    *string     `json:"category"`
	// Goal-aware judging only (nil and false otherwise). Goal: the goal this work serves (the same thread as Thread).
	// Switch: working, but on another goal than the current one (or a new one): calm, never a nudge.
	Goal   *ThreadRef `json:"goal"`
	Switch bool       `json:"switch"`
}

type ThreadSummary struct {
	ID                string  `json:"id"`
	Title             string  `json:"title"`
	Summary           string  `json:"summary"`
	FocusMinutesToday int64   `json:"focusMinutesToday"`
	FocusMinutesTotal int64   `json:"focusMinutesTotal"`
	LastActiveAt      int64   `json:"lastActiveAt"`
	Category          *string `json:"category"`
}

type VoiceRequest struct {
	Kind              string   `json:"kind"`
	UserName          string   `json:"userName"`
	ThreadTitle       *string  `json:"threadTitle"`
	FocusMinutes      *float64 `json:"focusMinutes"`
	DriftMinutes      *float64 `json:"driftMinutes"`
	Distraction       *string  `json:"distraction"`
	NextUnit          *string  `json:"nextUnit"`
	MinutesToNextUnit *float64 `json:"minutesToNextUnit"`
	CompletionLabel   *string  `json:"completionLabel"`
}

type VoiceLine struct {
	Text   string `json:"text"`
	Source string `json:"source"`
}

type Feedback struct {
	TS         float64  `json:"ts"`
	Kind       string   `json:"kind"`
	SampleID   *string  `json:"sampleId"`
	ThreadID   *string  `json:"threadId"`
	SegmentIDs []string `json:"segmentIds"`
	// Since: a correction from the companion ("This is work" in a drift, "This isn't work"), which names no segment:
	// every moment from then until ts.
	Since *float64 `json:"since"`
}

type CompanionEvent struct {
	TS       float64  `json:"ts"`
	Type     string   `json:"type"`
	ThreadID *string  `json:"threadId"`
	Value    *float64 `json:"value"`
}

type StoneMemory struct {
	ID                    string  `json:"id"`
	TS                    int64   `json:"ts"`
	DriftSeconds          int64   `json:"driftSeconds"`
	From                  string  `json:"from"`
	FollowingFocusMinutes int64   `json:"followingFocusMinutes"`
	ThreadTitle           *string `json:"threadTitle"`
}

type WorldSnapshot struct {
	GrowthPoints             float64         `json:"growthPoints"`
	TodayFocusMinutes        int64           `json:"todayFocusMinutes"`
	TodayReturns             int64           `json:"todayReturns"`
	LongestFocusMinutesToday int64           `json:"longestFocusMinutesToday"`
	Threads                  []ThreadSummary `json:"threads"`
	UnitsToday               int64           `json:"unitsToday"`
	// Stones: the returns since yesterday's midnight (world.go: the world keeps the totals of what came before).
	Stones                   []StoneMemory   `json:"stones"`
	FocusMinutesAllTime      int64           `json:"focusMinutesAllTime"`
}

type DaySegment struct {
	ID       string  `json:"id"`
	Start    int64   `json:"start"`
	End      int64   `json:"end"`
	State    string  `json:"state"`
	App      string  `json:"app"`
	BundleID string  `json:"bundleId"`
	Host     *string `json:"host"`
	ThreadID *string `json:"threadId"`
	Activity *string `json:"activity"`
	Category *string `json:"category"`
}

type ActivityRow struct {
	ID         string   `json:"id"`
	App        string   `json:"app"`
	BundleID   string   `json:"bundleId"`
	Host       *string  `json:"host"`
	Activity   string   `json:"activity"`
	Minutes    int64    `json:"minutes"`
	SegmentIDs []string `json:"segmentIds"`
	Category   *string  `json:"category"`
}

type CategoryTotal struct {
	Category string `json:"category"`
	Minutes  int64  `json:"minutes"`
}

type CompletionMoment struct {
	TS          int64   `json:"ts"`
	Kind        string  `json:"kind"`
	Label       string  `json:"label"`
	ThreadTitle *string `json:"threadTitle"`
}

type TodaySummary struct {
	Date                string             `json:"date"`
	Note                *string            `json:"note"`
	FocusedMinutes      int64              `json:"focusedMinutes"`
	LongestFocusMinutes int64              `json:"longestFocusMinutes"`
	Returns             int64              `json:"returns"`
	UnitsToday          int64              `json:"unitsToday"`
	Segments            []DaySegment       `json:"segments"`
	Built               []ActivityRow      `json:"built"`
	Wandered            []ActivityRow      `json:"wandered"`
	QuickCheckMinutes   int64              `json:"quickCheckMinutes"`
	Comebacks           []StoneMemory      `json:"comebacks"`
	BestComeback        *StoneMemory       `json:"bestComeback"`
	Completions         []CompletionMoment `json:"completions"`
	ByCategory          []CategoryTotal    `json:"byCategory"`
	Goals               []GoalDay          `json:"goals"`
}

// GoalDay: one goal on Your day (goals.go). ID is the thread's, or "other" for work without a goal.
type GoalDay struct {
	ID             string    `json:"id"`
	Title          string    `json:"title"`
	Summary        *string   `json:"summary"`
	Minutes        int64     `json:"minutes"`
	LongestMinutes int64     `json:"longestMinutes"`
	Apps           []GoalApp `json:"apps"`
	Detours        int64     `json:"detours"`
	DetourMinutes  int64     `json:"detourMinutes"`
	DetourPlace    *string   `json:"detourPlace"`
	FirstAt        int64     `json:"firstAt"`
	LastAt         int64     `json:"lastAt"`
	// Workflow: how the work went (workflow.go): its apps in the order the work reached them, each with its minutes,
	// and the detours in between, where they happened.
	Workflow []WorkflowStep `json:"workflow"`
	// Sittings: the separate stretches of the day the goal was worked on (a pause of half an hour or more parts two).
	Sittings int64 `json:"sittings"`
	// Steps: what was done, in plain words, in the order it was done ("edited Today.swift", "ran swift test"). Made
	// on the Mac from the windows' titles, else Moku's words; shown to the person only, never sent anywhere.
	Steps []string `json:"steps"`
}

// WorkflowStep: one link of a goal's workflow. Kind "app" is one of its apps or sites (AppID is the GoalApp's id,
// "app:<bundle id>" or "site:<host>", and Minutes its minutes); kind "detour" is the drifts that left the goal and came
// back to it at that point (Count of them, Minutes in all, most of it at Place).
type WorkflowStep struct {
	Kind    string  `json:"kind"`
	AppID   string  `json:"appId"`
	Minutes int64   `json:"minutes"`
	Count   int64   `json:"count"`
	Place   *string `json:"place"`
}

// GoalApp: an app (or a site, in a browser) a goal used, and what was done there, longest first.
type GoalApp struct {
	App      string  `json:"app"`
	BundleID string  `json:"bundleId"`
	Host     *string `json:"host"`
	// Name: what Your day calls it: the app's name, or the site's ("Stripe docs", "GitHub", else its host).
	Name       string   `json:"name"`
	Minutes    int64    `json:"minutes"`
	Activities []string `json:"activities"`
	// Titles: its windows' titles, longest first (shown to the person only, never sent anywhere).
	Titles     []string `json:"titles"`
	SegmentIDs []string `json:"segmentIds"`
	// FirstAt: when the goal's work first came to it for a minute or more (a quick hop doesn't count).
	FirstAt int64 `json:"firstAt"`
}

type DayTotals struct {
	Date                string `json:"date"`
	FocusedMinutes      int64  `json:"focusedMinutes"`
	LongestFocusMinutes int64  `json:"longestFocusMinutes"`
	Returns             int64  `json:"returns"`
	Lanterns            int64  `json:"lanterns"`
	Pieces              int64  `json:"pieces"`
}

type ModelCounts struct {
	CloudCalls    int64   `json:"cloudCalls"`
	CloudFailures int64   `json:"cloudFailures"`
	LocalCalls    int64   `json:"localCalls"`
	LocalFailures int64   `json:"localFailures"`
	CloudP50Ms    int64   `json:"cloudP50Ms"`
	CloudP90Ms    int64   `json:"cloudP90Ms"`
	LocalP50Ms    int64   `json:"localP50Ms"`
	CostUsd       float64 `json:"costUsd"`
	Errors        OMap    `json:"errors"`
}

type DayCounts struct {
	DayTotals
	Screens        int64       `json:"screens"`
	WatchedMinutes int64       `json:"watchedMinutes"`
	Verdicts       OMap        `json:"verdicts"`
	Sources        OMap        `json:"sources"`
	Feedback       OMap        `json:"feedback"`
	Events         OMap        `json:"events"`
	Models         ModelCounts `json:"models"`
}

type DaysResponse struct {
	FirstDay *string     `json:"firstDay"`
	Days     []DayTotals `json:"days"`
}

// CompanionConfig: every timing in seconds. Field order is the schema's (and so config.json's).
type CompanionConfig struct {
	UserName             string  `json:"userName"`
	SampleIntervalSec    float64 `json:"sampleIntervalSec"`
	AwayAfterIdleSec     float64 `json:"awayAfterIdleSec"`
	ShortDriftMaxSec     float64 `json:"shortDriftMaxSec"`
	AnnoyedAfterSec      float64 `json:"annoyedAfterSec"`
	StandUpAfterSec      float64 `json:"standUpAfterSec"`
	AskAfterSec          float64 `json:"askAfterSec"`
	SmileEverySec        float64 `json:"smileEverySec"`
	DrinkEverySec        float64 `json:"drinkEverySec"`
	ProudAfterSec        float64 `json:"proudAfterSec"`
	BreakAfterSec        float64 `json:"breakAfterSec"`
	EvidenceWindowSec    float64 `json:"evidenceWindowSec"`
	LongAwaySec          float64 `json:"longAwaySec"`
	IgnoredNudgeAfterSec float64 `json:"ignoredNudgeAfterSec"`
	ThreadLabelGapSec    float64 `json:"threadLabelGapSec"`
	TeaBreakMaxSec       float64 `json:"teaBreakMaxSec"`
	GraceSec             float64 `json:"graceSec"`
	// Companion: who keeps the person company (moku or tetsu); the app sets it. Only the day's home's words
	// follow it (its pieces in the notes); nothing about judging does.
	Companion string `json:"companion"`
}

// ConfigKeys in schema order (the drift ladder's four timings are RetiredConfigKeys: they're served, never saved).
var ConfigKeys = []string{"userName", "sampleIntervalSec", "awayAfterIdleSec", "shortDriftMaxSec",
	"smileEverySec", "drinkEverySec", "proudAfterSec", "breakAfterSec", "evidenceWindowSec", "longAwaySec",
	"ignoredNudgeAfterSec", "threadLabelGapSec", "teaBreakMaxSec", "companion"}

// DefaultConfig: the same values as CompanionConfig.standard in MokuKit.
var DefaultConfig = CompanionConfig{
	UserName: "friend", SampleIntervalSec: 3, AwayAfterIdleSec: 300, ShortDriftMaxSec: 120, AnnoyedAfterSec: 60,
	StandUpAfterSec: 240, AskAfterSec: 600, SmileEverySec: 60, DrinkEverySec: 1800, ProudAfterSec: 2700, BreakAfterSec: 3000,
	EvidenceWindowSec: 60, LongAwaySec: 600, IgnoredNudgeAfterSec: 600, ThreadLabelGapSec: 1800, TeaBreakMaxSec: 1200, GraceSec: 1,
	Companion: "moku",
}

// Today's house (assets/src/house_kit.py; the app's DayHouse): a piece per 10 focused minutes, done at 4 hours.
const (
	PointsPerUnit    = 10
	HouseGoalMinutes = 240
)

var HousePieces = []string{
	"the stakes and string", "the stone footings", "the floor joists", "the floor",
	"the corner posts", "the top beams", "the rafters", "the ridge beam",
	"the back wall", "the left wall", "the right wall", "the front wall", "the round door", "the windows",
	"the left roof", "the right roof", "the roof trim", "the chimney",
	"the porch", "the flower boxes", "the porch lamp", "the fence", "the garden", "the finishing touches",
}

// DayHome: what a companion builds each day, with the same 24 pieces in the same order of stages as the cottage
// (assets/world/<id>/layout.json, homes[<id>].names).
type DayHome struct {
	Companion, Kind, Noun string
	Pieces                []string
}

// Companions: who can keep the person company, and their homes.
var Companions = []string{"moku", "tetsu"}

var dayHomes = map[string]DayHome{
	"moku": {Companion: "Moku", Kind: "small bunny", Noun: "house", Pieces: HousePieces},
	"tetsu": {Companion: "Tetsu", Kind: "small desk robot", Noun: "rocket", Pieces: []string{
		"the chalk ring", "the concrete pad", "the hazard stripes", "the launch ring",
		"the gantry legs", "the gantry top", "the crew walkway", "the fuel lines",
		"the engine", "the lower hull", "the upper hull", "the round hatch", "the portholes", "the amber bands",
		"the left fin", "the right fin", "the back fin", "the nose cone",
		"the beacon", "the pad lights", "the countdown clock", "the radio dish", "the mission flag", "the finishing touches",
	}},
}

// HomeOf: the companion's day home; Moku's cottage for anyone else.
func HomeOf(companion string) DayHome {
	if home, ok := dayHomes[companion]; ok {
		return home
	}
	return dayHomes["moku"]
}

// ── Validating bodies (what the zod schemas refuse, refused the same way: 400 with the issues) ─────────────────

type Issue struct {
	Path    string `json:"path"`
	Message string `json:"message"`
}

type checker struct{ issues []Issue }

func (c *checker) fail(path, format string, args ...any) {
	c.issues = append(c.issues, Issue{Path: path, Message: fmt.Sprintf(format, args...)})
}

func join(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}

// decodeAny reads JSON keeping numbers exact.
func decodeAny(body []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, fmt.Errorf("trailing data")
	}
	return v, nil
}

func kindOf(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case string:
		return "string"
	case json.Number:
		return "number"
	case bool:
		return "boolean"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	}
	return "unknown"
}

type field struct {
	c    *checker
	m    map[string]any
	path string
}

func (f field) get(key string) (any, bool) { v, ok := f.m[key]; return v, ok }

// object checks that key holds an object (nullish: absent or null is fine too).
func (f field) object(key string, nullish bool, inner func(field)) {
	v, ok := f.get(key)
	if (!ok || v == nil) && nullish {
		return
	}
	m, isObject := v.(map[string]any)
	if !isObject {
		f.c.fail(join(f.path, key), "Invalid input: expected object, received %s", received(v, ok))
		return
	}
	inner(field{f.c, m, join(f.path, key)})
}

func received(v any, present bool) string {
	if !present {
		return "undefined"
	}
	return kindOf(v)
}

type strRule struct {
	nullish  bool
	min, max int // UTF-16 units; 0 max means none
	pattern  *regexp.Regexp
	oneOf    []string
}

func (f field) str(key string, rule strRule) {
	v, ok := f.get(key)
	if (!ok || v == nil) && rule.nullish {
		return
	}
	s, isString := v.(string)
	path := join(f.path, key)
	if !isString {
		if rule.oneOf != nil {
			f.c.fail(path, "Invalid option: expected one of %s", options(rule.oneOf))
		} else {
			f.c.fail(path, "Invalid input: expected string, received %s", received(v, ok))
		}
		return
	}
	switch {
	case rule.oneOf != nil && !slices.Contains(rule.oneOf, s):
		f.c.fail(path, "Invalid option: expected one of %s", options(rule.oneOf))
	case Len16(s) < rule.min:
		f.c.fail(path, "Too small: expected string to have >=%d characters", rule.min)
	case rule.max > 0 && Len16(s) > rule.max:
		f.c.fail(path, "Too big: expected string to have <=%d characters", rule.max)
	case rule.pattern != nil && !rule.pattern.MatchString(s):
		f.c.fail(path, "Invalid string: must match pattern %s", rule.pattern)
	}
}

func options(values []string) string {
	quoted := make([]string, len(values))
	for i, v := range values {
		quoted[i] = `"` + v + `"`
	}
	return strings.Join(quoted, "|")
}

type numRule struct {
	nullish, integer, nonNegative, positive bool
	min, max                                 *float64
}

func (f field) num(key string, rule numRule) {
	v, ok := f.get(key)
	if (!ok || v == nil) && rule.nullish {
		return
	}
	path := join(f.path, key)
	n, isNumber := v.(json.Number)
	if !isNumber {
		f.c.fail(path, "Invalid input: expected number, received %s", received(v, ok))
		return
	}
	x, err := n.Float64()
	if err != nil || math.IsInf(x, 0) || math.IsNaN(x) {
		f.c.fail(path, "Invalid input: expected number, received number")
		return
	}
	switch {
	case rule.integer && x != math.Trunc(x):
		f.c.fail(path, "Invalid input: expected int, received number")
	case rule.nonNegative && x < 0:
		f.c.fail(path, "Too small: expected number to be >=0")
	case rule.positive && x <= 0:
		f.c.fail(path, "Too small: expected number to be >0")
	case rule.min != nil && x < *rule.min:
		f.c.fail(path, "Too small: expected number to be >=%v", *rule.min)
	case rule.max != nil && x > *rule.max:
		f.c.fail(path, "Too big: expected number to be <=%v", *rule.max)
	}
}

func (f field) boolean(key string) {
	v, ok := f.get(key)
	if _, isBool := v.(bool); !isBool {
		f.c.fail(join(f.path, key), "Invalid input: expected boolean, received %s", received(v, ok))
	}
}

func (f field) strings(key string, nullish bool) {
	v, ok := f.get(key)
	if (!ok || v == nil) && nullish {
		return
	}
	list, isArray := v.([]any)
	if !isArray {
		f.c.fail(join(f.path, key), "Invalid input: expected array, received %s", received(v, ok))
		return
	}
	for i, item := range list {
		if _, isString := item.(string); !isString {
			f.c.fail(fmt.Sprintf("%s.%d", join(f.path, key), i), "Invalid input: expected string, received %s", kindOf(item))
		}
	}
}

var (
	epochMs = numRule{integer: true, nonNegative: true}
	count   = numRule{integer: true, nonNegative: true}
)

func validateSample(f field) {
	f.str("id", strRule{min: 1})
	f.num("ts", epochMs)
	f.object("app", false, func(a field) { a.str("bundleId", strRule{}); a.str("name", strRule{}) })
	f.object("window", true, func(w field) { w.str("title", strRule{}); w.str("url", strRule{nullish: true}) })
	f.str("text", strRule{nullish: true})
	f.str("textSource", strRule{nullish: true, oneOf: []string{"accessibility", "ocr"}})
	f.str("textHash", strRule{nullish: true})
	f.object("activity", false, func(a field) {
		a.num("keysPerMinute", count)
		a.num("clicksPerMinute", count)
		a.num("scrollsPerMinute", count)
		a.num("idleSeconds", numRule{nonNegative: true})
	})
	f.object("context", false, func(c field) {
		c.boolean("inCall")
		c.boolean("sharingScreen")
		c.boolean("micInUse")
		c.boolean("cameraInUse")
	})
}

func validateVoice(f field) {
	f.str("kind", strRule{oneOf: VoiceKinds})
	f.str("userName", strRule{})
	f.str("threadTitle", strRule{nullish: true})
	f.num("focusMinutes", numRule{nullish: true, integer: true, nonNegative: true})
	f.num("driftMinutes", numRule{nullish: true, integer: true, nonNegative: true})
	f.str("distraction", strRule{nullish: true})
	f.str("nextUnit", strRule{nullish: true})
	f.num("minutesToNextUnit", numRule{nullish: true, integer: true, nonNegative: true})
	f.str("completionLabel", strRule{nullish: true})
}

func validateFeedback(f field) {
	f.num("ts", epochMs)
	f.str("kind", strRule{oneOf: FeedbackKinds})
	f.str("sampleId", strRule{nullish: true})
	f.str("threadId", strRule{nullish: true})
	f.strings("segmentIds", true)
	f.num("since", numRule{nullish: true, integer: true, nonNegative: true})
}

func validateEvent(f field) {
	f.num("ts", epochMs)
	f.str("type", strRule{oneOf: EventTypes})
	f.str("threadId", strRule{nullish: true})
	f.num("value", numRule{nullish: true})
}

// parseBody validates `body` with `validate` (on the top-level object) and decodes it into T.
func parseBody[T any](body []byte, validate func(field)) (T, []Issue, error) {
	var out T
	raw, err := decodeAny(body)
	if err != nil {
		return out, nil, err
	}
	c := &checker{}
	m, ok := raw.(map[string]any)
	if !ok {
		c.fail("", "Invalid input: expected object, received %s", kindOf(raw))
		return out, c.issues, nil
	}
	validate(field{c, m, ""})
	if len(c.issues) > 0 {
		return out, c.issues, nil
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return out, nil, err
	}
	return out, nil, nil
}

// parseEvents reads one CompanionEvent or an array of them.
func parseEvents(body []byte) ([]CompanionEvent, []Issue, error) {
	raw, err := decodeAny(body)
	if err != nil {
		return nil, nil, err
	}
	c := &checker{}
	switch v := raw.(type) {
	case map[string]any:
		validateEvent(field{c, v, ""})
	case []any:
		for i, item := range v {
			m, ok := item.(map[string]any)
			if !ok {
				c.fail(fmt.Sprint(i), "Invalid input: expected object, received %s", kindOf(item))
				continue
			}
			validateEvent(field{c, m, fmt.Sprint(i)})
		}
	default:
		c.fail("", "Invalid input")
	}
	if len(c.issues) > 0 {
		return nil, c.issues, nil
	}
	if _, isArray := raw.([]any); isArray {
		var events []CompanionEvent
		err = json.Unmarshal(body, &events)
		return events, nil, err
	}
	var event CompanionEvent
	err = json.Unmarshal(body, &event)
	return []CompanionEvent{event}, nil, err
}
