package brain

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	sqlite "modernc.org/sqlite"
)

// The Store keeps everything the brain sees and decides in one SQLite file (~/.moku/moku.sqlite, or MOKU_DB), with
// the TypeScript brain's schema: the same tables, columns and additive migrations, so either brain opens the other's
// database. Time logic keys on the sample's timestamp, never the wall clock. Methods panic on a database error (the
// HTTP layer answers 500), as the TypeScript store threw.

type SampleRow struct {
	Screen
	ID   string
	TS   int64
	Text *string
}

type VerdictRow struct {
	SampleID   string
	TS         int64
	State      string
	ThreadID   *string
	Confidence float64
	Source     string
	Reason     string
	Activity   *string
	Category   *string
}

type ThreadRow struct {
	ID           string
	Title        string
	Summary      string
	Provisional  bool
	Activity     *string
	Category     *string
	TitleByPerson bool
	CreatedAt    int64
	LastActiveAt int64
}

type LearnedRuleRow struct {
	ID        int64
	BundleID  string
	AppName   string
	Host      *string
	PathPrefix *string
	Title     *string
	Effect    string // work | notWork
	ThreadID  *string
	Source    string // pat | markedWork | markedNotWork
	SampleID  *string
	CreatedAt int64
}

type TimelineRow struct {
	SampleID string
	TS       int64
	State    string
	Relabel  *string
	ThreadID *string
	Activity *string
	Category *string
	BundleID string
	AppName  string
	Title    string
	URL      *string
}

type ContextLabel struct {
	ThreadID  *string
	Activity  *string
	Category  *string
	TextHash  *string
	LabeledAt int64
	NewThread bool
	Reason    string
}

type CompletionRow struct {
	TS          int64
	Kind        string
	Label       string
	ThreadID    *string
	ThreadTitle *string
}

type ModelCallRecord struct {
	Purpose   string
	SampleID  *string
	ThreadID  *string
	Model     string
	OK        bool
	ErrorCode *string
	LatencyMs int64
	Attempts  int
	TokensIn  int64
	TokensOut int64
	CostUsd   *float64
	Input     any
	Output    any
}

const schema = `
CREATE TABLE IF NOT EXISTS samples (
  id TEXT PRIMARY KEY, ts INTEGER NOT NULL,
  bundle_id TEXT NOT NULL, app_name TEXT NOT NULL, title TEXT NOT NULL, url TEXT,
  text TEXT, text_source TEXT, text_hash TEXT,
  keys_per_minute INTEGER, clicks_per_minute INTEGER, scrolls_per_minute INTEGER, idle_seconds REAL,
  in_call INTEGER, sharing_screen INTEGER, mic_in_use INTEGER, camera_in_use INTEGER,
  received_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
CREATE INDEX IF NOT EXISTS samples_screen ON samples(bundle_id, title, ts);
-- Screen text lives in its own table (samples.text is no longer written). It's kept an hour: deleting a row of a table
-- that only holds text frees whole pages, which new text then reuses. Set to NULL inside samples it left every page
-- half empty for good, and the file kept the most text it had ever held (about 10 MB a day of use, 3 GB a year).
CREATE TABLE IF NOT EXISTS sample_text (
  id INTEGER PRIMARY KEY, sample_id TEXT NOT NULL UNIQUE, ts INTEGER NOT NULL, text TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS sample_text_ts ON sample_text(ts);

CREATE TABLE IF NOT EXISTS verdicts (
  sample_id TEXT PRIMARY KEY, ts INTEGER NOT NULL, state TEXT NOT NULL, thread_id TEXT,
  is_new_thread INTEGER NOT NULL, confidence REAL NOT NULL, source TEXT NOT NULL, reason TEXT NOT NULL,
  latency_ms INTEGER NOT NULL, created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS verdicts_ts ON verdicts(ts);

CREATE TABLE IF NOT EXISTS threads (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, summary TEXT NOT NULL, provisional INTEGER NOT NULL,
  created_at INTEGER NOT NULL, last_active_at INTEGER NOT NULL, origin_sample_id TEXT
);

CREATE TABLE IF NOT EXISTS learned_rules (
  id INTEGER PRIMARY KEY, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL, host TEXT, path_prefix TEXT, title TEXT,
  effect TEXT NOT NULL, thread_id TEXT, source TEXT NOT NULL, sample_id TEXT, created_at INTEGER NOT NULL, removed_at INTEGER
);
CREATE INDEX IF NOT EXISTS learned_rules_scope ON learned_rules(bundle_id, host);

CREATE TABLE IF NOT EXISTS relabels (sample_id TEXT PRIMARY KEY, state TEXT NOT NULL, feedback_ts INTEGER NOT NULL);

CREATE TABLE IF NOT EXISTS completions (
  id INTEGER PRIMARY KEY, sample_id TEXT NOT NULL, ts INTEGER NOT NULL, kind TEXT NOT NULL, label TEXT NOT NULL,
  thread_id TEXT, text_hash TEXT
);
CREATE INDEX IF NOT EXISTS completions_ts ON completions(ts);

CREATE TABLE IF NOT EXISTS context_activity (
  bundle_id TEXT NOT NULL, context_key TEXT NOT NULL, activity TEXT NOT NULL, created_at INTEGER NOT NULL,
  PRIMARY KEY (bundle_id, context_key)
);

CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS context_labels (
  key TEXT PRIMARY KEY, thread_id TEXT, activity TEXT, category TEXT, text_hash TEXT, labeled_at INTEGER NOT NULL,
  new_thread INTEGER NOT NULL DEFAULT 0, reason TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS feedback (
  id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, kind TEXT NOT NULL, sample_id TEXT, thread_id TEXT,
  received_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, type TEXT NOT NULL, thread_id TEXT, value REAL,
  received_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS events_type_ts ON events(type, ts);

-- Charles's calibration of goal-aware judging (calibrate.go): his rating of each moment, with what Moku said then.
CREATE TABLE IF NOT EXISTS goal_ratings (
  moment_id TEXT PRIMARY KEY, start INTEGER NOT NULL, end INTEGER NOT NULL, said TEXT NOT NULL, ok INTEGER NOT NULL,
  truth TEXT, truth_goal_id TEXT, truth_title TEXT, rated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS goal_ratings_start ON goal_ratings(start);
CREATE TABLE IF NOT EXISTS goal_edits (
  id INTEGER PRIMARY KEY, at INTEGER NOT NULL, kind TEXT NOT NULL, goal_id TEXT NOT NULL, into_id TEXT, title TEXT
);

CREATE TABLE IF NOT EXISTS model_calls (
  id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, purpose TEXT NOT NULL, sample_id TEXT, thread_id TEXT,
  model TEXT NOT NULL, ok INTEGER NOT NULL, error_code TEXT, latency_ms INTEGER NOT NULL, attempts INTEGER NOT NULL,
  tokens_in INTEGER NOT NULL, tokens_out INTEGER NOT NULL, cost_usd REAL, input TEXT NOT NULL, output TEXT
);

-- The input of a call that carried screen text (TextPurposes) is kept here for an hour, for the same reason as
-- sample_text; model_calls.input then says {"forgotten":true} from the start.
CREATE TABLE IF NOT EXISTS call_inputs (
  id INTEGER PRIMARY KEY, call_id INTEGER NOT NULL UNIQUE, ts INTEGER NOT NULL, input TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS call_inputs_ts ON call_inputs(ts);

-- So the retention pass finds the model calls older than 90 days without reading the table (retention.go).
CREATE INDEX IF NOT EXISTS model_calls_ts ON model_calls(ts);

-- A finished day's Your day, saved before the day's detail is deleted (retention.go): the summary as JSON, gzipped, one row
-- for each local date. Kept until "Delete my data".
CREATE TABLE IF NOT EXISTS day_summaries (
  date TEXT PRIMARY KEY, saved_at INTEGER NOT NULL, summary BLOB NOT NULL
);

-- What Luna wrote for a finished day (its note, and the lines under its goals), kept until the day's summary is saved with
-- them: the caches they live in are forgotten when the brain quits (retention.go).
CREATE TABLE IF NOT EXISTS day_words (
  date TEXT PRIMARY KEY, note TEXT, goal_lines TEXT
);
`

// Columns added after v0, created on open when missing.
var addedColumns = [][3]string{
	{"verdicts", "activity", "TEXT"},
	{"verdicts", "completion_kind", "TEXT"},
	{"verdicts", "completion_label", "TEXT"},
	{"threads", "activity", "TEXT"},
	{"verdicts", "category", "TEXT"},
	{"threads", "category", "TEXT"},
	{"threads", "named_by", "TEXT"},
	{"feedback", "segment_ids", "TEXT"},
}

