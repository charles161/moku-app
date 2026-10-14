package brain

import (
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"runtime/debug"
	"strconv"
	"strings"
	"time"
)

// The brain's HTTP surface (127.0.0.1 only). Every body is validated against the contract (400 on bad input).

func logf(format string, args ...any) { log.Printf(format, args...) }

// giveBackMemory: the world and threads read the whole timeline, tens of megabytes for a moment. Hand it back to macOS
// as soon as the answer is out, so the brain stays small between calls.
func giveBackMemory() { debug.FreeOSMemory() }

const maxBodyBytes = 2 * 1024 * 1024

type AppOptions struct {
	Port int
	// LogVerdicts: one line per verdict on stdout (no screen text).
	LogVerdicts bool
	// Token: what every request but /health (and the calibration dashboard) must carry as "Authorization: Bearer …"
	// (LoadBrainToken). Empty: no token asked (tests).
	Token string
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(status)
	io.WriteString(w, JSON(v))
}

func errorJSON(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, OMap{{"error", message}})
}

type httpError struct {
	status int
	body   any
}

// NewHandler serves the brain.
func NewHandler(b *Brain, o AppOptions) http.Handler {
	hosts := map[string]bool{fmt.Sprintf("127.0.0.1:%d", o.Port): true, fmt.Sprintf("localhost:%d", o.Port): true}
	threadPath := regexp.MustCompile(`^/v1/threads/([^/]+)$`)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		RefreshZone() // the brain outlives a flight: its days follow the Mac's time zone (zone.go)
		defer func() {
			if p := recover(); p != nil {
				if he, ok := p.(httpError); ok {
					writeJSON(w, he.status, he.body)
					return
				}
				LogError(ErrRequest, "moku brain error: %v", p)
				errorJSON(w, 500, "internal error")
			}
		}()
		// Only the Mac app talks to the brain. A web page never does: see fromAWebPage. Another local process (another
		// macOS user, a sandboxed app) needs the brain token, which only this Mac user can read, so it can't read Your
		// day, change settings or delete everything. /health stays open: it's how Moku sees its brain is up.
		if fromAWebPage(r, b.calibrate, o.Port) || (r.Host != "" && !hosts[r.Host]) {
			errorJSON(w, 403, "forbidden")
			return
		}
		if o.Token != "" && !openToAll(r, b.calibrate) && !carriesToken(r, o.Token) {
			errorJSON(w, 401, "unauthorized")
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes+1))
		if err != nil || len(body) > maxBodyBytes {
			errorJSON(w, 413, "body too large")
			return
		}
		path, method := r.URL.Path, r.Method
		query := r.URL.Query()

		switch {
		case method == "GET" && path == "/health":
			access := ModelAccess()
			writeJSON(w, 200, OMap{{"ok", true}, {"service", "moku-brain"}, {"modelKey", access != "none"}, {"models", access}, {"cloud", b.ModelHealth()},
				{"errors", ErrorCounts()}})

		case method == "POST" && path == "/v1/judge":
			sample := mustParse[ActivitySample](body, validateSample)
			verdict := locked(b, func() Verdict { return b.Judge(sample) })
			if o.LogVerdicts {
				logVerdict(verdict, sample.App.Name)
			}
			writeJSON(w, 200, verdict)

		case method == "POST" && path == "/v1/voice":
			req := mustParse[VoiceRequest](body, validateVoice)
			line := locked(b, func() VoiceLine { return b.Voice(req) })
			writeJSON(w, 200, line)

		case method == "POST" && path == "/v1/feedback":
			f := mustParse[Feedback](body, validateFeedback)
			result := locked(b, func() FeedbackResult { return b.Feedback(f) })
			writeJSON(w, 200, result)

		case method == "POST" && path == "/v1/events":
			events, issues, err := parseEvents(body)
			failParse(issues, err)
			n := locked(b, func() int { return b.Events(events) })
			writeJSON(w, 200, OMap{{"stored", n}})

		case method == "GET" && path == "/v1/world":
			world := locked(b, b.World)
			writeJSON(w, 200, world)
			giveBackMemory()

		case method == "GET" && path == "/v1/config":
			writeJSON(w, 200, b.Config())

		case method == "PUT" && path == "/v1/config":
			patch, issues, err := ParseConfigPatch(body)
			failParse(issues, err)
			config, err := b.UpdateConfig(patch)
			if err != nil {
				panic(err)
			}
			writeJSON(w, 200, config)

		case method == "GET" && path == "/v1/threads":
			threads := locked(b, b.Threads)
			writeJSON(w, 200, threads)
			giveBackMemory()

		case (method == "PATCH" || method == "DELETE") && threadPath.MatchString(path):
			id := threadPath.FindStringSubmatch(path)[1]
			b.Lock()
			defer b.Unlock()
			if method == "DELETE" {
				verdicts, rules, ok := b.Store.ForgetThread(id)
				if !ok {
					errorJSON(w, 404, "no such thread")
					return
				}
				writeJSON(w, 200, OMap{{"ok", true}, {"unlinkedVerdicts", verdicts}, {"unlinkedRules", rules}})
				return
			}
			title := parseTitle(body)
			if !b.retitleByPerson(id, title) {
				errorJSON(w, 404, "no such thread")
				return
			}
			for _, t := range b.Threads() {
				if t.ID == id {
					writeJSON(w, 200, t)
					return
				}
			}
			errorJSON(w, 404, "no such thread")

		case method == "GET" && path == "/v1/days":
			to := query.Get("to")
			if to == "" {
				to = localDate(b.now())
			}
			from := query.Get("from")
			if from == "" {
				from = weekBefore(to)
			}
			days, err := locked2(b, func() (DaysResponse, error) { return b.Days(from, to) })
			if isRange(err) {
				errorJSON(w, 400, "from and to must be YYYY-MM-DD, from before to")
				return
			}
			writeJSON(w, 200, days)

		case method == "DELETE" && path == "/v1/data":
			b.Settle()
			locked(b, func() bool { b.DeleteEverything(); return true })
			writeJSON(w, 200, OMap{{"ok", true}})

		case method == "GET" && path == "/v1/counts":
			date := query.Get("date")
			if date == "" {
				y := time.UnixMilli(b.now()).In(Zone())
				date = time.Date(y.Year(), y.Month(), y.Day()-1, 12, 0, 0, 0, Zone()).Format("2006-01-02")
			}
			counts, err := locked2(b, func() (DayCounts, error) { return b.Counts(date) })
			if isRange(err) {
				errorJSON(w, 400, "date must be YYYY-MM-DD")
				return
			}
			writeJSON(w, 200, counts)

		case method == "GET" && path == "/v1/today":
			day := b.Today
			if query.Get("cached") == "1" { // "Today counted": only what's written, never a model call
				day = b.TodayCached
			}
			summary, err := locked2(b, func() (TodaySummary, error) { return day(query.Get("date")) })
			if isRange(err) {
				errorJSON(w, 400, "date must be YYYY-MM-DD")
				return
			}
			writeJSON(w, 200, summary)

		case b.calibrate && (path == "/calibrate" || strings.HasPrefix(path, "/calibrate/")):
			b.serveCalibration(w, r, body)

		default:
			errorJSON(w, 404, "not found")
		}
	})
}

