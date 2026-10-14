package brain

import (
	"bytes"
	"compress/gzip"
	"database/sql"
	"encoding/json"
	"io"
	"maps"
	"sort"
	"time"
)

// Moku keeps the moment-by-moment detail (samples, verdicts, model calls) for 90 days and each day's summary for good.
// Without it the store grew about 3.5 to 5 MB a day, 1.3 to 1.8 GB a year (launch QA, lens 3).
//
// A day's summary is everything Your day shows for it (GET /v1/today for that date: the totals, the goals with their
// workflow and steps, the day's ribbon, the note, the comebacks), saved as one compact record while the detail it is made
// from still exists. When the detail goes, /v1/today and /v1/days answer for that date from the record, and look the same.
// "Delete my data" deletes the records too, being a table like the others.
//
// Retain is the pass that does it, at start and every ten minutes, in small steps with the brain's lock let go between
// them, so a store older than 90 days is migrated in the background by the same code that tidies up each day:
//  1. save the summary of every day up to two days past the ones about to go (a day's summary reads an hour of the day
//     before it, so it is saved before that hour is deleted);
//  2. a day at a time, oldest first: keep the world's totals of it, move the boundary (from then on Your day answers for
//     it from its record), delete its detail in batches, and
//  3. empty the write-ahead log, and give the space back (VACUUM) when most of the file is free: after a first big
//     prune, never in the steady state, where the freed pages are reused by the next day's.
// Every stage can stop at any point (the brain quits, the Mac sleeps) and the next pass carries on from what is there.

// DetailKeepDays: how many calendar days of detail are kept, today's among them.
const DetailKeepDays = 90

// ── Saved days ──────────────────────────────────────────────────────────────────────────────────────────────────

// SaveDay keeps a day's summary (the day's own, or a newer save of it).
func (s *Store) SaveDay(date string, savedAt int64, summary TodaySummary) {
	s.saveDay(date, savedAt, packDay(summary))
}

// packDay: a summary as gzipped JSON, the form it's kept in. Compressing a big day takes a few milliseconds, so the
// pass does it before it takes the brain's lock.
func packDay(summary TodaySummary) []byte {
	var packed bytes.Buffer
	zip, _ := gzip.NewWriterLevel(&packed, gzip.BestCompression)
	_, err := zip.Write([]byte(JSON(summary)))
	must(err)
	must(zip.Close())
	return packed.Bytes()
}

func (s *Store) saveDay(date string, savedAt int64, packed []byte) {
	s.tx(func(tx *sql.Tx) {
		_, err := tx.Exec(`INSERT OR REPLACE INTO day_summaries (date, saved_at, summary) VALUES (?,?,?)`, date, savedAt, packed)
		must(err)
		_, err = tx.Exec(`DELETE FROM day_words WHERE date = ?`, date) // they're in the summary now
		must(err)
	})
}

// SaveDayNote and SaveDayGoalLines keep what Luna wrote for a finished day, for its summary (frozenDay).
func (s *Store) SaveDayNote(date, note string) {
	s.exec(`INSERT INTO day_words (date, note) VALUES (?, ?) ON CONFLICT(date) DO UPDATE SET note = excluded.note`, date, note)
}

func (s *Store) SaveDayGoalLines(date string, lines map[string]string) {
	_, kept := s.dayWords(date)
	merged := maps.Clone(kept)
	if merged == nil {
		merged = map[string]string{}
	}
	maps.Copy(merged, lines)
	s.exec(`INSERT INTO day_words (date, goal_lines) VALUES (?, ?) ON CONFLICT(date) DO UPDATE SET goal_lines = excluded.goal_lines`, date, JSON(merged))
}

// dayWords: the note and the goals' lines kept for a date, if any.
func (s *Store) dayWords(date string) (note *string, lines map[string]string) {
	var n, l sql.NullString
	err := s.db.QueryRow(`SELECT note, goal_lines FROM day_words WHERE date = ?`, date).Scan(&n, &l)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	must(err)
	if l.Valid {
		json.Unmarshal([]byte(l.String), &lines)
	}
	return str(n), lines
}

