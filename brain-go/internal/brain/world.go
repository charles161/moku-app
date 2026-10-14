package brain

import (
	"maps"
	"math"
	"sort"
	"time"
)

// worldSnapshot is GET /v1/world. From the event log: growth points (all time), home pieces laid today, returns
// today, and the stones. From the verdict timeline (corrections applied): today's focus minutes, the longest stretch,
// per-thread minutes (today and total), and every focused minute ever. Minutes round down.
//
// This is the whole-timeline read the world cache is checked against; the brain never makes it (see worldCache).
func worldSnapshot(store *Store, config CompanionConfig, now int64) WorldSnapshot {
	return worldSnapshotFrom(store, config, now, 0)
}

// worldSnapshotFrom: the same answer, with everything before `through` kept as totals (focus minutes, per thread) and
// only the moments from there on read as spans, as the cache answers. The stones are those of the returns from there on.
// A stone whose reading reached the first span read (its drift ran back across `through`) is left out: it would be
// told differently from different starting points. With through 0, it is the whole timeline.
func worldSnapshotFrom(store *Store, config CompanionConfig, now, through int64) WorldSnapshot {
	spans := toSpans(store.Timeline(0, MaxSafeInteger), now)
	first := firstStartingAt(spans, through)
	var past pastFocus
	for _, s := range spans[:first] {
		past.add(s)
	}
	live := spans[first:]
	return assembleWorld(store, config, now, live, past, storiesFrom(store, live, through))
}

// storiesFrom: the stones of the returns from `through` on, read from the spans from there on.
func storiesFrom(store *Store, live []Span, through int64) []stoneDraft {
	returns := store.Returns(through, MaxSafeInteger)
	drafts := make([]stoneDraft, 0, len(returns))
	for _, r := range returns {
		d := draftStone(live, r)
		if through > 0 && (d.pastStart || d.lo == 0) {
			continue
		}
		drafts = append(drafts, d)
	}
	return drafts
}

// pastFocus: the focus in spans the world was given as totals instead (the world cache's finished days).
type pastFocus struct {
	focusMs  int64
	threadMs map[string]int64
}

// add: a span's focus, if it is focus. Every number the world keeps for the past is a sum of these.
func (p *pastFocus) add(s Span) {
	if s.Effective != "working" {
		return
	}
	p.focusMs += s.End - s.Start
	if s.EffectiveThreadID != nil {
		if p.threadMs == nil {
			p.threadMs = map[string]int64{}
		}
		p.threadMs[*s.EffectiveThreadID] += s.End - s.Start
	}
}

func assembleWorld(store *Store, config CompanionConfig, now int64, spans []Span, past pastFocus, drafts []stoneDraft) WorldSnapshot {
	dayStart := startOfDay(now)
	shortDrift := int64(config.ShortDriftMaxSec * 1000)
	stats := focusStats(spans, Window{dayStart, now + 1}, shortDrift)
	allTime := focusStats(spans, Window{0, now + 1}, shortDrift)
	for id, ms := range past.threadMs {
		thread := stats.ByThread[id]
		if thread == nil {
			thread = &threadFocus{}
			stats.ByThread[id] = thread
		}
		thread.TotalMs += ms
	}
	stones := make([]StoneMemory, len(drafts))
	for i, d := range drafts {
		stones[i] = d.titled(func(id string) *string { return threadTitle(store, id) })
	}
	return WorldSnapshot{
		GrowthPoints:             store.GrowthPoints(0, MaxSafeInteger),
		TodayFocusMinutes:        minutes(stats.FocusMs),
		TodayReturns:             store.CountEvents("returned", dayStart, now+1),
		LongestFocusMinutesToday: minutes(stats.LongestMs),
		Threads:                  threadSummaries(store, stats),
		UnitsToday:               housePieces(stats.FocusMs),
		Stones:                   stones,
		FocusMinutesAllTime:      minutes(past.focusMs + allTime.FocusMs),
	}
}

