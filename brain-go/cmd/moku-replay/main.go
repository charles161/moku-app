// moku-replay: Charles's rated moments (the calibration dashboard's ratings) judged again by the current rules and
// prompts, and scored against his ratings, before a new version reaches his Mac (docs/specs/goal-aware-judging.md,
// "Tuning loop").
//
//	go run ./cmd/moku-replay [--db ~/.moku/moku.sqlite] [--model typesafe-ai/jev] [--limit 200] [--json]
//
// It copies the database into a temporary folder (VACUUM INTO, so a running brain can't tear the copy), works on the
// copy only, and removes the copy when it ends, however it ends: the copy holds screen text. Jev is reached the way
// the brain reaches it (MOKU_HOME/credentials.env, the environment or bunny/.env); keys are never printed. --model
// scores another judge model on the same moments (anything the AI Gateway serves).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"moku/brain/internal/brain"
)

// copyDir: the temporary folder holding the copy, removed on every way out.
var copyDir string

func main() {
	home, _ := os.UserHomeDir()
	db := flag.String("db", filepath.Join(home, ".moku", "moku.sqlite"), "the database to copy and replay")
	model := flag.String("model", "", "the judge model (default: Jev)")
	limit := flag.Int("limit", 0, "replay only the latest N rated moments")
	asJSON := flag.Bool("json", false, "print the report as JSON")
	flag.Parse()
	if *model != "" {
		os.Setenv("MOKU_MODEL_JUDGE", *model)
	}
	brain.LoadEnv(brain.DevEnvPath())
	if brain.ModelAccess() == "none" {
		fail("no model credentials (MOKU_HOME/credentials.env, the environment or bunny/.env)")
	}
	dir, err := os.MkdirTemp("", "moku-replay-")
	if err != nil {
		fail(err.Error())
	}
	copyDir = dir
	interrupted := make(chan os.Signal, 1)
	signal.Notify(interrupted, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-interrupted
		fail("interrupted")
	}()
	copyPath := filepath.Join(dir, "moku.sqlite")
	if err := brain.CopyDatabase(*db, copyPath); err != nil {
		fail("cannot copy " + *db + ": " + err.Error())
	}
	store, err := brain.OpenStore(copyPath)
	if err != nil {
		fail(err.Error())
	}
	report := brain.ReplayRatings(store, brain.NewModels(brain.ModelOptions{Transport: brain.NewGateway()}), *limit)
	store.Close()
	if report.Moments == 0 {
		fail("no rated moments yet: rate some on the calibration dashboard first")
	}
	if *asJSON {
		out, _ := json.MarshalIndent(report, "", "  ")
		fmt.Println(string(out))
	} else {
		fmt.Print(brain.ReplayTable(report))
	}
	removeCopy()
}

// removeCopy: the copy is this tool's own temporary file, never the database it came from.
func removeCopy() {
	if copyDir != "" {
		os.RemoveAll(copyDir)
	}
}

func fail(msg string) {
	removeCopy()
	fmt.Fprintln(os.Stderr, "moku-replay: "+msg)
	os.Exit(1)
}