// SavedDay: the summary saved for a local date, if there is one.
func (s *Store) SavedDay(date string) (TodaySummary, bool) {
	var packed []byte
	err := s.db.QueryRow(`SELECT summary FROM day_summaries WHERE date = ?`, date).Scan(&packed)
	if err == sql.ErrNoRows {
		return TodaySummary{}, false
	}
	must(err)
	unzip, err := gzip.NewReader(bytes.NewReader(packed))
	must(err)
	raw, err := io.ReadAll(unzip)
	must(err)
	var summary TodaySummary
	must(json.Unmarshal(raw, &summary))
	return summary, true
}

// HasSavedDay: whether a summary is saved for the date.
func (s *Store) HasSavedDay(date string) bool {
	var one int
	return s.db.QueryRow(`SELECT 1 FROM day_summaries WHERE date = ?`, date).Scan(&one) == nil
}

// FirstSavedDay: the earliest local date with a saved summary, or nil.
func (s *Store) FirstSavedDay() *string {
	var date sql.NullString
	must(s.db.QueryRow(`SELECT MIN(date) FROM day_summaries`).Scan(&date))
	return str(date)
}

// PastSummary: what Your day shows for a date whose detail is gone: the saved summary, when the date ends at or before
// the moment the detail was pruned through. A day whose detail still exists is read from it, so a correction counts.
func (s *Store) PastSummary(date string, dayEnd int64) (TodaySummary, bool) {
	if dayEnd > s.prunedThrough.Load() {
		return TodaySummary{}, false
	}
	return s.SavedDay(date)
}

// frozenDay: a day's summary as Your day shows it, ready to be saved: built from the day's detail, with the note and the
// goals' lines Luna wrote for it when someone looked at the day (kept for this, noteFor), or else the template note and the
// lines made from what was done, so saving a day never calls a model. It reads the store only, so it runs without the
// brain's lock.
func (b *Brain) frozenDay(date string, bounds Window, now int64) TodaySummary {
	summary, dataMs := b.buildDay(date, bounds, now)
	note, lines := b.Store.dayWords(date)
	if dataMs >= noteMinDataMs {
		if note == nil {
			text := templateNote(summary, HomeOf(b.config().Companion))
			note = &text
		}
		summary.Note = note
	}
	fillGoalLines(&summary, cachedGoalLines{lines: lines}, lines != nil)
	return summary
}

// ── The detail that has gone ────────────────────────────────────────────────────────────────────────────────────

// prunedKey: meta, the world's totals of the detail that is gone (a pastTotals), whose Through is the moment before which
// the detail is deleted or being deleted. The world's all-time numbers (focus minutes, minutes per goal) are sums over the
// whole timeline, and they must not shrink when old verdicts go: a rebuild of the world's totals (world.go) starts from
// these instead of from the first verdict that is left.
const prunedKey = "detail_pruned"

// AdvancePruned records the totals of everything before totals.Through and moves the boundary there, in one write. Call it
// before deleting the detail, never after: from then on Your day answers for those days from their saved summaries, and
// the world's totals count them from here.
func (s *Store) AdvancePruned(totals pastTotals) {
	s.exec(`INSERT OR REPLACE INTO meta VALUES (?, ?)`, prunedKey, JSON(totals))
	s.prunedThrough.Store(totals.Through)
}

// loadPruned: the totals of the detail that is gone, if any is, and where. It also sets prunedThrough (at open).
func (s *Store) loadPruned() (pastTotals, bool) {
	saved := s.Meta(prunedKey)
	if saved == nil {
		s.prunedThrough.Store(0)
		return pastTotals{}, false
	}
	var totals pastTotals
	if json.Unmarshal([]byte(*saved), &totals) != nil || totals.Through <= 0 {
		s.prunedThrough.Store(0)
		return pastTotals{}, false
	}
	s.prunedThrough.Store(totals.Through)
	return totals, true
}

// ── Deleting ────────────────────────────────────────────────────────────────────────────────────────────────────

// PruneCounts: the rows one batch deleted.
type PruneCounts struct{ Samples, Verdicts, ModelCalls, Other int64 }

func (c PruneCounts) add(o PruneCounts) PruneCounts {
	return PruneCounts{c.Samples + o.Samples, c.Verdicts + o.Verdicts, c.ModelCalls + o.ModelCalls, c.Other + o.Other}
}

