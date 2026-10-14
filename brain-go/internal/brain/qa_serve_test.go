package brain

import (
	"context"
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// The QA brain: the real brain (the real rulebook, store, labeling, Your day, HTTP surface) on a port of its own with a
// temporary home, and a Jev that replays testdata/qa/jev-tape.json: the answers the real Jev gave (qa_live_test.go).
// The engine QA (app/MokuMind/Sources/mokumind-qa) feeds it a day of samples at a time and costs no model calls. It
// never touches ~/.moku or the brain on 8020.
//
//	MOKU_QA_PORT=8031 go test ./internal/brain -run ServeQABrain -v -timeout 0      # until SIGTERM
//
// A second, control port (MOKU_QA_PORT + 1) switches the model off and on as a network would: POST /qa/mode?m=up|down|
// flap (flap: every other call fails) and GET /qa/stats (calls, screens the tape didn't know).

type qaModels struct {
	fake    *fakeModels
	tape    map[string]tapeEntry
	screens []qaScreen
	byKey   map[string][]qaScreen

	mu       sync.Mutex
	variants bool
	mode     string
	calls    int
	failed   int
	missed   map[string]int
}

func newQAModels(t testing.TB) *qaModels {
	data, err := os.ReadFile("testdata/qa/jev-tape.json")
	if err != nil {
		t.Fatalf("no Jev tape (qa_live_test.go records it): %v", err)
	}
	var entries []tapeEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		t.Fatal(err)
	}
	m := &qaModels{tape: map[string]tapeEntry{}, byKey: map[string][]qaScreen{}, mode: "up", variants: true, missed: map[string]int{}}
	for _, e := range entries {
		m.tape[e.Key] = e
	}
	m.screens = loadQAScreens(t)
	for _, s := range m.screens {
		m.byKey[s.tapeKey()] = append(m.byKey[s.tapeKey()], s)
	}
	m.fake = &fakeModels{oracle: m.oracle, names: m.names}
	return m
}

// screenFor: the catalogue screen a title, site and words belong to (the words tell WhatsApp chats apart).
func (m *qaModels) screenFor(app, title, site, text string) (qaScreen, bool) {
	list := m.byKey[tapeKey(app, title, site)]
	if app == "" { // the labeling questions don't name the app
		for _, s := range m.screens {
			if s.Title == title && (s.URL == "" && site == "" || s.URL != "" && deref(hostAndPath(ptr(s.URL))) == site) {
				list = append(list, s)
			}
		}
	}
	best, found := qaScreen{}, false
	for _, s := range list {
		if !found || (text != "" && strings.HasPrefix(text, s.Text[:min(len(s.Text), 40)])) {
			best, found = s, true
		}
	}
	return best, found
}

func (m *qaModels) oracle(window, site, text string) screenTruth {
	s, ok := m.screenFor("", window, site, text)
	if !ok {
		return screenTruth{goal: goalNone, p: 0.9, category: "other"}
	}
	if s.Truth == "work" || s.Truth == "meeting" {
		return screenTruth{goal: s.task(), p: 0.9, category: s.bucket()}
	}
	return screenTruth{goal: goalNone, p: 0.95, category: s.bucket()}
}

func (m *qaModels) names(prompt string) (title, summary, activity string) {
	for _, s := range m.screens {
		encoded, _ := json.Marshal(s.Title)
		if s.task() != "" && strings.Contains(prompt, strings.Trim(string(encoded), `"`)) {
			return s.task(), "Working on " + s.task(), s.task()
		}
	}
	return "a goal", "A goal", "working"
}

func (s qaScreen) task() string {
	if s.Task != "" {
		return s.Task
	}
	return ""
}

func (s qaScreen) bucket() string {
	if s.Bucket != "" {
		return s.Bucket
	}
	return "other"
}

func (m *qaModels) Health() *CloudHealth { return nil }

// down: whether this call fails, as a dead network or a relay error would.
func (m *qaModels) down() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls++
	fail := m.mode == "down" || (m.mode == "flap" && m.calls%2 == 0)
	if fail {
		m.failed++
	}
	return fail
}

