package brain

import (
	"os"
	"testing"
	"time"
)

// MOKU_BENCH_DB=<a copy of moku.sqlite> go test -run '^$' -bench World ./internal/brain
func benchStore(b *testing.B) *Store {
	path := os.Getenv("MOKU_BENCH_DB")
	if path == "" {
		b.Skip("MOKU_BENCH_DB isn't set")
	}
	store, err := OpenStore(path)
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { store.Close() })
	return store
}

func BenchmarkWorldSnapshot(b *testing.B) {
	store := benchStore(b)
	now := time.Now().UnixMilli()
	for b.Loop() {
		worldSnapshot(store, DefaultConfig, now)
	}
}

// The brain's path: the cache, built once a day, then read from today's rows.
func BenchmarkWorldCache(b *testing.B) {
	store := benchStore(b)
	now := time.Now().UnixMilli()
	var cache worldCache
	cache.snapshot(store, DefaultConfig, now, inline)
	for b.Loop() {
		cache.snapshot(store, DefaultConfig, now, inline)
	}
	if cache.builds > 1 {
		b.Fatalf("%d builds", cache.builds)
	}
}

func BenchmarkWorldParts(b *testing.B) {
	store := benchStore(b)
	now := time.Now().UnixMilli()
	var rows []TimelineRow
	var spans []Span
	b.Run("timeline", func(b *testing.B) {
		for b.Loop() {
			rows = store.Timeline(0, MaxSafeInteger)
		}
	})
	b.Run("spans", func(b *testing.B) {
		for b.Loop() {
			spans = toSpans(rows, now)
		}
	})
	b.Run("focusStats", func(b *testing.B) {
		for b.Loop() {
			focusStats(spans, Window{0, now + 1}, 120_000)
		}
	})
	b.Run("stones", func(b *testing.B) {
		returns := store.Returns(0, MaxSafeInteger)
		for b.Loop() {
			toStones(spans, returns, func(id string) *string { return threadTitle(store, id) })
		}
	})
	b.Run("threads", func(b *testing.B) {
		stats := focusStats(spans, Window{startOfDay(now), now + 1}, 120_000)
		for b.Loop() {
			threadSummaries(store, stats)
		}
	})
}