const sampleColumns = "id, ts, bundle_id, app_name, title, url, text_hash, (SELECT t.text FROM sample_text t WHERE t.sample_id = samples.id)"

// MaxSafeInteger is Number.MAX_SAFE_INTEGER: "until forever" in time ranges.
const MaxSafeInteger = int64(9007199254740991)

type Store struct {
	db     *sql.DB
	path   string
	closed bool
	now    func() int64
	// edited: the earliest timeline moment a write has added or changed since the world cache last asked
	// (TakeEdits), so it knows when the finished days it keeps have changed.
	editMu sync.Mutex
	edited int64
	// pastLookahead: while the world's saved totals (meta "world_past") are in the database, the moment from which a
	// write no longer changes them (0 when none are saved). A write before it deletes them at once.
	pastLookahead atomic.Int64
	// prunedThrough: the moment before which the detail (samples, verdicts, model calls) is deleted or being deleted, so
	// Your day answers for those days from the summaries saved (0 when nothing has been pruned). See retention.go.
	prunedThrough atomic.Int64
	// wipes: how many times "Delete my data" has run, so work that read the store before it can tell, under the brain's lock,
	// that what it read is gone (retention.go).
	wipes atomic.Int64
}

func must(err error) {
	if err != nil {
		panic(fmt.Errorf("moku store: %w", err))
	}
}

// OpenStore opens (or creates) the database, owner-only, in WAL mode, and migrates it. A database that is damaged
// (not a database at all, or pages gone) is set aside as <path>.damaged, owner-only like the rest of ~/.moku, and a
// new one starts: a brain that can't open its file exits, the app tries it five times and rests ten minutes, and Moku
// would stay silent for good. The history in the damaged file is lost to Moku, never silently deleted.
func OpenStore(path string) (*Store, error) {
	store, err := openStore(path)
	if err == nil || path == ":memory:" || !isDamage(err) {
		return store, err
	}
	LogError(ErrStore, "moku brain: %s is damaged (%v); setting it aside as %s.damaged and starting a new one", path, err, path)
	for _, suffix := range []string{"", "-wal", "-shm"} {
		os.Remove(path + ".damaged" + suffix)
		if err := os.Rename(path+suffix, path+".damaged"+suffix); err != nil && !os.IsNotExist(err) {
			return nil, err
		}
	}
	return openStore(path)
}

// isDamage: whether err says the file isn't a healthy database (SQLite's "not a database" and "malformed"). A locked
// database, a full disk or a read-only folder are not damage, and must never cost anyone their history.
func isDamage(err error) bool {
	if errors.Is(err, errDamaged) {
		return true
	}
	var sqliteErr *sqlite.Error
	if !errors.As(err, &sqliteErr) {
		return false
	}
	const corrupt, notADatabase = 11, 26
	code := sqliteErr.Code() & 0xff
	return code == corrupt || code == notADatabase
}

var errDamaged = errors.New("the database failed its quick check")

// quickCheckMaxBytes: a database bigger than this isn't checked at every start (the check reads all of it).
const quickCheckMaxBytes = 1 << 30

func openStore(path string) (*Store, error) {
	if path != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return nil, err
		}
	}
	dsn := path
	if path != ":memory:" {
		// Deleted text is overwritten with zeros, on every connection, not left in the file's free space.
		dsn = path + "?_pragma=secure_delete(ON)"
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// One connection: every statement sees the one before it (and :memory: stays one database).
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(0)
	fail := func(err error) (*Store, error) {
		db.Close()
		return nil, err
	}
	if err := db.Ping(); err != nil {
		return fail(err)
	}
	if path != ":memory:" {
		os.Chmod(path, 0o600) // screen text is private
	}
	for _, stmt := range []string{"PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL", "PRAGMA busy_timeout = 5000", "PRAGMA secure_delete = ON"} {
		if _, err := db.Exec(stmt); err != nil {
			return fail(err)
		}
	}
	if _, err := db.Exec(schema); err != nil {
		return fail(err)
	}
	s := &Store{db: db, path: path, now: func() int64 { return time.Now().UnixMilli() }, edited: MaxSafeInteger}
	if err := s.migrate(); err != nil {
		return fail(err)
	}
	s.loadPruned()
	if info, statErr := os.Stat(path); statErr == nil && info.Size() <= quickCheckMaxBytes && path != ":memory:" {
		var verdict string
		if err := db.QueryRow(`PRAGMA quick_check(1)`).Scan(&verdict); err != nil {
			return fail(err)
		}
		if verdict != "ok" {
			return fail(fmt.Errorf("%w: %s", errDamaged, verdict))
		}
	}
	return s, nil
}

func (s *Store) migrate() error {
	for _, c := range addedColumns {
		rows, err := s.db.Query(fmt.Sprintf("PRAGMA table_info(%s)", c[0]))
		if err != nil {
			return err
		}
		found := false
		for rows.Next() {
			var cid int
			var name, typ string
			var notNull, pk int
			var dflt sql.NullString
			if err := rows.Scan(&cid, &name, &typ, &notNull, &dflt, &pk); err != nil {
				rows.Close()
				return err
			}
			if name == c[1] {
				found = true
			}
		}
		rows.Close()
		if !found {
			if _, err := s.db.Exec(fmt.Sprintf("ALTER TABLE %s ADD COLUMN %s %s", c[0], c[1], c[2])); err != nil {
				return err
			}
		}
	}
	if err := s.splitOutScreenText(); err != nil {
		return err
	}
	// 0.1.7 ran an experiment (shadow mode for fewer Jev calls) that kept a row per judgment in reuse_shadow; the code
	// that wrote and read it is gone.
	if _, err := s.db.Exec(`DROP TABLE IF EXISTS reuse_shadow`); err != nil {
		return err
	}
	var one int
	if s.db.QueryRow(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'overrides'`).Scan(&one) == nil {
		_, err := s.db.Exec(`
      INSERT INTO learned_rules (bundle_id, app_name, host, path_prefix, title, effect, thread_id, source, sample_id, created_at)
      SELECT o.bundle_id, COALESCE(s.app_name, o.bundle_id),
        CASE WHEN o.context_key LIKE 'site:%' THEN substr(o.context_key, 6) END, NULL,
        CASE WHEN o.context_key LIKE 'title:%' THEN substr(o.context_key, 7) END,
        'work', o.thread_id, 'pat', o.sample_id, o.created_at
      FROM overrides o LEFT JOIN samples s ON s.id = o.sample_id;
      DROP TABLE overrides;`)
		return err
	}
	return nil
}

// splitOutScreenText moves the screen text still held in samples.text and model_calls.input into their own tables (once,
// meta "text_split"), then rewrites the file (VACUUM), which gives back the half-empty pages all the text that was ever
// forgotten left behind. If the rewrite can't be made (the disk is nearly full) it's tried again at the next start.
func (s *Store) splitOutScreenText() error {
	if s.Meta("text_split") != nil {
		return nil
	}
	marks := strings.TrimSuffix(strings.Repeat("?,", len(TextPurposes)), ",")
	purposes := make([]any, len(TextPurposes))
	for i, p := range TextPurposes {
		purposes[i] = p
	}
	var moved int64
	for _, stmt := range []struct {
		sql  string
		args []any
	}{
		{`INSERT OR REPLACE INTO sample_text (sample_id, ts, text) SELECT id, ts, text FROM samples WHERE text IS NOT NULL ORDER BY ts, rowid`, nil},
		{`UPDATE samples SET text = NULL WHERE text IS NOT NULL`, nil},
		{`INSERT OR IGNORE INTO call_inputs (call_id, ts, input) SELECT id, ts, input FROM model_calls WHERE purpose IN (` + marks + `) AND input != '` + forgottenInput + `' ORDER BY id`, purposes},
		{`UPDATE model_calls SET input = '` + forgottenInput + `' WHERE purpose IN (` + marks + `) AND input != '` + forgottenInput + `'`, purposes},
	} {
		r, err := s.db.Exec(stmt.sql, stmt.args...)
		if err != nil {
			return err
		}
		n, _ := r.RowsAffected()
		moved += n
	}
	s.db.Exec(`DROP INDEX IF EXISTS samples_text`)
	var pages int64
	s.db.QueryRow(`PRAGMA page_count`).Scan(&pages)
	if pages > 32 { // a new database has nothing to give back
		if _, err := s.db.Exec(`VACUUM`); err != nil {
			LogError(ErrDisk, "moku brain: couldn't rewrite the database to give back the space screen text left (%v); trying again at the next start", err)
			return nil
		}
	}
	_, err := s.db.Exec(`INSERT OR REPLACE INTO meta VALUES ('text_split', ?)`, fmt.Sprint(moved))
	return err
}

// Close folds the write-ahead log into the database file, then closes it.
func (s *Store) Close() {
	if s.closed {
		return
	}
	s.closed = true
	s.db.Exec("PRAGMA wal_checkpoint(TRUNCATE)")
	s.db.Close()
}

func (s *Store) exec(query string, args ...any) sql.Result {
	r, err := s.db.Exec(query, args...)
	must(err)
	return r
}

func changes(r sql.Result) int64 { n, _ := r.RowsAffected(); return n }

func (s *Store) tx(fn func(tx *sql.Tx)) {
	tx, err := s.db.Begin()
	must(err)
	defer func() {
		if p := recover(); p != nil {
			tx.Rollback()
			panic(p)
		}
	}()
	fn(tx)
	must(tx.Commit())
}

func str(n sql.NullString) *string {
	if !n.Valid {
		return nil
	}
	v := n.String
	return &v
}

func nullable(p *string) any {
	if p == nil {
		return nil
	}
	return *p
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

type scanner interface{ Scan(...any) error }

func scanSample(r scanner) (*SampleRow, error) {
	var row SampleRow
	var url, hash, text sql.NullString
	if err := r.Scan(&row.ID, &row.TS, &row.BundleID, &row.AppName, &row.Title, &url, &hash, &text); err != nil {
		return nil, err
	}
	row.URL, row.TextHash, row.Text = str(url), str(hash), str(text)
	return &row, nil
}

func (s *Store) oneSample(query string, args ...any) *SampleRow {
	row, err := scanSample(s.db.QueryRow(query, args...))
	if err == sql.ErrNoRows {
		return nil
	}
	must(err)
	return row
}

// ── Samples ─────────────────────────────────────────────────────────────────────────────────────────────────────

func (s *Store) InsertSample(x ActivitySample) {
	s.noteEdit(x.Ts())
	title := ""
	var url *string
	if x.Window != nil {
		title, url = x.Window.Title, x.Window.URL
	}
	s.exec(`INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		x.ID, x.Ts(), x.App.BundleID, x.App.Name, title, nullable(url),
		nil, nullable(x.TextSource), nullable(x.TextHash), // the text itself goes to sample_text
		int64(x.Activity.KeysPerMinute), int64(x.Activity.ClicksPerMinute), int64(x.Activity.ScrollsPerMinute), x.Activity.IdleSeconds,
		boolInt(x.Context.InCall), boolInt(x.Context.SharingScreen), boolInt(x.Context.MicInUse), boolInt(x.Context.CameraInUse),
		s.now())
	if x.Text != nil {
		s.exec(`INSERT OR REPLACE INTO sample_text (sample_id, ts, text) VALUES (?,?,?)`, x.ID, x.Ts(), *x.Text)
	}
}