// full: whether any table gave `limit` rows, so there may be more.
func (c PruneCounts) full(limit int) bool {
	n := int64(limit)
	return c.Samples >= n || c.Verdicts >= n || c.ModelCalls >= n || c.Other >= n
}

// PruneBatch deletes up to limit rows older than `before` from each table that holds a moment's detail, and the rows that
// hang on them: samples and their corrections, verdicts, screen text, model calls and their inputs. What Moku learned
// (threads, rules, labels, completions, growth events) stays. One transaction, so it's short.
func (s *Store) PruneBatch(before int64, limit int) (n PruneCounts) {
	s.tx(func(tx *sql.Tx) {
		run := func(query string) int64 {
			r, err := tx.Exec(query, before, limit)
			must(err)
			return changes(r)
		}
		run(`DELETE FROM relabels WHERE sample_id IN (SELECT id FROM samples WHERE ts < ?1 ORDER BY ts LIMIT ?2)`)
		n.Other += run(`DELETE FROM sample_text WHERE id IN (SELECT id FROM sample_text WHERE ts < ?1 ORDER BY ts LIMIT ?2)`)
		n.Verdicts = run(`DELETE FROM verdicts WHERE rowid IN (SELECT rowid FROM verdicts WHERE ts < ?1 ORDER BY ts LIMIT ?2)`)
		n.Samples = run(`DELETE FROM samples WHERE rowid IN (SELECT rowid FROM samples WHERE ts < ?1 ORDER BY ts LIMIT ?2)`)
		n.Other += run(`DELETE FROM call_inputs WHERE id IN (SELECT id FROM call_inputs WHERE ts < ?1 ORDER BY ts LIMIT ?2)`)
		n.ModelCalls = run(`DELETE FROM model_calls WHERE id IN (SELECT id FROM model_calls WHERE ts < ?1 ORDER BY ts LIMIT ?2)`)
	})
	return n
}

// firstDetailFrom: when the first moment of detail at or after ts was made, or nil.
func (s *Store) firstDetailFrom(ts int64) *int64 {
	var first *int64
	for _, table := range []string{"samples", "verdicts", "model_calls", "sample_text", "call_inputs"} {
		var at sql.NullInt64
		must(s.db.QueryRow(`SELECT MIN(ts) FROM `+table+` WHERE ts >= ?`, ts).Scan(&at))
		if at.Valid && (first == nil || at.Int64 < *first) {
			v := at.Int64
			first = &v
		}
	}
	return first
}

// FreeSpace: the bytes of the database file that hold nothing (deleted rows' pages, kept for new rows), and the file's size.
func (s *Store) FreeSpace() (free, size int64) {
	var pageSize, pages, freePages int64
	must(s.db.QueryRow(`PRAGMA page_size`).Scan(&pageSize))
	must(s.db.QueryRow(`PRAGMA page_count`).Scan(&pages))
	must(s.db.QueryRow(`PRAGMA freelist_count`).Scan(&freePages))
	return freePages * pageSize, pages * pageSize
}

// ── The pass ────────────────────────────────────────────────────────────────────────────────────────────────────

const (
	// freezeLeadDays: a day's summary is saved this many days before its detail goes, because the summary of the day after
	// it reads the last hour of it.
	freezeLeadDays = 2
	// The first pass of a store older than 90 days deletes a lot: a batch starts this big and then grows or shrinks to take
	// about retainTargetHold (a big store with a cold cache is slower than a small one), and the brain's lock is let go for
	// a breath between batches, so a judgment never waits for more than one.
	retainStartRows  = 250
	retainMinRows    = 25
	retainMaxRows    = 2000
	retainTargetHold = 15 * time.Millisecond
	retainPause      = 5 * time.Millisecond
	// A world build in progress reads the days about to go: the pass waits for it, this long at most.
	retainWorldWait  = 250 * time.Millisecond
	retainWorldWaits = 240
	// VACUUM only when this share of the file, and this many bytes, are free: the first pass over a year of history, not a
	// day's tidying.
	retainVacuumMinFree = 64 << 20
	retainVacuumShare   = 40
)

// RetainOptions: knobs for tests and measuring. The zero value is what the brain runs with.
type RetainOptions struct {
	BatchRows          int           // rows a step deletes from each table (0: as many as take about 15 ms)
	Pause              time.Duration // a breath between steps; negative: none
	MaxSteps           int           // stop after this many steps (0: no limit): the brain quitting halfway
	VacuumMinFreeBytes int64
	WorldWaits         int // how many times to wait for a world build before giving up this pass
}