// worldCache keeps what the finished days add to the world, as totals, so no call reads the history again.
//
// Every number the world reports about the past is a sum over spans: all-time focus minutes, and minutes per thread.
// The cache holds those sums for every verdict before `through` (the start of yesterday, brought forward each day), in
// memory and in the database (meta "world_past"), so a restart doesn't read the history either. A call then reads only
// the verdicts from `through` on: yesterday and today.
//
// Reading all of it, as the first version did, took 0.34 s of CPU and 215 MB a minute on a month of history, and on 90
// days 17 s and 676 MB of memory at every start of the brain, with the brain's lock held: every judgment waiting.
// Now the totals are built a day at a time (a few MB), letting others in between days, and kept.
//
// The totals are dropped and built again when a write changes the time they cover (a relabel, labels written back, a
// thread forgotten or merged, a late verdict): Store.TakeEdits says so, and Store.noteEdit deletes the saved copy at
// once. Its answer is worldSnapshotFrom's, which world_cache_test.go checks on random histories.
type worldCache struct {
	valid  bool
	loaded bool
	past   pastTotals
	// building is open while the totals are being built, so a second call waits for them instead of building its own.
	building chan struct{}
	// builds: how many times the totals were built from the store (not loaded); steps: days read doing it. For tests.
	builds, steps int
}

// pastTotals: what every verdict before Through adds to the world, and where toSpans carries on from.
type pastTotals struct {
	Through int64 `json:"through"`
	// Lookahead: the first verdict at or after Through when this was built. The last verdict before Through lasts until
	// it (at most CoverMs), so a verdict landing earlier changes the totals.
	Lookahead int64            `json:"lookahead"`
	State     string           `json:"state"`
	Thread    *string          `json:"thread"`
	Known     bool             `json:"known"`
	FocusMs   int64            `json:"focusMs"`
	ThreadMs  map[string]int64 `json:"threadMs"`
}

func (t pastTotals) carry() spanCarry { return spanCarry{state: t.State, thread: t.Thread, known: t.Known} }

func (t pastTotals) focus() pastFocus { return pastFocus{focusMs: t.FocusMs, threadMs: t.ThreadMs} }

const (
	worldPastKey   = "world_past"
	worldPastStep  = 24 * 3_600_000
	worldPastSaved = 30 // days built between saves of a long build
)

// pastEdge: the moment the totals are brought up to, the start of yesterday.
func pastEdge(now int64) int64 { return startOfDay(startOfDay(now) - 1) }

// snapshot: the world as of now. `unlocked` runs a function with the brain's lock let go, which the build does between
// days so a long build never keeps a judgment waiting.
func (c *worldCache) snapshot(store *Store, config CompanionConfig, now int64, unlocked func(func())) WorldSnapshot {
	for {
		if c.building != nil {
			done := c.building
			unlocked(func() { <-done })
			continue
		}
		edited := store.TakeEdits()
		if !c.loaded {
			// First call since the brain started: the saved totals, unless a write since (the start's housekeeping merges
			// threads) touched the time they cover.
			c.loaded = true
			if saved, ok := store.loadPast(); ok {
				if edited < saved.Lookahead {
					store.forgetPast()
				} else {
					c.past, c.valid = saved, true
				}
			}
		}
		if c.valid && edited < c.past.Lookahead {
			c.valid = false
			store.forgetPast()
		}
		if edge := pastEdge(now); !c.valid || c.past.Through < edge {
			c.build(store, edge, now, unlocked)
			continue // the lock was let go; look again
		}
		break
	}
	carry := c.past.carry()
	spans := carry.spans(store.Timeline(c.past.Through, MaxSafeInteger), now)
	return assembleWorld(store, config, now, spans, c.past.focus(), storiesFrom(store, spans, c.past.Through))
}