func (s *Store) Sample(id string) *SampleRow {
	return s.oneSample(`SELECT `+sampleColumns+` FROM samples WHERE id = ?`, id)
}

func (s *Store) LatestSample() *SampleRow {
	return s.oneSample(`SELECT ` + sampleColumns + ` FROM samples ORDER BY ts DESC, rowid DESC LIMIT 1`)
}

// PreviousSample: the sample just before ts (the one this sample is compared with for "unchanged screen").
func (s *Store) PreviousSample(ts int64, excludeID string) *SampleRow {
	return s.oneSample(`SELECT `+sampleColumns+` FROM samples WHERE ts <= ? AND id != ? ORDER BY ts DESC, rowid DESC LIMIT 1`, ts, excludeID)
}

// LastText: the last text (and its hash) seen for this app, window and text hash (any hash when the screen has none).
func (s *Store) LastText(screen Screen, ts int64, excludeID string) (text string, hash *string, ok bool) {
	var t string
	var h sql.NullString
	err := s.db.QueryRow(`SELECT t.text, s.text_hash FROM sample_text t JOIN samples s ON s.id = t.sample_id
        WHERE s.bundle_id = ? AND s.title = ? AND (? IS NULL OR s.text_hash = ?) AND t.ts <= ? AND s.id != ? ORDER BY t.ts DESC LIMIT 1`,
		screen.BundleID, screen.Title, nullable(screen.TextHash), nullable(screen.TextHash), ts, excludeID).Scan(&t, &h)
	if err == sql.ErrNoRows {
		return "", nil, false
	}
	must(err)
	return t, str(h), true
}

// ── Verdicts ────────────────────────────────────────────────────────────────────────────────────────────────────

