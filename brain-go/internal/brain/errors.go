package brain

import (
	"log"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
)

// The brain's own errors, counted for Moku (docs/privacy.md). What the brain logs as an error is also counted here, by
// kind (one of the words below) and the place in its code it came from, and /health lists the counts since it started.
// The app reads them with its health check every 30 s and sends what's new as `app_error` (MokuMind ErrorLog.swift), so
// the brain has no network path of its own. A count never holds the message: only the kind, the Go file and function,
// and how many times.

const (
	// ErrRequest: a request failed inside the brain (it answered 500).
	ErrRequest = "request"
	// ErrTask: a background task failed (naming a thread, forgetting screen text, retention).
	ErrTask = "task"
	// ErrDisk: the database file couldn't be rewritten to give space back.
	ErrDisk = "disk"
	// ErrStore: the database was damaged and set aside.
	ErrStore = "store"
)

// ErrorCount is one line of /health's "errors".
type ErrorCount struct {
	Kind  string `json:"kind"`
	Where string `json:"where"`
	Count int    `json:"count"`
}

// maxErrorPlaces keeps /health small: past this many kinds and places, new ones count as "other".
const maxErrorPlaces = 32

var errorCounts = struct {
	sync.Mutex
	byPlace map[[2]string]int
}{byPlace: map[[2]string]int{}}

// LogError logs the line as log.Printf does, and counts it by kind and by where it came from: during a panic being
// recovered, the function in our code that panicked; otherwise the caller of LogError.
func LogError(kind string, format string, args ...any) {
	log.Printf(format, args...)
	countError(kind, errorPlace(3))
}

func countError(kind, where string) {
	errorCounts.Lock()
	defer errorCounts.Unlock()
	key := [2]string{kind, where}
	if _, seen := errorCounts.byPlace[key]; !seen && len(errorCounts.byPlace) >= maxErrorPlaces {
		key = [2]string{kind, "other.go:other"}
	}
	errorCounts.byPlace[key]++
}

// ErrorCounts lists the counts since the brain started, by kind, then place.
func ErrorCounts() []ErrorCount {
	errorCounts.Lock()
	defer errorCounts.Unlock()
	counts := make([]ErrorCount, 0, len(errorCounts.byPlace))
	for key, n := range errorCounts.byPlace {
		counts = append(counts, ErrorCount{Kind: key[0], Where: key[1], Count: n})
	}
	sort.Slice(counts, func(i, j int) bool {
		if counts[i].Kind != counts[j].Kind {
			return counts[i].Kind < counts[j].Kind
		}
		return counts[i].Where < counts[j].Where
	})
	return counts
}

// errorPlace is "file.go:Function" for the frame `skip` calls up (runtime.Callers counting), or, when a panic is under
// way, the first frame of our own code below the panic that isn't `must` (store.go's helper that turns an error into a
// panic: its caller is where it went wrong).
func errorPlace(skip int) string {
	pcs := make([]uintptr, 64)
	frames := runtime.CallersFrames(pcs[:runtime.Callers(skip, pcs)])
	caller, panicking := "", false
	for {
		frame, more := frames.Next()
		ours := strings.HasPrefix(frame.Function, "moku/") || strings.HasPrefix(frame.Function, "main.")
		switch {
		case frame.Function == "runtime.gopanic":
			panicking = true
		case panicking && ours && !strings.HasSuffix(frame.Function, "/brain.must"):
			return codePlace(frame)
		case caller == "" && ours:
			caller = codePlace(frame)
		}
		if !more {
			break
		}
	}
	if caller == "" {
		return "unknown.go:unknown"
	}
	return caller
}

// codePlace: "moku/brain/internal/brain.(*Brain).Judge" in .../judge.go → "judge.go:Brain.Judge". Only letters, digits,
// "_" and "." are kept, so a place is always a word in code (the app and the relay check the same).
func codePlace(frame runtime.Frame) string {
	name := frame.Function[strings.LastIndex(frame.Function, "/")+1:]
	if dot := strings.Index(name, "."); dot >= 0 {
		name = name[dot+1:]
	}
	keep := func(text, extra string, limit int) string {
		var b strings.Builder
		for _, r := range text {
			if b.Len() >= limit {
				break
			}
			if r == '_' || strings.ContainsRune(extra, r) || ('a' <= r && r <= 'z') || ('A' <= r && r <= 'Z') || ('0' <= r && r <= '9') {
				b.WriteRune(r)
			}
		}
		return b.String()
	}
	file := keep(strings.TrimSuffix(filepath.Base(frame.File), ".go"), "+", 45)
	function := strings.Trim(keep(name, ".", 64), ".")
	if file == "" || function == "" || !('A' <= function[0] && function[0] <= 'Z' || 'a' <= function[0] && function[0] <= 'z' || function[0] == '_') {
		return "unknown.go:unknown"
	}
	return file + ".go:" + function
}
