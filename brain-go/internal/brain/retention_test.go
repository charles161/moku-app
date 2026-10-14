package brain

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Screen text is kept an hour. These check that it's really gone (not just hidden from queries), that what's still on
// screen stays, and that the store doesn't keep growing by it.

const hour = int64(60 * 60_000)

func insertWithText(store *Store, id string, ts int64, title, text string) {
	hash := fmt.Sprintf("h-%s", id)
	store.InsertSample(ActivitySample{ID: id, TS: float64(ts), App: AppInfo{BundleID: "b.app", Name: "App"}, Window: &WindowInfo{Title: title},
		Text: &text, TextSource: ptr("ocr"), TextHash: &hash})
}

func TestScreenTextOlderThanAnHourIsForgottenButWhatIsStillOnScreenStays(t *testing.T) {
	store := newPastStore(t)
	now := 1_790_000_000_000
	n := int64(now)
	insertWithText(store, "old", n-3*hour, "Old doc", "old words")
	insertWithText(store, "recent", n-30*60_000, "Recent doc", "recent words")
	// A window whose text was read three hours ago and again just now: it's still there.
	store.InsertSample(ActivitySample{ID: "still-1", TS: float64(n - 3*hour), App: AppInfo{BundleID: "b.app", Name: "App"}, Window: &WindowInfo{Title: "Long doc"},
		Text: ptr("long words"), TextSource: ptr("ocr"), TextHash: ptr("same")})
	store.InsertSample(ActivitySample{ID: "still-2", TS: float64(n - 60_000), App: AppInfo{BundleID: "b.app", Name: "App"}, Window: &WindowInfo{Title: "Long doc"},
		Text: ptr("long words"), TextSource: ptr("ocr"), TextHash: ptr("same")})
	for _, c := range []struct {
		purpose string
		age     int64
	}{{"judge", 3 * hour}, {"judge", 10 * 60_000}, {"voice", 3 * hour}} {
		store.InsertModelCall(ModelCallRecord{Purpose: c.purpose, Model: "m", OK: true, Input: OMap{{"screen", "words on the screen"}}, Output: OMap{{"ok", true}}})
		store.exec(`UPDATE model_calls SET ts = ? WHERE id = (SELECT MAX(id) FROM model_calls)`, n-c.age)
		store.exec(`UPDATE call_inputs SET ts = ? WHERE call_id = (SELECT MAX(id) FROM model_calls)`, n-c.age)
	}

	samples, calls := ForgetScreenText(store, n, TextKeepMs)
	if samples != 1 || calls != 1 {
		t.Errorf("forgot %d samples and %d model calls, want 1 and 1 (the old doc's text; the long doc's first reading is still on screen)", samples, calls)
	}
	if textOf := store.Sample("still-1").Text; textOf == nil {
		t.Error("text of a window that is still on screen was forgotten")
	}
	textOf := func(id string) *string { return store.Sample(id).Text }
	if textOf("old") != nil {
		t.Error("three-hour-old text is still there")
	}
	if textOf("recent") == nil || textOf("still-2") == nil {
		t.Error("text from the last hour was forgotten")
	}
	left := map[string]bool{}
	for _, c := range store.ModelCalls("") {
		left[c.Purpose+"|"+string(c.Input)] = true
	}
	if left[`judge|{"forgotten":true}`] != true || len(left) != 3 {
		t.Errorf("model call inputs after retention: %v", left)
	}
	for _, c := range store.ModelCalls("voice") {
		if strings.Contains(string(c.Input), "forgotten") {
			t.Error("a voice call carries no screen text; its input shouldn't be touched")
		}
	}
	if b := (&Brain{calibrate: true}); b.TextKeepMs() != CalibrationTextKeepMs || (&Brain{}).TextKeepMs() != TextKeepMs {
		t.Error("only the calibration build keeps text for 14 days")
	}
}

// Forgotten is not hidden: the words must not be left in the database file for anyone who reads the file.
func TestForgottenScreenTextIsNotLeftInTheDatabaseFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moku.sqlite")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	n := int64(1_790_000_000_000)
	secret := "SECRET-SCREEN-WORDS-" + strings.Repeat("quarterly salary figures ", 20)
	insertWithText(store, "old", n-3*hour, "Old doc", secret)
	store.InsertModelCall(ModelCallRecord{Purpose: "judge", Model: "m", OK: true, Input: OMap{{"screen", secret}}, Output: OMap{{"ok", true}}})
	store.exec(`UPDATE model_calls SET ts = ?`, n-3*hour)
	store.exec(`UPDATE call_inputs SET ts = ?`, n-3*hour)
	ForgetScreenText(store, n, TextKeepMs)
	store.Close() // folds the write-ahead log into the file

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte("SECRET-SCREEN-WORDS")) {
		t.Error("the text Moku says it forgot after an hour is still in moku.sqlite")
	}
	if wal, err := os.ReadFile(path + "-wal"); err == nil && bytes.Contains(wal, []byte("SECRET-SCREEN-WORDS")) {
		t.Error("the text is still in the write-ahead log")
	}
}