func (m *qaModels) Judge(state any, questions QuestionSet, local bool) JudgeOutcome {
	if m.down() {
		return JudgeOutcome{ErrorCode: "provider", HTTPStatus: 503, CallMeta: CallMeta{Model: "typesafe-ai/jev", Attempts: 2, LatencyMs: 900}}
	}
	if len(questions) == 1 && questions[0].Key == "kind" {
		st := state.(OMap)
		key := tapeKey(get(st, "user_app"), get(st, "window"), get(st, "site"))
		e, ok := m.tape[key]
		if !ok {
			m.mu.Lock()
			m.missed[key]++
			m.mu.Unlock()
			return JudgeOutcome{ErrorCode: "schema", CallMeta: CallMeta{Model: "typesafe-ai/jev"}}
		}
		pWork := e.PWork
		// The real Jev's answer moved with the page's words on borderline pages (the variants recorded with it): each
		// distinct text gets one of the answers it gave, always the same one for the same words.
		if m.variants && len(e.Variants) > 0 {
			sum := sha1.Sum([]byte(get(st, "screen_contents")))
			if pick := int(sum[0]) % (1 + len(e.Variants)); pick > 0 {
				pWork = e.Variants[pick-1].PWork
			}
		}
		choice := "distraction"
		if pWork >= 0.5 {
			choice = "work"
		}
		answer := EvaluationAnswer{Type: "choice", Choice: choice, Probabilities: map[string]float64{"work": pWork, "distraction": 1 - pWork}, order: []string{"work", "distraction"}}
		return JudgeOutcome{OK: true, Answers: Answers{byID: map[string]EvaluationAnswer{"kind": answer}, order: []string{"kind"}},
			CallMeta: CallMeta{Model: e.Model, LatencyMs: e.LatencyMs, Attempts: 1}}
	}
	return m.fake.Judge(state, questions, local)
}

func (m *qaModels) Write(req WriteRequest) WriteOutcome {
	if m.down() {
		return WriteOutcome{ErrorCode: "provider", CallMeta: CallMeta{Model: "openai/gpt-6-luna"}}
	}
	return m.fake.Write(req)
}

func TestServeQABrain(t *testing.T) {
	port := os.Getenv("MOKU_QA_PORT")
	if port == "" {
		t.Skip("MOKU_QA_PORT=8031 serves the QA brain")
	}
	// MOKU_QA_HOME: a home of our own (never ~/.moku); the driver reads its brain-token to talk to this brain.
	home := os.Getenv("MOKU_QA_HOME")
	if home == "" {
		home = t.TempDir()
	}
	os.MkdirAll(home, 0o700)
	t.Setenv("MOKU_HOME", home)
	t.Setenv("MOKU_BRAIN_TOKEN", "")
	token, err := LoadBrainToken(home)
	if err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(filepath.Join(home, "moku.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	// The process runs with the production brain's collector settings (main.go), so its memory is the app's brain's.
	debug.SetGCPercent(50)
	debug.SetMemoryLimit(96 << 20)
	models := newQAModels(t)
	var number int
	fmt.Sscan(port, &number)
	b := NewBrain(BrainOptions{Store: store, Models: models})

	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", number))
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: NewHandler(b, AppOptions{Port: number, Token: token}), ReadHeaderTimeout: 10 * time.Second}
	go server.Serve(listener)

	control := http.NewServeMux()
	control.HandleFunc("/qa/mode", func(w http.ResponseWriter, r *http.Request) {
		models.mu.Lock()
		models.mode = r.URL.Query().Get("m")
		models.calls = 0
		models.mu.Unlock()
		fmt.Fprintf(w, "ok %s\n", r.URL.Query().Get("m"))
	})
	control.HandleFunc("/qa/variants", func(w http.ResponseWriter, r *http.Request) {
		models.mu.Lock()
		models.variants = r.URL.Query().Get("on") != "0"
		models.mu.Unlock()
		fmt.Fprintf(w, "ok %v\n", r.URL.Query().Get("on") != "0")
	})
	// GET /qa/runtime: what the brain's process holds (launch QA, lens 3: the soak reads it every few seconds).
	control.HandleFunc("/qa/runtime", func(w http.ResponseWriter, r *http.Request) {
		var m runtime.MemStats
		runtime.ReadMemStats(&m)
		json.NewEncoder(w).Encode(map[string]any{"goroutines": runtime.NumGoroutine(), "heapAllocMiB": float64(m.HeapAlloc) / (1 << 20),
			"heapInuseMiB": float64(m.HeapInuse) / (1 << 20), "sysMiB": float64(m.Sys) / (1 << 20), "gcs": m.NumGC, "heapObjects": m.HeapObjects})
	})
	control.HandleFunc("/qa/stats", func(w http.ResponseWriter, r *http.Request) {
		models.mu.Lock()
		defer models.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"calls": models.calls, "failed": models.failed, "missed": models.missed, "mode": models.mode})
	})
	controlListener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", number+1))
	if err != nil {
		t.Fatal(err)
	}
	go (&http.Server{Handler: control}).Serve(controlListener)

	fmt.Printf("qa brain on http://127.0.0.1:%d (control on %d), home %s\n", number, number+1, home)
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	<-signals
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	server.Shutdown(ctx)
	b.Settle()
	models.mu.Lock()
	fmt.Printf("qa brain: %d model calls, %d failed on purpose, tape missed %v\n", models.calls, models.failed, models.missed)
	models.mu.Unlock()
}