// RetentionReport: what a pass did, and how long it held the brain's lock.
type RetentionReport struct {
	DaysSaved                     int
	Samples, Verdicts, ModelCalls int64
	OtherRows                     int64
	DaysPruned                    int
	Steps                         int
	MaxLockHold, TotalLockHold    time.Duration
	MaxHoldByKind                 map[string]time.Duration
	Holds                         []time.Duration // how long each step held the lock, in order
	Vacuumed                      bool
	VacuumTook                    time.Duration
	Stopped, WaitedForWorld       bool // MaxSteps reached; a world build in the way
}

// HoldQuantile: how long the lock was held for the q-th share of the steps (0.5: the median).
func (r RetentionReport) HoldQuantile(q float64) time.Duration {
	if len(r.Holds) == 0 {
		return 0
	}
	sorted := append([]time.Duration(nil), r.Holds...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	return sorted[min(len(sorted)-1, int(q*float64(len(sorted))))]
}

func (r *RetentionReport) held(kind string, d time.Duration) {
	r.Steps++
	r.Holds = append(r.Holds, d)
	r.TotalLockHold += d
	r.MaxLockHold = max(r.MaxLockHold, d)
	if r.MaxHoldByKind == nil {
		r.MaxHoldByKind = map[string]time.Duration{}
	}
	r.MaxHoldByKind[kind] = max(r.MaxHoldByKind[kind], d)
}

type retainer struct {
	b    *Brain
	o    RetainOptions
	r    RetentionReport
	rows int // the size of the next batch
	// wipes: the store's wipes when the pass began. "Delete my data" during a pass (the brain's lock is let go between
	// steps) must not be followed by a save of a day read before it, so a step that finds a wipe since stops the pass.
	wipes int64
}

// tune: the next batch is sized to take about retainTargetHold, going half-way there so one odd batch doesn't swing it.
func (rt *retainer) tune(took time.Duration) {
	if rt.o.BatchRows > 0 {
		return
	}
	want := float64(rt.rows) * float64(retainTargetHold) / float64(max(took, 100*time.Microsecond))
	rt.rows = int(max(retainMinRows, min(retainMaxRows, (float64(rt.rows)+want)/2)))
}

// step runs fn under the brain's lock, as one short unit of work, then lets others in. false: stop here.
func (rt *retainer) step(kind string, fn func()) bool {
	if rt.o.MaxSteps > 0 && rt.r.Steps >= rt.o.MaxSteps {
		rt.r.Stopped = true
		return false
	}
	rt.b.Lock()
	if rt.b.Store.wipes.Load() != rt.wipes {
		rt.b.Unlock()
		rt.r.Stopped = true
		return false
	}
	started := time.Now()
	func() {
		defer func() {
			held := time.Since(started)
			rt.b.Unlock()
			rt.r.held(kind, held)
		}()
		fn()
	}()
	if rt.o.Pause > 0 {
		time.Sleep(rt.o.Pause)
	}
	return true
}

// retentionEdges: cutoff is the start of the oldest day whose detail is kept (a day ending at or before it has been
// pruned); freezeEdge, where the days whose summary is saved ahead of that end.
func retentionEdges(now int64) (cutoff, freezeEdge int64) {
	t := time.UnixMilli(now).In(Zone())
	first := t.Day() - (DetailKeepDays - 1)
	return dayStart(t.Year(), t.Month(), first).UnixMilli(), dayStart(t.Year(), t.Month(), first+freezeLeadDays).UnixMilli()
}

// dayAround: the local day ts falls in.
func dayAround(ts int64) Window {
	t := time.UnixMilli(ts).In(Zone())
	return Window{dayStart(t.Year(), t.Month(), t.Day()).UnixMilli(), dayStart(t.Year(), t.Month(), t.Day()+1).UnixMilli()}
}

// Retain: one pass of the retention (the comment at the top of this file). Called without the brain's lock; it takes it
// for each short step. A pass that is stopped, or whose store grew new old days meanwhile, is finished by the next.
func (b *Brain) Retain(o RetainOptions) RetentionReport {
	if o.Pause == 0 {
		o.Pause = retainPause
	}
	if o.VacuumMinFreeBytes <= 0 {
		o.VacuumMinFreeBytes = retainVacuumMinFree
	}
	if o.WorldWaits <= 0 {
		o.WorldWaits = retainWorldWaits
	}
	now, store := b.now(), b.Store
	rt := &retainer{b: b, o: o, rows: retainStartRows, wipes: store.wipes.Load()}
	if o.BatchRows > 0 {
		rt.rows = o.BatchRows
	}
	cutoff, freezeEdge := retentionEdges(now)

	// 1. Save the days that are about to go.
	for cursor := int64(0); ; {
		first := store.FirstVerdictFrom(cursor)
		if first == nil {
			break
		}
		day := dayAround(*first)
		if day.End > freezeEdge {
			break
		}
		if date := localDate(day.Start); !store.HasSavedDay(date) {
			packed := packDay(b.frozenDay(date, day, now))
			if !rt.step("save", func() { store.saveDay(date, now, packed) }) {
				return rt.r
			}
			rt.r.DaysSaved++
		}
		cursor = day.End
	}

	// 2. Delete the days that are old, oldest first.
	for cursor := int64(0); ; {
		first := store.firstDetailFrom(cursor)
		if first == nil {
			break
		}
		day := dayAround(*first)
		if day.End > cutoff {
			break
		}
		if !rt.pruneDay(day, now) {
			return rt.r
		}
		rt.r.DaysPruned++
		cursor = day.End
	}

	// 3. What was deleted is really gone from the file, and the space comes back when most of the file is free.
	if rt.r.Samples+rt.r.Verdicts+rt.r.ModelCalls+rt.r.OtherRows > 0 && !rt.step("settle", store.SettleAfterForgetting) {
		return rt.r
	}
	if free, size := store.FreeSpace(); !b.vacuumFailed && free >= o.VacuumMinFreeBytes && free*100 >= size*retainVacuumShare {
		started := time.Now()
		// Every use of the store waits for it, once: the file is rewritten without its free pages.
		if _, err := store.db.Exec(`VACUUM`); err != nil {
			LogError(ErrDisk, "moku brain: couldn't give the space of the old detail back to the disk (%v); trying again at the next start", err)
			b.vacuumFailed = true
			return rt.r
		}
		store.SettleAfterForgetting() // the new file was written through the log: fold it in, and the old size goes
		rt.r.Vacuumed, rt.r.VacuumTook = true, time.Since(started)
	}
	return rt.r
}

// pruneDay: keep the world's totals of a day, move the boundary past it, and delete its detail. false: stop the pass.
func (rt *retainer) pruneDay(day Window, now int64) bool {
	store := rt.b.Store
	base, ok := store.loadPruned()
	if !ok {
		through := day.End
		if first := store.FirstVerdictAt(); first != nil {
			through = min(through, *first)
		}
		base = pastTotals{Through: through, Lookahead: through + CoverMs}
	}
	// The totals of the day come from reading it, so read it before it goes (and without the lock: a day is a few MB).
	if base.Through < day.End {
		next := base.extend(store, day.End, now)
		for waited := 0; ; waited++ {
			moved := false
			if !rt.step("boundary", func() {
				// A world build in progress reads these days a day at a time: it would miss what is deleted under it.
				if rt.b.world.building == nil {
					store.AdvancePruned(next)
					moved = true
				}
			}) {
				return false
			}
			if moved {
				break
			}
			if waited >= rt.o.WorldWaits {
				rt.r.WaitedForWorld = true
				return false
			}
			time.Sleep(retainWorldWait)
		}
	}
	for {
		var n PruneCounts
		var took time.Duration
		limit := rt.rows
		if !rt.step("batch", func() {
			started := time.Now()
			n = store.PruneBatch(day.End, limit)
			took = time.Since(started)
		}) {
			return false
		}
		rt.r.Samples, rt.r.Verdicts, rt.r.ModelCalls, rt.r.OtherRows = rt.r.Samples+n.Samples, rt.r.Verdicts+n.Verdicts, rt.r.ModelCalls+n.ModelCalls, rt.r.OtherRows+n.Other
		if !n.full(limit) {
			return true
		}
		rt.tune(took)
	}
}