// fromAWebPage: a request a browser made for a web page, which the brain refuses. A browser sends Origin on every
// fetch and form post to another origin, and Sec-Fetch-Site on <img>, <script> and links (cross-site, or same-site
// from a page on another local port); a DNS-rebinding page arrives with its own Host, which the caller checks. The
// calibration dashboard (Charles's build only) is a page the brain serves itself: its own requests (same-origin, or
// carrying its own origin) are let through, to /calibrate only.
func fromAWebPage(r *http.Request, calibrate bool, port int) bool {
	if site := r.Header.Get("Sec-Fetch-Site"); site == "cross-site" || site == "same-site" {
		return true
	}
	_, hasOrigin := r.Header["Origin"]
	return hasOrigin && !(calibrate && calibrationOrigin(r, port))
}

// openToAll: what answers without the brain token: /health, and the calibration dashboard in its own build (a
// browser page can't hold the token; fromAWebPage keeps other sites out of it).
func openToAll(r *http.Request, calibrate bool) bool {
	if r.Method == "GET" && r.URL.Path == "/health" {
		return true
	}
	return calibrate && (r.URL.Path == "/calibrate" || strings.HasPrefix(r.URL.Path, "/calibrate/"))
}

// carriesToken: "Authorization: Bearer <token>", compared in constant time.
func carriesToken(r *http.Request, token string) bool {
	scheme, given, found := strings.Cut(r.Header.Get("Authorization"), " ")
	return found && strings.EqualFold(scheme, "Bearer") && subtle.ConstantTimeCompare([]byte(strings.TrimSpace(given)), []byte(token)) == 1
}

