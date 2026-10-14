package brain

import (
	"database/sql"
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"testing"
	"time"
)

// A tool, not a test: writes months of a heavy user's history to a database, to see how the store grows and how the
// brain answers over it (launch QA, lens 5):
//
//	MOKU_SEED_DB=/path/moku.sqlite MOKU_SEED_DAYS=90 go test ./internal/brain -run TestSeedHistory -v -timeout 3h
//
// A day is ten hours at the app's pace (a sample every 3 s, 12,000 a day) with its verdicts, the Jev calls the pipeline
// made (about one sample in six, input kept once the hour of screen text is over, as retention leaves it), a handful of
// goals and the growth events. Without MOKU_SEED_DB it does nothing.
func TestSeedHistory(t *testing.T) {
	path := os.Getenv("MOKU_SEED_DB")
	if path == "" {
		t.Skip("MOKU_SEED_DB isn't set")
	}
	days, _ := strconv.Atoi(os.Getenv("MOKU_SEED_DAYS"))
	if days == 0 {
		days = 30
	}
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	started := time.Now()
	seedHistory(store, time.Now().In(Zone()), days, 12000, 3*time.Second, func(d int) {
		if d%10 == 0 {
			t.Logf("%d days to go, %.0fs", d, time.Since(started).Seconds())
		}
	})
	size := func(p string) int64 { info, _ := os.Stat(p); return map[bool]int64{true: info.Size(), false: 0}[info != nil] }
	t.Logf("%d days in %.0fs: %d MB (+%d MB log)", days, time.Since(started).Seconds(), size(path)>>20, size(path+"-wal")>>20)
}

// seedHistory writes `days` days of history ending the day before `end`: each of perDay samples `step` apart from 08:30,
// five goals, the Jev calls and the growth events. progress, when given, hears of each day left.
func seedHistory(store *Store, end time.Time, days, perDay int, step time.Duration, progress func(daysLeft int)) {
	rng := rand.New(rand.NewSource(42))
	goals := []string{"Writing · Draft", "Coding · Moku", "Reading · Papers", "Planning · Week", "Email · Replies"}
	for i, g := range goals {
		if store.Thread(fmt.Sprintf("goal-%d", i)) == nil {
			store.CreateThread(fmt.Sprintf("goal-%d", i), g, "A goal.", 0, nil)
		}
	}
	loc := Zone()
	for d := days; d >= 1; d-- {
		day := time.Date(end.Year(), end.Month(), end.Day()-d, 8, 30, 0, 0, loc)
		must(seedDay(store, rng, day, d, goals, perDay, step))
		if progress != nil {
			progress(d)
		}
	}
}

// seedDay: one day. A person stays on a page for a while, so the state (working, drifting, away, in a meeting) and the goal
// are chosen when the page changes, as a real day's ribbon is, a few hundred segments and not one for each sample.
func seedDay(store *Store, rng *rand.Rand, start time.Time, daysAgo int, goals []string, perDay int, step time.Duration) error {
	var err error
	store.tx(func(tx *sql.Tx) {
		exec := func(q string, args ...any) {
			if _, e := tx.Exec(q, args...); e != nil && err == nil {
				err = e
			}
		}
		pages := 200
		stay, page := 0, 0
		goal := rng.Intn(len(goals))
		state := "working"
		var driftedAt int64
		for i := 0; i < perDay; i++ {
			ts := start.Add(time.Duration(i) * step).UnixMilli()
			if stay <= 0 {
				was := state
				page, stay, goal = rng.Intn(pages), 5+rng.Intn(120), rng.Intn(len(goals))
				state = "working"
				switch r := rng.Intn(100); {
				case r < 15:
					state = "drifting"
				case r < 20:
					state = "away"
				case r < 25:
					state = "meeting"
				}
				if state == "drifting" && was != "drifting" {
					driftedAt = ts
				}
				if was == "drifting" && state == "working" { // a comeback, with the drift's clock
					exec(`INSERT INTO events (ts, type, thread_id, value, received_at) VALUES (?,?,?,?,?)`, ts, "returned",
						fmt.Sprintf("goal-%d", goal), float64(ts-driftedAt)/1000, ts)
				}
			}
			stay--
			id := fmt.Sprintf("seed-%d-%d", daysAgo, i)
			exec(`INSERT INTO samples VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, id, ts, "com.apple.Safari", "Safari",
				fmt.Sprintf("Design doc %d - Google Docs", page), fmt.Sprintf("https://docs.google.com/document/d/%d", page), nil, nil, fmt.Sprintf("h%d", page),
				rng.Intn(180), rng.Intn(30), rng.Intn(60), 0.0, 0, 0, 0, 0, ts)
			var thread any
			if state == "working" {
				thread = fmt.Sprintf("goal-%d", goal)
			}
			exec(`INSERT INTO verdicts (sample_id, ts, state, thread_id, is_new_thread, confidence, source, reason, latency_ms, created_at, activity, category)
                VALUES (?,?,?,?,0,0.9,'jev','[jev] work on the screen',420,?,?,?)`, id, ts, state, thread, ts, "writing the draft", "building")
			if rng.Intn(6) == 0 {
				exec(`INSERT INTO model_calls (ts, purpose, sample_id, model, ok, latency_ms, attempts, tokens_in, tokens_out, cost_usd, input, output)
                    VALUES (?,?,?,?,1,420,1,900,4,0.00004,'{"forgotten":true}',?)`, ts, "judge", id, "typesafe-ai/jev",
					`{"answers":{"kind":{"type":"choice","choice":"work","probabilities":{"work":0.97,"distraction":0.03}}}}`)
			}
			if i%20 == 0 && state == "working" {
				exec(`INSERT INTO events (ts, type, thread_id, value, received_at) VALUES (?,?,?,?,?)`, ts, "focusGrowth", thread, 1.0, ts)
			}
		}
	})
	return err
}