// build brings the totals up to edge: loads the saved ones the first time, and reads whatever days they lack.
func (c *worldCache) build(store *Store, edge, now int64, unlocked func(func())) {
	done := make(chan struct{})
	c.building = done
	defer func() { c.building = nil; close(done) }()
	if !c.valid {
		c.past, c.valid = pastTotals{}, true
		c.builds++
		if base, pruned := store.loadPruned(); pruned {
			// The history older than the detail that is kept was deleted (retention.go); its totals were kept.
			c.past = base
		} else {
			first := store.FirstVerdictAt()
			if first == nil || *first >= edge {
				// Nothing before yesterday: every verdict is read as it comes.
				c.past.Through, c.past.Lookahead = edge, edge+CoverMs
				store.savePast(c.past)
				return
			}
			c.past.Through = *first
		}
	}
	for day := 0; c.past.Through < edge; day++ {
		c.past = c.past.extend(store, min(edge, c.past.Through+worldPastStep), now)
		c.steps++
		if (day+1)%worldPastSaved == 0 || c.past.Through >= edge {
			store.savePast(c.past)
		}
		if c.past.Through < edge {
			unlocked(func() {}) // let the judgments waiting in
		}
	}
}

// extend: the totals brought forward from t.Through to `to`, reading the verdicts in between.
func (t pastTotals) extend(store *Store, to, now int64) pastTotals {
	rows := store.Timeline(t.Through, to)
	next := store.FirstVerdictFrom(to)
	carry := t.carry()
	// The last verdict lasts until the next one, or a minute when there's none (now is far past it).
	until := now
	if next != nil {
		until = *next
	}
	past := pastFocus{focusMs: t.FocusMs, threadMs: maps.Clone(t.ThreadMs)}
	for _, span := range carry.spans(rows, until) {
		past.add(span)
	}
	out := pastTotals{Through: to, Lookahead: to + CoverMs, State: carry.state, Thread: carry.thread, Known: carry.known,
		FocusMs: past.focusMs, ThreadMs: past.threadMs}
	if next != nil {
		out.Lookahead = *next
	}
	return out
}

func threadTitle(store *Store, id string) *string {
	if t := store.Thread(id); t != nil {
		return &t.Title
	}
	return nil
}

// threadSummaries: every thread, most recently active first.
func threadSummaries(store *Store, stats FocusStats) []ThreadSummary {
	out := []ThreadSummary{}
	for _, t := range store.AllThreads() {
		var today, total int64
		if f := stats.ByThread[t.ID]; f != nil {
			today, total = f.WindowMs, f.TotalMs
		}
		out = append(out, ThreadSummary{ID: t.ID, Title: t.Title, Summary: t.Summary, FocusMinutesToday: minutes(today),
			FocusMinutesTotal: minutes(total), LastActiveAt: t.LastActiveAt, Category: t.Category})
	}
	return out
}

func minutes(ms int64) int64 { return max(0, int64(math.Floor(float64(ms)/60_000))) }

// shareMinutes: whole minutes for the parts of a whole that's shown as `total` minutes, adding up to it exactly: each
// part its whole minutes, then the minutes left to the parts with the most left over (the first part on a tie). Rounding
// each part on its own made the rows and "8 tasks" disagree with the header's minutes (2026-10-06).
func shareMinutes(ms []int64, total int64) []int64 {
	out := make([]int64, len(ms))
	order := make([]int, len(ms))
	left := total
	for i, m := range ms {
		out[i], order[i] = max(0, m)/60_000, i
		left -= out[i]
	}
	sort.SliceStable(order, func(a, b int) bool { return max(0, ms[order[a]])%60_000 > max(0, ms[order[b]])%60_000 })
	for k := 0; k < len(order) && left > 0; k, left = k+1, left-1 {
		out[order[k]]++
	}
	return out
}

// housePieces: the pieces of today's house built by `focusMs` of focus, as every view counts them: one per 10 focused
// minutes (the house itself stops at its 24). Return bonuses used to add pieces the popover's house never showed.
func housePieces(focusMs int64) int64 { return minutes(focusMs) / PointsPerUnit }

// startOfDay: local midnight of the day ts falls in.
func startOfDay(ts int64) int64 {
	t := time.UnixMilli(ts).In(Zone())
	return dayStart(t.Year(), t.Month(), t.Day()).UnixMilli()
}