// locked runs fn under the brain's lock, letting go of it even if fn panics.
func locked[T any](b *Brain, fn func() T) T {
	b.Lock()
	defer b.Unlock()
	return fn()
}

func locked2[T any](b *Brain, fn func() (T, error)) (T, error) {
	b.Lock()
	defer b.Unlock()
	return fn()
}

func isRange(err error) bool {
	var re *RangeError
	return errors.As(err, &re)
}

// mustParse validates and decodes a body, or stops the request with a 400.
func mustParse[T any](body []byte, validate func(field)) T {
	value, issues, err := parseBody[T](body, validate)
	failParse(issues, err)
	return value
}

func failParse(issues []Issue, err error) {
	if err != nil {
		panic(httpError{400, OMap{{"error", "body must be JSON"}}})
	}
	if len(issues) > 0 {
		panic(httpError{400, OMap{{"error", "invalid body"}, {"issues", issues}}})
	}
}

var oneLineTitle = regexp.MustCompile(`^[^\n\r]*$`)

// parseTitle: PATCH /v1/threads/:id body: the person's own title, one line.
func parseTitle(body []byte) string {
	raw, err := decodeAny(body)
	if err != nil {
		panic(httpError{400, OMap{{"error", "body must be JSON"}}})
	}
	m, _ := raw.(map[string]any)
	title, ok := m["title"].(string)
	title = Trim(title)
	if !ok || Len16(title) < 1 || Len16(title) > PersonTitleMax || !oneLineTitle.MatchString(title) {
		panic(httpError{400, OMap{{"error", "invalid body"}, {"issues", []Issue{{Path: "title", Message: "Invalid title"}}}}})
	}
	return title
}

// weekBefore: six days before `to` (the default strip is a week), or something dayWindow refuses.
func weekBefore(to string) string {
	parts := strings.Split(to, "-")
	num := func(i, fallback int) (int, bool) {
		if i >= len(parts) {
			return fallback, true
		}
		n, err := strconv.Atoi(parts[i])
		return n, err == nil
	}
	y, ok1 := num(0, 1970)
	m, ok2 := num(1, 1)
	d, ok3 := num(2, 1)
	if !ok1 || !ok2 || !ok3 {
		return "NaN-NaN-NaN"
	}
	return time.Date(y, time.Month(m), d-6, 12, 0, 0, 0, Zone()).Format("2006-01-02")
}

var ruleID = regexp.MustCompile(`^\[([\w-]+)\]`)

func logVerdict(v Verdict, app string) {
	thread := ""
	if v.Thread != nil {
		thread = fmt.Sprintf(" %q", v.Thread.Title)
		if v.IsNewThread {
			thread += " (new)"
		}
	}
	var extra []string
	if v.Activity != nil && *v.Activity != "" {
		extra = append(extra, *v.Activity)
	}
	if v.Completion != nil {
		extra = append(extra, "completed: "+v.Completion.Label)
	}
	rule := v.Source
	if m := ruleID.FindStringSubmatch(v.Reason); m != nil {
		rule = m[1]
	}
	tail := ""
	if len(extra) > 0 {
		tail = " (" + strings.Join(extra, ", ") + ")"
	}
	fmt.Printf("%s %s%s [%s, %d ms] %s%s\n", time.Now().Format("3:04:05 PM"), v.State, thread, rule, v.LatencyMs, app, tail)
}