func (s *Store) InsertVerdict(v Verdict, ts int64) {
	s.noteEdit(ts)
	var threadID, kind, label *string
	if v.Thread != nil {
		threadID = &v.Thread.ID
	}
	if v.Completion != nil {
		kind, label = &v.Completion.Kind, &v.Completion.Label
	}
	s.exec(`INSERT OR REPLACE INTO verdicts (sample_id, ts, state, thread_id, is_new_thread, confidence, source, reason, latency_ms,
        created_at, activity, completion_kind, completion_label, category) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		v.SampleID, ts, v.State, nullable(threadID), boolInt(v.IsNewThread), v.Confidence, v.Source, v.Reason, v.LatencyMs, s.now(),
		nullable(v.Activity), nullable(kind), nullable(label), nullable(v.Category))
}

func scanVerdict(r scanner, extra ...any) (*VerdictRow, error) {
	var v VerdictRow
	var thread, activity, category sql.NullString
	dest := append([]any{&v.SampleID, &v.TS, &v.State, &thread, &v.Confidence, &v.Source, &v.Reason, &activity, &category}, extra...)
	if err := r.Scan(dest...); err != nil {
		return nil, err
	}
	v.ThreadID, v.Activity, v.Category = str(thread), str(activity), str(category)
	return &v, nil
}

const verdictColumns = "v.sample_id, v.ts, v.state, v.thread_id, v.confidence, v.source, v.reason, v.activity, v.category"

// RecentJevVerdict: the latest real Jev (or local model) verdict, working or drifting, on exactly this screen within
// [since, until].
func (s *Store) RecentJevVerdict(screen Screen, since, until int64, excludeID string) *VerdictRow {
	v, err := scanVerdict(s.db.QueryRow(`SELECT `+verdictColumns+` FROM verdicts v JOIN samples s ON s.id = v.sample_id
        WHERE s.bundle_id = ? AND s.title = ? AND s.url IS ? AND s.text_hash IS ? AND s.ts BETWEEN ? AND ? AND s.id != ?
          AND v.source IN ('jev', 'local') AND v.state IN ('working', 'drifting')
        ORDER BY s.ts DESC LIMIT 1`, screen.BundleID, screen.Title, nullable(screen.URL), nullable(screen.TextHash), since, until, excludeID))
	if err == sql.ErrNoRows {
		return nil
	}
	must(err)
	return v
}

// CurrentThread: the thread of the latest working verdict at or before ts (and after since), with when its current
// run started: the run ends at work on another thread or at away; drifts inside it don't end it.
func (s *Store) CurrentThread(ts, since int64, excludeID string) (thread *ThreadRow, runStartedAt, lastAt int64, ok bool) {
	var threadID string
	var last int64
	err := s.db.QueryRow(`SELECT thread_id, ts FROM verdicts WHERE state = 'working' AND thread_id IS NOT NULL
        AND ts <= ? AND ts >= ? AND sample_id != ? ORDER BY ts DESC LIMIT 1`, ts, since, excludeID).Scan(&threadID, &last)
	if err == sql.ErrNoRows {
		return nil, 0, 0, false
	}
	must(err)
	var boundary sql.NullInt64
	must(s.db.QueryRow(`SELECT MAX(ts) AS ts FROM verdicts WHERE ts <= ? AND sample_id != ?
        AND ((state = 'working' AND thread_id IS NOT NULL AND thread_id != ?) OR state = 'away')`, ts, excludeID, threadID).Scan(&boundary))
	b := int64(-1)
	if boundary.Valid {
		b = boundary.Int64
	}
	var start sql.NullInt64
	must(s.db.QueryRow(`SELECT MIN(ts) AS ts FROM verdicts WHERE ts > ? AND ts <= ? AND state = 'working' AND thread_id = ?`, b, ts, threadID).Scan(&start))
	current := s.Thread(threadID)
	if current == nil {
		return nil, 0, 0, false
	}
	runStart := last
	if start.Valid {
		runStart = start.Int64
	}
	return current, runStart, last, true
}

// LastWorkThread: the thread of the latest working verdict with one in [since, ts] (goal-aware judging's current goal).
func (s *Store) LastWorkThread(ts, since int64, excludeID string) (id string, at int64, ok bool) {
	err := s.db.QueryRow(`SELECT thread_id, ts FROM verdicts WHERE state = 'working' AND thread_id IS NOT NULL
        AND ts <= ? AND ts >= ? AND sample_id != ? ORDER BY ts DESC LIMIT 1`, ts, since, excludeID).Scan(&id, &at)
	if err == sql.ErrNoRows {
		return "", 0, false
	}
	must(err)
	return id, at, true
}

// FirstVerdictFrom: the first verdict at or after ts, or nil.
func (s *Store) FirstVerdictFrom(ts int64) *int64 {
	var first sql.NullInt64
	must(s.db.QueryRow(`SELECT MIN(ts) FROM verdicts WHERE ts >= ?`, ts).Scan(&first))
	if !first.Valid {
		return nil
	}
	return &first.Int64
}

// savePast keeps the world's totals of the past (world.go), so the next start doesn't read the history.
func (s *Store) savePast(p pastTotals) {
	s.exec(`INSERT OR REPLACE INTO meta VALUES (?, ?)`, worldPastKey, JSON(p))
	s.pastLookahead.Store(p.Lookahead)
}

// loadPast: the saved totals, if there are any and they make sense.
func (s *Store) loadPast() (pastTotals, bool) {
	saved := s.Meta(worldPastKey)
	if saved == nil {
		return pastTotals{}, false
	}
	var p pastTotals
	if json.Unmarshal([]byte(*saved), &p) != nil || p.Through <= 0 || p.Lookahead < p.Through || p.FocusMs < 0 {
		s.forgetPast()
		return pastTotals{}, false
	}
	s.pastLookahead.Store(p.Lookahead)
	return p, true
}

// forgetPast drops the saved totals: a write changed the time they cover.
func (s *Store) forgetPast() {
	s.pastLookahead.Store(0)
	s.exec(`DELETE FROM meta WHERE key = ?`, worldPastKey)
}

// FirstVerdictAt: when the first verdict was made, or nil.
func (s *Store) FirstVerdictAt() *int64 {
	var ts sql.NullInt64
	must(s.db.QueryRow(`SELECT MIN(ts) AS ts FROM verdicts`).Scan(&ts))
	if !ts.Valid {
		return nil
	}
	return &ts.Int64
}

// Timeline: verdicts in [since, until) in time order, with their screen and any relabel.
func (s *Store) Timeline(since, until int64) []TimelineRow {
	rows, err := s.db.Query(`SELECT v.sample_id, v.ts, v.state, v.thread_id, v.activity, v.category, s.bundle_id, s.app_name, s.title, s.url, r.state AS relabel
        FROM verdicts v JOIN samples s ON s.id = v.sample_id LEFT JOIN relabels r ON r.sample_id = v.sample_id
        WHERE v.ts >= ? AND v.ts < ? ORDER BY v.ts, v.rowid`, since, until)
	must(err)
	defer rows.Close()
	var out []TimelineRow
	for rows.Next() {
		var r TimelineRow
		var thread, activity, category, url, relabel sql.NullString
		must(rows.Scan(&r.SampleID, &r.TS, &r.State, &thread, &activity, &category, &r.BundleID, &r.AppName, &r.Title, &url, &relabel))
		r.ThreadID, r.Activity, r.Category, r.URL, r.Relabel = str(thread), str(activity), str(category), str(url), str(relabel)
		out = append(out, r)
	}
	must(rows.Err())
	return out
}

// KnownBefore: the carry (spanCarry) as it stands just before ts: the last state a verdict settled (its relabel when it
// has one; unknown settles nothing) and its thread. A day read from its own morning then treats an unknown verdict as
// a read of the whole history does: the world counted a morning of unknown after last night's work as focus, and Your
// day, reading from an hour before midnight, didn't (2026-10-08).
func (s *Store) KnownBefore(ts int64) spanCarry {
	var state string
	var relabel, thread sql.NullString
	err := s.db.QueryRow(`SELECT v.state, r.state, v.thread_id FROM verdicts v JOIN samples s ON s.id = v.sample_id LEFT JOIN relabels r ON r.sample_id = v.sample_id
        WHERE v.ts < ? AND COALESCE(r.state, v.state) != 'unknown' ORDER BY v.ts DESC, v.rowid DESC LIMIT 1`, ts).Scan(&state, &relabel, &thread)
	if err == sql.ErrNoRows {
		return spanCarry{}
	}
	must(err)
	var carry spanCarry
	carry.follow(TimelineRow{State: state, Relabel: str(relabel), ThreadID: str(thread)})
	return carry
}

// Relabel: "This was work" / "This wasn't work" on past samples; the verdicts themselves stay as judged.
func (s *Store) Relabel(sampleIDs []string, state string, at int64) {
	s.tx(func(tx *sql.Tx) {
		for _, id := range sampleIDs {
			_, err := tx.Exec(`INSERT OR REPLACE INTO relabels VALUES (?,?,?)`, id, state, at)
			must(err)
		}
	})
	s.noteEditedSamples(sampleIDs)
}

// noteEdit: the timeline at ts (and after) has changed.
func (s *Store) noteEdit(ts int64) {
	s.editMu.Lock()
	s.edited = min(s.edited, ts)
	s.editMu.Unlock()
	if look := s.pastLookahead.Load(); look > 0 && ts < look {
		s.forgetPast()
	}
}

// noteEditedSamples: these samples' verdicts have changed.
func (s *Store) noteEditedSamples(ids []string) {
	if len(ids) == 0 {
		return
	}
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	var first sql.NullInt64
	must(s.db.QueryRow(`SELECT MIN(ts) FROM verdicts WHERE sample_id IN (?`+strings.Repeat(",?", len(ids)-1)+`)`, args...).Scan(&first))
	if first.Valid {
		s.noteEdit(first.Int64)
	}
}

// TakeEdits: the earliest timeline moment added or changed since the last call (MaxSafeInteger when none).
func (s *Store) TakeEdits() int64 {
	s.editMu.Lock()
	defer s.editMu.Unlock()
	edited := s.edited
	s.edited = MaxSafeInteger
	return edited
}

// ── Threads ─────────────────────────────────────────────────────────────────────────────────────────────────────

func scanThread(r scanner) (*ThreadRow, error) {
	var t ThreadRow
	var provisional int
	var activity, category, namedBy sql.NullString
	if err := r.Scan(&t.ID, &t.Title, &t.Summary, &provisional, &t.CreatedAt, &t.LastActiveAt, &activity, &category, &namedBy); err != nil {
		return nil, err
	}
	t.Provisional = provisional == 1
	t.Activity, t.Category = str(activity), str(category)
	t.TitleByPerson = namedBy.Valid && namedBy.String == "person"
	return &t, nil
}

const threadColumns = "id, title, summary, provisional, created_at, last_active_at, activity, category, named_by"

func (s *Store) CreateThread(id, title, summary string, at int64, originSampleID *string) *ThreadRow {
	s.exec(`INSERT INTO threads (id, title, summary, provisional, created_at, last_active_at, origin_sample_id) VALUES (?,?,?,1,?,?,?)`,
		id, title, summary, at, at, nullable(originSampleID))
	return s.Thread(id)
}

func (s *Store) Thread(id string) *ThreadRow {
	t, err := scanThread(s.db.QueryRow(`SELECT `+threadColumns+` FROM threads WHERE id = ?`, id))
	if err == sql.ErrNoRows {
		return nil
	}
	must(err)
	return t
}

// Threads: most recently active first.
func (s *Store) Threads(since int64, limit int) []ThreadRow {
	rows, err := s.db.Query(`SELECT `+threadColumns+` FROM threads WHERE last_active_at >= ? ORDER BY last_active_at DESC LIMIT ?`, since, limit)
	must(err)
	defer rows.Close()
	var out []ThreadRow
	for rows.Next() {
		t, err := scanThread(rows)
		must(err)
		out = append(out, *t)
	}
	must(rows.Err())
	return out
}

func (s *Store) AllThreads() []ThreadRow { return s.Threads(0, 1000) }

// NameThread: Luna's name. A title the person set stays: only the summary (and a missing activity) are filled in.
func (s *Store) NameThread(id, title, summary string, activity *string) {
	s.exec(`UPDATE threads SET title = CASE WHEN named_by = 'person' THEN title ELSE ? END, summary = ?, provisional = 0,
        activity = CASE WHEN named_by = 'person' THEN COALESCE(activity, ?) ELSE COALESCE(?, activity) END WHERE id = ?`,
		title, summary, nullable(activity), nullable(activity), id)
}

// SetThreadTitleByPerson: the person's own title, final. Their words also become the activity when short enough.
func (s *Store) SetThreadTitleByPerson(id, title string, activity *string) bool {
	return changes(s.exec(`UPDATE threads SET title = ?, provisional = 0, named_by = 'person', activity = COALESCE(?, activity) WHERE id = ?`,
		title, nullable(activity), id)) > 0
}

func (s *Store) SetThreadCategory(id, category string) {
	s.exec(`UPDATE threads SET category = ? WHERE id = ?`, category, id)
}

// RenameThread: the one-time rename to the person's own words.
func (s *Store) RenameThread(id, title, summary string, activity *string) {
	s.exec(`UPDATE threads SET title = ?, summary = ?, activity = COALESCE(?, activity) WHERE id = ? AND named_by IS NOT 'person'`,
		title, summary, nullable(activity), id)
}

// UpdateThreadCategory: a thread takes the bucket most of its verdicts have.
func (s *Store) UpdateThreadCategory(id string) {
	s.exec(`UPDATE threads SET category = (SELECT category FROM verdicts WHERE thread_id = ? AND category IS NOT NULL
        GROUP BY category ORDER BY COUNT(*) DESC LIMIT 1) WHERE id = ?`, id, id)
}

type ThreadScreen struct {
	SampleRow
	Seen int64
}

// ThreadScreens: the distinct screens a thread was seen on, most seen first.
func (s *Store) ThreadScreens(id string, limit int) []ThreadScreen {
	rows, err := s.db.Query(`SELECT s.bundle_id, s.app_name, s.title, s.url, COUNT(*) AS seen,
          (SELECT t.text FROM sample_text t JOIN samples x ON x.id = t.sample_id JOIN verdicts y ON y.sample_id = x.id
            WHERE y.thread_id = ? AND x.bundle_id = s.bundle_id AND x.title = s.title ORDER BY t.ts DESC LIMIT 1) AS text
        FROM verdicts v JOIN samples s ON s.id = v.sample_id WHERE v.thread_id = ?
        GROUP BY s.bundle_id, s.title, s.url ORDER BY seen DESC LIMIT ?`, id, id, limit)
	must(err)
	defer rows.Close()
	var out []ThreadScreen
	for rows.Next() {
		var r ThreadScreen
		var url, text sql.NullString
		must(rows.Scan(&r.BundleID, &r.AppName, &r.Title, &url, &r.Seen, &text))
		r.URL, r.Text = str(url), str(text)
		out = append(out, r)
	}
	must(rows.Err())
	return out
}

type ThreadOnApp struct {
	ThreadID string
	URL      *string
}

// RecentThreadsOn: the threads of the latest working verdicts at ts or before on this app.
func (s *Store) RecentThreadsOn(bundleID string, ts int64, limit int) []ThreadOnApp {
	rows, err := s.db.Query(`SELECT v.thread_id, s.url FROM verdicts v JOIN samples s ON s.id = v.sample_id
        WHERE s.bundle_id = ? AND v.state = 'working' AND v.thread_id IS NOT NULL AND v.ts <= ? ORDER BY v.ts DESC LIMIT ?`, bundleID, ts, limit)
	must(err)
	defer rows.Close()
	var out []ThreadOnApp
	for rows.Next() {
		var r ThreadOnApp
		var url sql.NullString
		must(rows.Scan(&r.ThreadID, &url))
		r.URL = str(url)
		out = append(out, r)
	}
	must(rows.Err())
	return out
}

// OriginSample: the screen a thread started on.
func (s *Store) OriginSample(threadID string) *SampleRow {
	// (Not by prefixing sampleColumns with an alias: its last column is a sub-select, and "s.(SELECT …)" is a syntax error
	// that stopped the start-up thread upkeep for any database that still had to rename its threads.)
	return s.oneSample(`SELECT `+sampleColumns+` FROM samples WHERE id = (SELECT origin_sample_id FROM threads WHERE id = ?)`, threadID)
}

// ── Labeling ────────────────────────────────────────────────────────────────────────────────────────────────────

func (s *Store) ContextLabel(key string) *ContextLabel {
	var l ContextLabel
	var thread, activity, category, hash sql.NullString
	var newThread int
	err := s.db.QueryRow(`SELECT thread_id, activity, category, text_hash, labeled_at, new_thread, reason FROM context_labels WHERE key = ?`, key).
		Scan(&thread, &activity, &category, &hash, &l.LabeledAt, &newThread, &l.Reason)
	if err == sql.ErrNoRows {
		return nil
	}
	must(err)
	l.ThreadID, l.Activity, l.Category, l.TextHash, l.NewThread = str(thread), str(activity), str(category), str(hash), newThread == 1
	return &l
}

func (s *Store) SetContextLabel(key string, l ContextLabel) {
	s.exec(`INSERT OR REPLACE INTO context_labels (key, thread_id, activity, category, text_hash, labeled_at, new_thread, reason) VALUES (?,?,?,?,?,?,?,?)`,
		key, nullable(l.ThreadID), nullable(l.Activity), nullable(l.Category), nullable(l.TextHash), l.LabeledAt, boolInt(l.NewThread), l.Reason)
}

// TakeNewThread: true once, for the first verdict to carry a thread the labeler started.
func (s *Store) TakeNewThread(key string) bool {
	return changes(s.exec(`UPDATE context_labels SET new_thread = 0 WHERE key = ? AND new_thread = 1`, key)) > 0
}

var likeSpecial = regexp.MustCompile(`[\\%_]`)

// ForgetContextLabels: a context is labeled again (in both states), after a pat, say.
func (s *Store) ForgetContextLabels(keySuffix string) {
	s.exec(`DELETE FROM context_labels WHERE key LIKE ? ESCAPE '\'`, "%|"+likeSpecial.ReplaceAllString(keySuffix, `\$0`))
}

// WriteLabels writes the labeler's result into verdicts stored before it was known.
func (s *Store) WriteLabels(sampleIDs []string, threadID, activity, category *string) {
	s.tx(func(tx *sql.Tx) {
		for _, id := range sampleIDs {
			_, err := tx.Exec(`UPDATE verdicts SET thread_id = ?, activity = ?, category = ? WHERE sample_id = ?`, nullable(threadID), nullable(activity), nullable(category), id)
			must(err)
			if threadID != nil {
				_, err = tx.Exec(`UPDATE completions SET thread_id = ? WHERE sample_id = ? AND thread_id IS NULL`, *threadID, id)
				must(err)
			}
		}
	})
	s.noteEditedSamples(sampleIDs)
}

// Verdict: one stored verdict with its labels.
func (s *Store) Verdict(sampleID string) (*VerdictRow, bool) {
	var isNew int
	v, err := scanVerdict(s.db.QueryRow(`SELECT `+verdictColumns+`, v.is_new_thread FROM verdicts v WHERE sample_id = ?`, sampleID), &isNew)
	if err == sql.ErrNoRows {
		return nil, false
	}
	must(err)
	return v, isNew == 1
}

// ── One-time jobs ───────────────────────────────────────────────────────────────────────────────────────────────

func (s *Store) Meta(key string) *string {
	var v string
	err := s.db.QueryRow(`SELECT value FROM meta WHERE key = ?`, key).Scan(&v)
	if err == sql.ErrNoRows {
		return nil
	}
	must(err)
	return &v
}

func (s *Store) SetMeta(key, value string) { s.exec(`INSERT OR REPLACE INTO meta VALUES (?, ?)`, key, value) }

func (s *Store) SetThreadActivity(id, activity string) {
	s.exec(`UPDATE threads SET activity = ? WHERE id = ?`, activity, id)
}

// ForgetThread: its verdicts keep their state but lose the link, its completions too, learned rules pointing at it
// lose it, and the thread row goes.
func (s *Store) ForgetThread(id string) (unlinkedVerdicts, unlinkedRules int64, ok bool) {
	if s.Thread(id) == nil {
		return 0, 0, false
	}
	s.noteEdit(0)
	s.tx(func(tx *sql.Tx) {
		r, err := tx.Exec(`UPDATE verdicts SET thread_id = NULL WHERE thread_id = ?`, id)
		must(err)
		unlinkedVerdicts = changes(r)
		r, err = tx.Exec(`UPDATE learned_rules SET thread_id = NULL WHERE thread_id = ? AND removed_at IS NULL`, id)
		must(err)
		unlinkedRules = changes(r)
		for _, q := range []string{`UPDATE completions SET thread_id = NULL WHERE thread_id = ?`, `DELETE FROM context_labels WHERE thread_id = ?`, `DELETE FROM threads WHERE id = ?`} {
			_, err = tx.Exec(q, id)
			must(err)
		}
	})
	return unlinkedVerdicts, unlinkedRules, true
}

// MergeThread: a duplicate goal folds into the one it repeats. Everything that pointed at `from` points at `into`, which
// keeps its own name and takes the later last-active time; `from` goes.
func (s *Store) MergeThread(from, into string) bool {
	if from == into || s.Thread(from) == nil || s.Thread(into) == nil {
		return false
	}
	var first sql.NullInt64
	must(s.db.QueryRow(`SELECT MIN(ts) FROM verdicts WHERE thread_id = ?`, from).Scan(&first))
	if first.Valid {
		s.noteEdit(first.Int64)
	}
	s.tx(func(tx *sql.Tx) {
		for _, q := range []string{
			`UPDATE verdicts SET thread_id = ? WHERE thread_id = ?`,
			`UPDATE learned_rules SET thread_id = ? WHERE thread_id = ?`,
			`UPDATE completions SET thread_id = ? WHERE thread_id = ?`,
			`UPDATE context_labels SET thread_id = ? WHERE thread_id = ?`,
			`UPDATE events SET thread_id = ? WHERE thread_id = ?`,
			`UPDATE feedback SET thread_id = ? WHERE thread_id = ?`,
		} {
			_, err := tx.Exec(q, into, from)
			must(err)
		}
		_, err := tx.Exec(`UPDATE threads SET last_active_at = MAX(last_active_at, (SELECT last_active_at FROM threads WHERE id = ?)) WHERE id = ?`, from, into)
		must(err)
		_, err = tx.Exec(`DELETE FROM threads WHERE id = ?`, from)
		must(err)
	})
	return true
}

// FillThreadLabels: verdicts on a goal that were stored before it had its phrase and bucket (a new goal, before Luna
// named it) take them now.
func (s *Store) FillThreadLabels(id string) {
	var first sql.NullInt64
	must(s.db.QueryRow(`SELECT MIN(ts) FROM verdicts WHERE thread_id = ? AND (activity IS NULL OR category IS NULL)`, id).Scan(&first))
	if !first.Valid {
		return
	}
	r := s.exec(`UPDATE verdicts SET activity = COALESCE(activity, (SELECT activity FROM threads WHERE id = ?)),
        category = COALESCE(category, (SELECT category FROM threads WHERE id = ?)) WHERE thread_id = ? AND (activity IS NULL OR category IS NULL)`, id, id, id)
	if changes(r) > 0 {
		s.noteEdit(first.Int64)
	}
}

func (s *Store) TouchThread(id string, ts int64) {
	s.exec(`UPDATE threads SET last_active_at = MAX(last_active_at, ?) WHERE id = ?`, ts, id)
}

// ── Activity for work without a thread, once per context ────────────────────────────────────────────────────

func (s *Store) ContextActivity(bundleID, contextKey string) *string {
	var v string
	err := s.db.QueryRow(`SELECT activity FROM context_activity WHERE bundle_id = ? AND context_key = ?`, bundleID, contextKey).Scan(&v)
	if err == sql.ErrNoRows {
		return nil
	}
	must(err)
	return &v
}

func (s *Store) SetContextActivity(bundleID, contextKey, activity string) {
	s.exec(`INSERT OR REPLACE INTO context_activity VALUES (?,?,?,?)`, bundleID, contextKey, activity, s.now())
}

// ── Learned rules ───────────────────────────────────────────────────────────────────────────────────────────────

func scanLearned(r scanner) (*LearnedRuleRow, error) {
	var l LearnedRuleRow
	var host, prefix, title, thread, sample sql.NullString
	if err := r.Scan(&l.ID, &l.BundleID, &l.AppName, &host, &prefix, &title, &l.Effect, &thread, &l.Source, &sample, &l.CreatedAt); err != nil {
		return nil, err
	}
	l.Host, l.PathPrefix, l.Title, l.ThreadID, l.SampleID = str(host), str(prefix), str(title), str(thread), str(sample)
	return &l, nil
}

const learnedColumns = "id, bundle_id, app_name, host, path_prefix, title, effect, thread_id, source, sample_id, created_at"

func (s *Store) learnedRules(query string, args ...any) []LearnedRuleRow {
	rows, err := s.db.Query(query, args...)
	must(err)
	defer rows.Close()
	var out []LearnedRuleRow
	for rows.Next() {
		l, err := scanLearned(rows)
		must(err)
		out = append(out, *l)
	}
	must(rows.Err())
	return out
}

func (s *Store) InsertLearnedRule(r LearnedRuleRow) *LearnedRuleRow {
	result := s.exec(`INSERT INTO learned_rules (bundle_id, app_name, host, path_prefix, title, effect, thread_id, source, sample_id, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?)`, r.BundleID, r.AppName, nullable(r.Host), nullable(r.PathPrefix), nullable(r.Title), r.Effect,
		nullable(r.ThreadID), r.Source, nullable(r.SampleID), r.CreatedAt)
	id, _ := result.LastInsertId()
	return s.LearnedRule(id)
}

func (s *Store) LearnedRule(id int64) *LearnedRuleRow {
	l, err := scanLearned(s.db.QueryRow(`SELECT `+learnedColumns+` FROM learned_rules WHERE id = ? AND removed_at IS NULL`, id))
	if err == sql.ErrNoRows {
		return nil
	}
	must(err)
	return l
}

// LearnedRulesFor: active rules that could apply to this app and host.
func (s *Store) LearnedRulesFor(bundleID string, host *string) []LearnedRuleRow {
	return s.learnedRules(`SELECT `+learnedColumns+` FROM learned_rules WHERE bundle_id = ? AND host IS ? AND removed_at IS NULL`, bundleID, nullable(host))
}

func (s *Store) LearnedRules() []LearnedRuleRow {
	return s.learnedRules(`SELECT ` + learnedColumns + ` FROM learned_rules WHERE removed_at IS NULL ORDER BY created_at DESC, id DESC`)
}

// RemoveLearnedRule marks a rule removed (kept for the eval history).
func (s *Store) RemoveLearnedRule(id, at int64) bool {
	return changes(s.exec(`UPDATE learned_rules SET removed_at = ? WHERE id = ? AND removed_at IS NULL`, at, id)) > 0
}

// ── Completions ─────────────────────────────────────────────────────────────────────────────────────────────────

func (s *Store) InsertCompletion(sampleID string, ts int64, kind, label string, threadID, textHash *string) {
	s.exec(`INSERT INTO completions (sample_id, ts, kind, label, thread_id, text_hash) VALUES (?,?,?,?,?,?)`,
		sampleID, ts, kind, label, nullable(threadID), nullable(textHash))
}

// CompletionSeen: this screen already fired, or the same kind fired since `since` on the same thread or in the same app.
func (s *Store) CompletionSeen(textHash *string, kind string, threadID *string, bundleID string, since int64) bool {
	var one int
	err := s.db.QueryRow(`SELECT 1 FROM completions c LEFT JOIN samples s ON s.id = c.sample_id
        WHERE (c.text_hash IS NOT NULL AND c.text_hash = ?) OR (c.kind = ? AND c.ts >= ? AND (c.thread_id = ? OR s.bundle_id = ?)) LIMIT 1`,
		nullable(textHash), kind, since, nullable(threadID), bundleID).Scan(&one)
	if err == sql.ErrNoRows {
		return false
	}
	must(err)
	return true
}

func (s *Store) Completions(since, until int64) []CompletionRow {
	rows, err := s.db.Query(`SELECT c.ts, c.kind, c.label, c.thread_id, t.title AS thread_title FROM completions c LEFT JOIN threads t ON t.id = c.thread_id
        WHERE c.ts >= ? AND c.ts < ? ORDER BY c.ts`, since, until)
	must(err)
	defer rows.Close()
	var out []CompletionRow
	for rows.Next() {
		var c CompletionRow
		var thread, title sql.NullString
		must(rows.Scan(&c.TS, &c.Kind, &c.Label, &thread, &title))
		c.ThreadID, c.ThreadTitle = str(thread), str(title)
		out = append(out, c)
	}
	must(rows.Err())
	return out
}

// ── Feedback and events ─────────────────────────────────────────────────────────────────────────────────────────

func (s *Store) InsertFeedback(f Feedback) {
	var segments any
	if f.SegmentIDs != nil {
		segments = JSON(f.SegmentIDs)
	}
	s.exec(`INSERT INTO feedback (ts, kind, sample_id, thread_id, received_at, segment_ids) VALUES (?,?,?,?,?,?)`,
		int64(f.TS), f.Kind, nullable(f.SampleID), nullable(f.ThreadID), s.now(), segments)
}

func (s *Store) InsertEvents(events []CompanionEvent) {
	now := s.now()
	s.tx(func(tx *sql.Tx) {
		for _, e := range events {
			var value any
			if e.Value != nil {
				value = *e.Value
			}
			_, err := tx.Exec(`INSERT INTO events (ts, type, thread_id, value, received_at) VALUES (?,?,?,?,?)`, int64(e.TS), e.Type, nullable(e.ThreadID), value, now)
			must(err)
		}
	})
}

// GrowthPoints: growth events only, and only positive values (nothing ever shrinks).
func (s *Store) GrowthPoints(since, until int64) float64 {
	var points float64
	must(s.db.QueryRow(`SELECT COALESCE(SUM(value), 0) AS points FROM events
        WHERE type IN ('focusGrowth', 'returnGrowth') AND value > 0 AND ts >= ? AND ts < ?`, since, until).Scan(&points))
	return points
}

func (s *Store) CountEvents(kind string, since, until int64) int64 {
	var n int64
	must(s.db.QueryRow(`SELECT COUNT(*) AS n FROM events WHERE type = ? AND ts >= ? AND ts < ?`, kind, since, until).Scan(&n))
	return n
}

type ReturnEvent struct {
	ID       int64
	TS       int64
	Value    *float64
	ThreadID *string
}

// Returns: `returned` events (the stones), oldest first. Value is the drift clock in seconds.
func (s *Store) Returns(since, until int64) []ReturnEvent {
	rows, err := s.db.Query(`SELECT id, ts, value, thread_id FROM events WHERE type = 'returned' AND ts >= ? AND ts < ? ORDER BY ts, id`, since, until)
	must(err)
	defer rows.Close()
	var out []ReturnEvent
	for rows.Next() {
		var r ReturnEvent
		var value sql.NullFloat64
		var thread sql.NullString
		must(rows.Scan(&r.ID, &r.TS, &value, &thread))
		if value.Valid {
			v := value.Float64
			r.Value = &v
		}
		r.ThreadID = str(thread)
		out = append(out, r)
	}
	must(rows.Err())
	return out
}

// ── Privacy (retention.go) ──────────────────────────────────────────────────────────────────────────────────────

// ForgetText deletes screen text older than cutoff, except text still on screen (a window seen since with that text).
func (s *Store) ForgetText(cutoff int64) int64 {
	return changes(s.exec(`DELETE FROM sample_text WHERE ts < ?1 AND NOT EXISTS (
          SELECT 1 FROM samples x JOIN samples r ON r.bundle_id = x.bundle_id AND r.title = x.title AND r.text_hash IS x.text_hash
          WHERE x.id = sample_text.sample_id AND r.ts >= ?1)`, cutoff))
}

// ForgetCallInputs: model calls older than cutoff whose input carried screen text keep their outcome, not their input.
func (s *Store) ForgetCallInputs(cutoff int64, purposes []string) int64 {
	marks := strings.TrimSuffix(strings.Repeat("?,", len(purposes)), ",")
	args := []any{cutoff}
	for _, p := range purposes {
		args = append(args, p)
	}
	return changes(s.exec(`DELETE FROM call_inputs WHERE ts < ? AND call_id IN (SELECT id FROM model_calls WHERE purpose IN (`+marks+`))`, args...))
}

// SettleAfterForgetting makes what was forgotten really gone: the freed bytes are zeroed (secure_delete), and the
// write-ahead log, which still holds the earlier pages, is folded in and emptied.
func (s *Store) SettleAfterForgetting() { s.exec(`PRAGMA wal_checkpoint(TRUNCATE)`) }

// DeleteEverything: "Delete my data": everything Moku saw, decided and learned. The schema stays.
func (s *Store) DeleteEverything() {
	s.wipes.Add(1)
	s.noteEdit(0)
	rows, err := s.db.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`)
	must(err)
	var tables []string
	for rows.Next() {
		var name string
		must(rows.Scan(&name))
		tables = append(tables, name)
	}
	rows.Close()
	s.tx(func(tx *sql.Tx) {
		for _, table := range tables {
			_, err := tx.Exec(fmt.Sprintf(`DELETE FROM "%s"`, table))
			must(err)
		}
	})
	s.prunedThrough.Store(0) // the saved days went with the rest (day_summaries is a table like the others)
	s.exec(`VACUUM`)
	// In WAL mode the deleted rows live on in the write-ahead log, and in the main file's old pages until a checkpoint
	// rewrites it: fold the log in and empty it now, not when the brain next quits (Time Machine copies ~/.moku hourly).
	s.SettleAfterForgetting()
	// A database set aside as damaged (OpenStore) holds the same screen history: it goes too.
	if s.path != "" && s.path != ":memory:" {
		for _, suffix := range []string{"", "-wal", "-shm"} {
			os.Remove(s.path + ".damaged" + suffix)
		}
	}
}

// Compact gives the space of deleted rows back to the disk.
func (s *Store) Compact() { s.exec(`VACUUM`) }

type countRow struct {
	Key1, Key2 string
	N          int64
}

type CallRow struct {
	Local     bool
	OK        bool
	ErrorCode *string
	LatencyMs int64
	CostUsd   *float64
}

// DayCounts: verdicts by state and source, feedback and events by kind, and each model call's outcome.
func (s *Store) DayCounts(since, until int64) (verdicts, feedback, events []countRow, calls []CallRow) {
	grouped := func(query string, two bool) []countRow {
		rows, err := s.db.Query(query, since, until)
		must(err)
		defer rows.Close()
		var out []countRow
		for rows.Next() {
			var r countRow
			if two {
				must(rows.Scan(&r.Key1, &r.Key2, &r.N))
			} else {
				must(rows.Scan(&r.Key1, &r.N))
			}
			out = append(out, r)
		}
		return out
	}
	verdicts = grouped(`SELECT state, source, COUNT(*) AS n FROM verdicts WHERE ts >= ? AND ts < ? GROUP BY state, source`, true)
	feedback = grouped(`SELECT kind, COUNT(*) AS n FROM feedback WHERE ts >= ? AND ts < ? GROUP BY kind`, false)
	events = grouped(`SELECT type, COUNT(*) AS n FROM events WHERE ts >= ? AND ts < ? GROUP BY type`, false)
	rows, err := s.db.Query(`SELECT model LIKE 'local/%' AS local, ok, error_code, latency_ms, cost_usd FROM model_calls WHERE ts >= ? AND ts < ?`, since, until)
	must(err)
	defer rows.Close()
	for rows.Next() {
		var c CallRow
		var local, ok int
		var code sql.NullString
		var cost sql.NullFloat64
		must(rows.Scan(&local, &ok, &code, &c.LatencyMs, &cost))
		c.Local, c.OK, c.ErrorCode = local != 0, ok != 0, str(code)
		if cost.Valid {
			v := cost.Float64
			c.CostUsd = &v
		}
		calls = append(calls, c)
	}
	return
}

// ── Model calls (full input and output: the eval set) ─────────────────────────────────────────────────────────

func (s *Store) InsertModelCall(c ModelCallRecord) {
	if c.ErrorCode != nil && *c.ErrorCode == "unavailable" {
		return // skipped by the breaker: no request, nothing to keep
	}
	var cost any
	if c.CostUsd != nil {
		cost = *c.CostUsd
	}
	now, input := s.now(), JSON(c.Input)
	carriesText := slices.Contains(TextPurposes, c.Purpose)
	if carriesText {
		input = forgottenInput // the input itself goes to call_inputs, for an hour
	}
	result := s.exec(`INSERT INTO model_calls (ts, purpose, sample_id, thread_id, model, ok, error_code, latency_ms, attempts, tokens_in, tokens_out, cost_usd, input, output)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		now, c.Purpose, nullable(c.SampleID), nullable(c.ThreadID), c.Model, boolInt(c.OK), nullable(c.ErrorCode), c.LatencyMs, c.Attempts,
		c.TokensIn, c.TokensOut, cost, input, JSON(c.Output))
	if carriesText {
		id, err := result.LastInsertId()
		must(err)
		s.exec(`INSERT INTO call_inputs (call_id, ts, input) VALUES (?,?,?)`, id, now, JSON(c.Input))
	}
}

