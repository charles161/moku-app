package brain

import (
	"runtime/debug"
	"sync"
	"time"
)

// The brain, independent of HTTP: one object per store. The HTTP app (app.go) and the tests drive it.
//
// Concurrency: the TypeScript brain ran on one thread and switched only at an await. This keeps that model: every
// request and background task holds the brain's lock while it runs, and lets go of it only while it waits on a
// model or a timer (b.unlocked). So the ported logic reads line for line like the original, with no data races.
type Brain struct {
	mu         sync.Mutex
	Store      *Store
	Models     Models
	config     func() CompanionConfig
	configFile string
	now        func() int64
	bg         *Background

	focus    *focusPipeline
	labeler  *labeler
	activity *workActivity
	complete *completionDetector
	today    *todayState
	world    worldCache

	// goalJudging: "does this screen serve one of your goals right now?" (goaljudge.go). calibrate: Charles's
	// calibration build (calibrate.go): goal-aware judging, the dashboard at /calibrate, and screen text kept 14 days.
	goalJudging, calibrate bool
	// merged: goals merged into another (from → into) since the brain started, for work still holding the old id.
	merged map[string]string
	// vacuumFailed: giving the old detail's space back to the disk failed (a full disk, say): not tried again until the
	// brain starts again (retention.go).
	vacuumFailed bool
}

type BrainOptions struct {
	Store  *Store
	Models Models
	// Config reads the config; default: DefaultConfig merged with ConfigFile, on every call.
	Config func() CompanionConfig
	// ConfigFile is the overrides file PUT /v1/config writes; default ConfigPath(), unless Config is given (then none).
	ConfigFile string
	Now        func() int64
	// GoalJudging turns on goal-aware judging; Calibrate turns on Charles's calibration (and goal-aware judging with
	// it). Both are off unless the brain is started with MOKU_GOAL_JUDGING=1 or MOKU_CALIBRATE=1 (GoalModes).
	GoalJudging, Calibrate bool
}

func NewBrain(o BrainOptions) *Brain {
	b := &Brain{Store: o.Store, Models: o.Models, now: o.Now, bg: NewBackground(),
		goalJudging: o.GoalJudging || o.Calibrate, calibrate: o.Calibrate, merged: map[string]string{}}
	if b.now == nil {
		b.now = func() int64 { return time.Now().UnixMilli() }
	}
	b.configFile = o.ConfigFile
	if o.Config != nil {
		b.config = o.Config
	} else {
		if b.configFile == "" {
			b.configFile = ConfigPath()
		}
		file := b.configFile
		b.config = func() CompanionConfig { return LoadConfig(file) }
	}
	b.focus = newFocus(b)
	b.activity = newWorkActivity(b)
	b.labeler = newLabeler(b)
	b.complete = newCompletionDetector(b)
	b.today = newTodayState()
	return b
}

// Lock and Unlock bracket a request: the brain's work runs under its lock.
func (b *Brain) Lock()   { b.mu.Lock() }
func (b *Brain) Unlock() { b.mu.Unlock() }
func (b *Brain) TryLock() bool { return b.mu.TryLock() }

// unlocked runs fn without the brain's lock (a model call, a wait), then takes the lock back.
func (b *Brain) unlocked(fn func()) {
	b.mu.Unlock()
	defer b.mu.Lock()
	fn()
}

func (b *Brain) judgeModel(state any, questions QuestionSet, local bool) (out JudgeOutcome) {
	b.unlocked(func() { out = b.Models.Judge(state, questions, local) })
	return
}

func (b *Brain) writeModel(req WriteRequest) (out WriteOutcome) {
	b.unlocked(func() { out = b.Models.Write(req) })
	return
}

// background starts fn under the brain's lock, after the current work lets go of it.
func (b *Brain) background(fn func()) *Task {
	return b.bg.Go(func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		fn()
	})
}

// await waits for a background task without holding the lock.
func (b *Brain) await(t *Task) {
	if t != nil {
		b.unlocked(func() { <-t.done })
	}
}

// Settle waits for background work (labeling, naming threads, writing the note). Call it without the lock.
func (b *Brain) Settle() { b.bg.Settle() }

func (b *Brain) Config() CompanionConfig { return b.config() }

// UpdateConfig merges a partial config into the overrides file (atomically) and returns the config served from then on.
func (b *Brain) UpdateConfig(patch map[string]any) (CompanionConfig, error) {
	if b.configFile == "" {
		panic("this brain has no config file")
	}
	if _, err := SaveConfig(patch, b.configFile); err != nil {
		return CompanionConfig{}, err
	}
	return b.config(), nil
}

func (b *Brain) Events(events []CompanionEvent) int {
	b.Store.InsertEvents(events)
	return len(events)
}

// World is the world snapshot. Like every Brain method it runs under the brain's lock, which it lets go of while it
// builds the totals of a long history (once per start, or after a correction to the past).
func (b *Brain) World() WorldSnapshot { return b.world.snapshot(b.Store, b.config(), b.now(), b.unlocked) }

func (b *Brain) Threads() []ThreadSummary { return b.World().Threads }

func (b *Brain) DeleteEverything() { b.Store.DeleteEverything() }

func (b *Brain) ModelHealth() *CloudHealth { return b.Models.Health() }

// ── Background work ─────────────────────────────────────────────────────────────────────────────────────────────

// Task is background work in flight.
type Task struct{ done chan struct{} }

func (t *Task) Done() <-chan struct{} { return t.done }

// Background: work that must not hold up a response. Failures are logged, never thrown. Settle waits for everything
// queued so far (and anything it queues in turn).
type Background struct {
	mu      sync.Mutex
	cond    *sync.Cond
	pending int
}

func NewBackground() *Background {
	bg := &Background{}
	bg.cond = sync.NewCond(&bg.mu)
	return bg
}

func (bg *Background) add() {
	bg.mu.Lock()
	bg.pending++
	bg.mu.Unlock()
}

func (bg *Background) done() {
	bg.mu.Lock()
	bg.pending--
	bg.cond.Broadcast()
	bg.mu.Unlock()
}

// Go runs task in the background.
func (bg *Background) Go(task func()) *Task {
	t := &Task{done: make(chan struct{})}
	bg.add()
	go func() {
		defer bg.done()
		defer close(t.done)
		defer func() {
			if p := recover(); p != nil {
				LogError(ErrTask, "moku background task failed: %v\n%s", p, debug.Stack())
			}
		}()
		task()
	}()
	return t
}

func (bg *Background) Settle() {
	bg.mu.Lock()
	for bg.pending > 0 {
		bg.cond.Wait()
	}
	bg.mu.Unlock()
}

// serialQueue runs jobs one at a time, in order (the labeler: two contexts never start the same thread twice).
type serialQueue struct {
	mu      sync.Mutex
	jobs    []func()
	running bool
}

func (q *serialQueue) push(job func()) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.jobs = append(q.jobs, job)
	if !q.running {
		q.running = true
		go q.drain()
	}
}

func (q *serialQueue) drain() {
	for {
		q.mu.Lock()
		if len(q.jobs) == 0 {
			q.running = false
			q.mu.Unlock()
			return
		}
		job := q.jobs[0]
		q.jobs = q.jobs[1:]
		q.mu.Unlock()
		job()
	}
}
