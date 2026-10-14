// The brain's process: `moku-brain [--port N]`, from any directory.
//   - Everything lives in MOKU_HOME (default ~/.moku, owner-only): the database, config.json, credentials.env and
//     brain-token, the secret every request but /health must carry (MOKU_BRAIN_TOKEN wins; LoadBrainToken).
//   - Listens on 127.0.0.1 only: --port N, else MOKU_BRAIN_PORT, else 8020; 0 picks a free port. Once listening it
//     prints "moku brain on http://127.0.0.1:PORT".
//   - MOKU_PARENT_PID (set by Moku.app): the brain stops, as for SIGTERM, once that app is gone.
//   - SIGTERM or SIGINT: stops taking requests, gives in-flight work a moment, folds the database's write-ahead log
//     into the file, and exits 0.
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime/debug"
	"syscall"
	"time"

	"moku/brain/internal/brain"
)

const shutdownGrace = 2500 * time.Millisecond

func main() {
	log.SetFlags(0)
	// A small, steady footprint: collect sooner. The soft limit is 96 MiB, not lower: /v1/world reads the whole
	// timeline (tens of MB for a moment), and a 24 MiB limit made the collector thrash on every core, about 2 s of CPU
	// per call against 0.3 s (2026-10-02). The handlers give that memory back right after (giveBackMemory). GOGC and
	// GOMEMLIMIT still override.
	if os.Getenv("GOGC") == "" {
		debug.SetGCPercent(50)
	}
	if os.Getenv("GOMEMLIMIT") == "" {
		debug.SetMemoryLimit(96 << 20)
	}
	brain.LoadEnv(brain.DevEnvPath())
	// Everything this process creates (the database and its -wal/-shm files) is owner-only: it holds screen text.
	syscall.Umask(0o077)
	port, err := brain.BrainPort(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "moku brain: %s\n", err)
		os.Exit(2)
	}
	home := brain.MokuHome()
	os.MkdirAll(home, 0o700)
	// One behaviour for everyone: the drift pace someone saved (Gentle, Quick, their own minutes) is cleared, once.
	if cleared := brain.ClearRetiredConfig(brain.ConfigPath()); len(cleared) > 0 {
		fmt.Printf("config: cleared the retired drift timings %v; everything else is kept\n", cleared)
	}
	token, err := brain.LoadBrainToken(home)
	if err != nil {
		// Closed, not open: a brain nobody can call beats one anybody on this Mac can.
		fmt.Fprintf(os.Stderr, "moku brain: no brain token (%s); only /health answers\n", err)
		if token, err = brain.NewBrainToken(); err != nil {
			os.Exit(1)
		}
	}
	dbPath := brain.DatabasePath()
	store, err := brain.OpenStore(dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "moku brain: cannot open %s: %s\n", dbPath, err)
		os.Exit(1)
	}
	// The local model: downloaded on first run, run only while Jev or Luna is failing. MOKU_LOCAL_MODEL=off turns it off.
	var local brain.LocalModel
	if os.Getenv("MOKU_LOCAL_MODEL") != "off" {
		local = brain.NewLocalModel(brain.LocalOptions{Home: home, ServerPath: os.Getenv("MOKU_LLAMA_SERVER")})
		local.Prepare()
	}
	models := brain.NewModels(brain.ModelOptions{Transport: brain.NewGateway(), Local: local})

	// Goal-aware judging and Charles's calibration (goaljudge.go, calibrate.go): off unless switched on.
	goalJudging, calibrate := brain.GoalModes(os.Getenv)
	// Screen text is kept an hour at most (14 days while calibrating): now, and every 10 minutes.
	b := brain.NewBrain(brain.BrainOptions{Store: store, Models: models, GoalJudging: goalJudging, Calibrate: calibrate})
	forget := func() {
		if os.Getenv("MOKU_KEEP_SCREEN_TEXT") == "1" {
			return
		}
		defer func() {
			if p := recover(); p != nil {
				brain.LogError(brain.ErrTask, "moku brain: forgetting screen text failed: %v", p)
			}
		}()
		b.Lock()
		defer b.Unlock()
		samples, calls := brain.ForgetScreenText(store, time.Now().UnixMilli(), b.TextKeepMs())
		if samples+calls > 0 {
			fmt.Printf("screen text forgotten: %d samples, %d model calls\n", samples, calls)
		}
	}
	forget()
	// The detail of a day is kept 90 days and the day's summary for good (retention.go): the same pass migrates a store that
	// holds more, in small steps with the brain's lock let go between them, and tidies up one day a day after that.
	retain := func() {
		defer func() {
			if p := recover(); p != nil {
				brain.LogError(brain.ErrTask, "moku brain: history retention failed: %v", p)
			}
		}()
		r := b.Retain(brain.RetainOptions{})
		if r.DaysSaved+r.DaysPruned > 0 || r.Vacuumed {
			fmt.Printf("history retention: %d days saved, %d days of detail deleted (%d samples, %d verdicts, %d model calls), longest hold of the lock %v%s\n",
				r.DaysSaved, r.DaysPruned, r.Samples, r.Verdicts, r.ModelCalls, r.MaxLockHold.Round(time.Millisecond),
				map[bool]string{true: fmt.Sprintf(", file rewritten in %v", r.VacuumTook.Round(time.Millisecond)), false: ""}[r.Vacuumed])
		}
	}
	go func() {
		retain()
		for range time.Tick(10 * time.Minute) {
			forget()
			retain()
		}
	}()

	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		fmt.Fprintf(os.Stderr, "moku brain: cannot listen on 127.0.0.1:%d (%s)\n", port, err)
		store.Close()
		os.Exit(1)
	}
	actual := listener.Addr().(*net.TCPAddr).Port
	server := &http.Server{Handler: brain.NewHandler(b, brain.AppOptions{Port: actual, LogVerdicts: true, Token: token}), ReadHeaderTimeout: 10 * time.Second}
	go server.Serve(listener)
	fmt.Printf("moku brain on http://127.0.0.1:%d\n", actual)
	fmt.Printf("  home %s, db %s, config %s\n", home, dbPath, brain.ConfigPath())
	if calibrate {
		fmt.Printf("  calibrating: goal-aware judging, screen text kept 14 days, http://127.0.0.1:%d/calibrate\n", actual)
	} else if goalJudging {
		fmt.Println("  goal-aware judging")
	}
	switch brain.ModelAccess() {
	case "none":
		fmt.Println("  no model credentials (MOKU_HOME/credentials.env, the environment or bunny/.env): verdicts will be `unknown`, lines will be templates")
	case "proxy":
		fmt.Println("  models via the Moku proxy")
	default:
		fmt.Println("  models via the AI Gateway key")
	}

	// Once per database: threads named before titles were in the person's own words get renamed. Every start: threads
	// named the same are merged, and a thread still without a bucket takes its verdicts' (or, if none, one from Jev).
	go func() {
		defer func() {
			if p := recover(); p != nil {
				brain.LogError(brain.ErrTask, "moku: thread upkeep failed: %v", p)
			}
		}()
		b.Lock()
		defer b.Unlock()
		for _, r := range b.RenameThreadsOnce() {
			fmt.Printf("renamed thread %s: %q → %q\n", r.ID, r.From, r.To)
		}
		for _, m := range b.MergeSameTitles() {
			fmt.Printf("merged thread %s into %s: both %q\n", m.From, m.Into, m.Title)
		}
		for _, f := range b.FillThreadCategories() {
			fmt.Printf("thread %s bucket: %s (from %s)\n", f.ID, f.Category, f.From)
		}
		// The world's totals of the past: loaded, or built a day at a time (the lock is let go between days), so the first
		// time the app asks for the world the answer is ready.
		b.World()
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	// Moku.app's brain stops with its app, however the app ends (parent.go).
	brain.WatchParent(brain.ParentPID(os.Getenv("MOKU_PARENT_PID")), 2*time.Second, func() { signals <- syscall.SIGTERM })
	sig := <-signals
	fmt.Printf("moku brain: %s, shutting down\n", map[os.Signal]string{syscall.SIGINT: "SIGINT", syscall.SIGTERM: "SIGTERM"}[sig])
	// In-flight requests and background work get a moment; the app waits for this process, so it never takes long.
	ctx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	settled := make(chan struct{})
	go func() {
		server.Shutdown(ctx)
		b.Settle()
		close(settled)
	}()
	select {
	case <-settled:
	case <-ctx.Done():
	}
	if local != nil {
		local.Close()
	}
	// Close the database once no request holds it (or after half a second: exiting is what matters now).
	for deadline := time.Now().Add(500 * time.Millisecond); !b.TryLock() && time.Now().Before(deadline); {
		time.Sleep(10 * time.Millisecond)
	}
	store.Close()
	os.Exit(0)
}