const forgottenInput = `{"forgotten":true}`

type StoredCall struct {
	Purpose   string
	OK        bool
	ErrorCode *string
	LatencyMs int64
	CostUsd   *float64
	Input     json.RawMessage
	Output    json.RawMessage
}

// ModelCalls, oldest first ("" purpose: all).
func (s *Store) ModelCalls(purpose string) []StoredCall {
	const columns = `SELECT m.purpose, m.ok, m.error_code, m.latency_ms, m.cost_usd, COALESCE(i.input, m.input), m.output FROM model_calls m LEFT JOIN call_inputs i ON i.call_id = m.id`
	query, args := columns+` ORDER BY m.id`, []any{}
	if purpose != "" {
		query, args = columns+` WHERE m.purpose = ? ORDER BY m.id`, []any{purpose}
	}
	rows, err := s.db.Query(query, args...)
	must(err)
	defer rows.Close()
	var out []StoredCall
	for rows.Next() {
		var c StoredCall
		var ok int
		var code, output sql.NullString
		var cost sql.NullFloat64
		var input string
		must(rows.Scan(&c.Purpose, &ok, &code, &c.LatencyMs, &cost, &input, &output))
		c.OK, c.ErrorCode, c.Input = ok == 1, str(code), json.RawMessage(input)
		if output.Valid {
			c.Output = json.RawMessage(output.String)
		}
		if cost.Valid {
			v := cost.Float64
			c.CostUsd = &v
		}
		out = append(out, c)
	}
	return out
}