// A month of work with text read all the time: after retention only the last hour holds text, and the file stops
// growing by it (the freed pages are reused).
func TestAMonthOfScreenTextLeavesOnlyTheLastHour(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moku.sqlite")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	n := int64(1_790_000_000_000)
	text := strings.Repeat("a line of text read from the screen. ", 60)
	rows := 0
	sizeAt := map[int]int64{}
	for day := 30; day >= 1; day-- {
		for i := 0; i < 400; i++ { // 400 text readings a day is plenty for the test; the app sends about 3,600
			ts := n - int64(day)*24*hour + int64(i)*60_000
			insertWithText(store, fmt.Sprintf("t-%d-%d", day, i), ts, fmt.Sprintf("doc %d", i%40), text+fmt.Sprint(rows))
			rows++
		}
		ForgetScreenText(store, n-int64(day-1)*24*hour, TextKeepMs) // retention at the end of each day
		store.exec(`PRAGMA wal_checkpoint(TRUNCATE)`)
		if info, err := os.Stat(path); err == nil && day%10 == 0 {
			sizeAt[day] = info.Size()
		}
	}
	var withText int
	store.db.QueryRow(`SELECT COUNT(*) FROM sample_text`).Scan(&withText)
	if withText > 80 {
		t.Errorf("%d samples still hold text after a month with retention running", withText)
	}
	if sizeAt[10] > sizeAt[30]*2 || sizeAt[10] > 6<<20 {
		t.Errorf("the file grows with the text it forgot: %v", sizeAt)
	}
}

// Retention runs every 10 minutes under the brain's lock. It finds the text to forget through an index, not by reading
// every old sample (5 s on 90 days of history).
func TestForgettingScreenTextDoesNotReadTheHistory(t *testing.T) {
	store := newPastStore(t)
	rows, err := store.db.Query(`EXPLAIN QUERY PLAN DELETE FROM sample_text WHERE ts < ?1 AND NOT EXISTS (
          SELECT 1 FROM samples x JOIN samples r ON r.bundle_id = x.bundle_id AND r.title = x.title AND r.text_hash IS x.text_hash
          WHERE x.id = sample_text.sample_id AND r.ts >= ?1)`, 1)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var plan []string
	for rows.Next() {
		var id, parent, unused int
		var detail string
		rows.Scan(&id, &parent, &unused, &detail)
		plan = append(plan, detail)
	}
	if !strings.Contains(plan[0], "sample_text_ts") && !strings.Contains(plan[0], "SEARCH sample_text") {
		t.Errorf("retention scans %q; plan: %v", plan[0], plan)
	}
}

// The store of a Moku that has run for weeks: text it forgot is still there as empty space in the middle of the tables.
// Opening it moves what text remains to its own tables and rewrites the file, which gives the space back.
func TestOpeningTheStoreOfAnEarlierVersionGivesBackTheSpaceForgottenTextLeft(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moku.sqlite")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	// Make it what 0.1.7 leaves: text inline in samples and in model_calls.input, mostly forgotten.
	store.exec(`DELETE FROM meta WHERE key = 'text_split'`)
	n := int64(1_790_000_000_000)
	text := strings.Repeat("a line of text read from the screen. ", 80)
	for i := 0; i < 3000; i++ {
		ts := n - int64(3000-i)*60_000
		id := fmt.Sprintf("s%d", i)
		store.exec(`INSERT INTO samples VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, id, ts, "b.app", "App", fmt.Sprintf("doc %d", i%50), nil, text+id, "ocr", "h"+id, 1, 1, 1, 0.0, 0, 0, 0, 0, ts)
		store.exec(`INSERT INTO model_calls (ts, purpose, model, ok, latency_ms, attempts, tokens_in, tokens_out, input) VALUES (?,?,?,?,?,?,?,?,?)`,
			ts, "judge", "m", 1, 1, 1, 1, 1, `{"screen":"`+text+id+`"}`)
	}
	// Retention as 0.1.7 did it: set to NULL (and the calls' inputs replaced), leaving the pages empty.
	store.exec(`UPDATE samples SET text = NULL WHERE ts < ?`, n-60*60_000)
	store.exec(`UPDATE model_calls SET input = '{"forgotten":true}' WHERE ts < ?`, n-60*60_000)
	store.Close()
	before, _ := os.Stat(path)

	store, err = OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	store.Close() // fold the log into the file so its size can be read
	after, _ := os.Stat(path)
	store, _ = OpenStore(path)
	defer store.Close()
	if after.Size() > before.Size()/2 {
		t.Errorf("the file is %d MB, was %d MB: the space wasn't given back", after.Size()>>20, before.Size()>>20)
	}
	var inline, moved, inputs int
	store.db.QueryRow(`SELECT COUNT(*) FROM samples WHERE text IS NOT NULL`).Scan(&inline)
	store.db.QueryRow(`SELECT COUNT(*) FROM sample_text`).Scan(&moved)
	store.db.QueryRow(`SELECT COUNT(*) FROM call_inputs`).Scan(&inputs)
	if inline != 0 || moved != 60 || inputs != 60 {
		t.Errorf("text left inline in %d samples; %d texts and %d call inputs moved, want 0, 60 and 60 (the last hour)", inline, moved, inputs)
	}
	if got := store.Sample("s2999").Text; got == nil || !strings.HasSuffix(*got, "s2999") {
		t.Error("the last sample's text didn't survive the move")
	}
	var recent string
	for _, c := range store.ModelCalls("judge")[2999:] {
		recent = string(c.Input)
	}
	if !strings.Contains(recent, "s2999") {
		t.Errorf("the last call's input didn't survive the move: %s", recent)
	}
	if store.Meta("text_split") == nil {
		t.Error("the move isn't marked done, so it would run again")
	}
}