// ── Calibration (calibrate.go) ──────────────────────────────────────────────────────────────────────────────────

// CalibrationRow: one verdict with its screen, as a moment is built from.
type CalibrationRow struct {
	SampleID   string
	TS         int64
	State      string
	ThreadID   *string
	IsNew      bool
	Confidence float64
	Source     string
	Reason     string
	BundleID   string
	AppName    string
	Title      string
	URL        *string
}

// CalibrationRows: the verdicts in [since, until), in time order.
func (s *Store) CalibrationRows(since, until int64) []CalibrationRow {
	rows, err := s.db.Query(`SELECT v.sample_id, v.ts, v.state, v.thread_id, v.is_new_thread, v.confidence, v.source, v.reason,
          s.bundle_id, s.app_name, s.title, s.url
        FROM verdicts v JOIN samples s ON s.id = v.sample_id WHERE v.ts >= ? AND v.ts < ? ORDER BY v.ts, v.rowid`, since, until)
	must(err)
	defer rows.Close()
	var out []CalibrationRow
	for rows.Next() {
		var r CalibrationRow
		var thread, url sql.NullString
		var isNew int
		must(rows.Scan(&r.SampleID, &r.TS, &r.State, &thread, &isNew, &r.Confidence, &r.Source, &r.Reason, &r.BundleID, &r.AppName, &r.Title, &url))
		r.ThreadID, r.URL, r.IsNew = str(thread), str(url), isNew == 1
		out = append(out, r)
	}
	must(rows.Err())
	return out
}

// EventTimes: when events of one type happened in [since, until).
func (s *Store) EventTimes(kind string, since, until int64) []int64 {
	rows, err := s.db.Query(`SELECT ts FROM events WHERE type = ? AND ts >= ? AND ts < ? ORDER BY ts`, kind, since, until)
	must(err)
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var ts int64
		must(rows.Scan(&ts))
		out = append(out, ts)
	}
	return out
}

type GoalRating struct {
	MomentID    string
	Start, End  int64
	Said        json.RawMessage
	OK          bool
	Truth       *string // when not OK: goal, new, drift or personal
	TruthGoalID *string
	TruthTitle  *string
	RatedAt     int64
}

func (s *Store) SetGoalRating(r GoalRating) {
	s.exec(`INSERT OR REPLACE INTO goal_ratings VALUES (?,?,?,?,?,?,?,?,?)`, r.MomentID, r.Start, r.End, string(r.Said), boolInt(r.OK),
		nullable(r.Truth), nullable(r.TruthGoalID), nullable(r.TruthTitle), r.RatedAt)
}

func (s *Store) DeleteGoalRating(momentID string) bool {
	return changes(s.exec(`DELETE FROM goal_ratings WHERE moment_id = ?`, momentID)) > 0
}

// GoalRatings: the ratings of moments that started in [since, until), oldest first.
func (s *Store) GoalRatings(since, until int64) []GoalRating {
	rows, err := s.db.Query(`SELECT moment_id, start, end, said, ok, truth, truth_goal_id, truth_title, rated_at FROM goal_ratings
        WHERE start >= ? AND start < ? ORDER BY start`, since, until)
	must(err)
	defer rows.Close()
	var out []GoalRating
	for rows.Next() {
		var r GoalRating
		var said string
		var ok int
		var truth, goalID, title sql.NullString
		must(rows.Scan(&r.MomentID, &r.Start, &r.End, &said, &ok, &truth, &goalID, &title, &r.RatedAt))
		r.Said, r.OK, r.Truth, r.TruthGoalID, r.TruthTitle = json.RawMessage(said), ok == 1, str(truth), str(goalID), str(title)
		out = append(out, r)
	}
	must(rows.Err())
	return out
}

// RecordGoalEdit: a rename, a merge or "not a real goal" from the dashboard, kept for the tuning loop.
func (s *Store) RecordGoalEdit(at int64, kind, goalID string, intoID, title *string) {
	s.exec(`INSERT INTO goal_edits (at, kind, goal_id, into_id, title) VALUES (?,?,?,?,?)`, at, kind, goalID, nullable(intoID), nullable(title))
}

// CallStats: the Jev calls in [since, until): their total cost and their latencies (purposes as given).
func (s *Store) CallStats(since, until int64, purposes []string) (cost float64, latencies []int64) {
	marks := strings.TrimSuffix(strings.Repeat("?,", len(purposes)), ",")
	args := []any{since, until}
	for _, p := range purposes {
		args = append(args, p)
	}
	rows, err := s.db.Query(`SELECT COALESCE(cost_usd, 0), latency_ms, ok FROM model_calls WHERE ts >= ? AND ts < ? AND purpose IN (`+marks+`)`, args...)
	must(err)
	defer rows.Close()
	for rows.Next() {
		var c float64
		var latency int64
		var ok int
		must(rows.Scan(&c, &latency, &ok))
		cost += c
		if ok == 1 {
			latencies = append(latencies, latency)
		}
	}
	return
}

// FirstCall: when the first model call with this purpose was made (0 when none).
func (s *Store) FirstCall(purpose string) int64 {
	var ts sql.NullInt64
	must(s.db.QueryRow(`SELECT MIN(ts) FROM model_calls WHERE purpose = ?`, purpose).Scan(&ts))
	return ts.Int64
}

// ActiveMs: time with working or drifting verdicts in [since, until), counted in 5-minute buckets.
func (s *Store) ActiveMs(since, until int64) int64 {
	var buckets int64
	must(s.db.QueryRow(`SELECT COUNT(DISTINCT ts / 300000) FROM verdicts WHERE ts >= ? AND ts < ? AND state IN ('working', 'drifting')`, since, until).Scan(&buckets))
	return buckets * 300_000
}

// CopyDatabase: a consistent copy of the database at from, written to to (owner-only), even while a brain writes to it:
// VACUUM INTO from a read-only connection; a plain copy of the files when that can't open it.
func CopyDatabase(from, to string) error {
	db, err := sql.Open("sqlite", "file:"+from+"?mode=ro")
	if err == nil {
		defer db.Close()
		if _, err = db.Exec(`VACUUM INTO ?`, to); err == nil {
			return os.Chmod(to, 0o600)
		}
	}
	os.Remove(to) // a half-written copy of our own, if any
	for _, suffix := range []string{"", "-wal", "-shm"} {
		data, readErr := os.ReadFile(from + suffix)
		if readErr != nil {
			if suffix == "" {
				return readErr
			}
			continue
		}
		if writeErr := os.WriteFile(to+suffix, data, 0o600); writeErr != nil {
			return writeErr
		}
	}
	return nil
}