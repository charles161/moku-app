package brain

import (
	"fmt"
	"math/rand"
	"testing"
	"time"
)

// inline runs a function at once: no other request is waiting for the brain's lock in these tests.
func inline(fn func()) { fn() }

// The world cache must answer exactly as a read of the whole timeline does: across midnights, with corrections, labels
// written back, forgotten threads, late verdicts and returns that arrive late or without their drift clock. Two ways:
// as worldSnapshotFrom does with the same past kept as totals (stones from there on only), and, but for the stones, as
// the whole timeline read in one go (worldSnapshot).
func TestWorldCacheMatchesFullRead(t *testing.T) {
	r := rand.New(rand.NewSource(11))
	calls, rebuilds := 0, 0
	for round := 0; round < 40; round++ {
		store, err := OpenStore(":memory:")
		if err != nil {
			t.Fatal(err)
		}
		history := newRandomHistory(r, store)
		var cache worldCache
		for step := 0; step < 150; step++ {
			history.step()
			now := history.ts + int64(r.Intn(120_000))
			world := cache.snapshot(store, DefaultConfig, now, inline)
			got, want := JSON(world), JSON(worldSnapshotFrom(store, DefaultConfig, now, cache.past.Through))
			if got != want {
				t.Fatalf("round %d, step %d: the cache says\n%s\nthe timeline from %d says\n%s", round, step, got, cache.past.Through, want)
			}
			if step%4 == 0 { // the whole read is the slow one
				whole := worldSnapshot(store, DefaultConfig, now)
				world.Stones, whole.Stones = nil, nil
				if got, want := JSON(world), JSON(whole); got != want {
					t.Fatalf("round %d, step %d: the cache says\n%s\nthe whole timeline says\n%s", round, step, got, want)
				}
			}
			calls++
		}
		rebuilds += cache.builds
		store.Close()
	}
	// Most calls should come from the cache, or it isn't being tested (or isn't helping).
	if rebuilds*3 > calls {
		t.Fatalf("the cache read the whole timeline %d times in %d calls", rebuilds, calls)
	}
	t.Logf("%d calls, %d builds from the store", calls, rebuilds)
}

// randomHistory: a store's history made the way real ones are, one step at a time: stretches of samples (some at the
// same moment), time away (sometimes past midnight), returns (with or without the drift clock, some arriving late),
// corrections, labels written back, threads forgotten and started again, verdicts landing hours late, growth. ts is
// where its clock stands.
type randomHistory struct {
	r       *rand.Rand
	store   *Store
	ts      int64
	samples []string
}

var historyStates = []string{"working", "working", "working", "drifting", "away", "unknown"}
var historyApps = []string{"Chrome", "Cursor", "WhatsApp", "VLC"}
var historyHosts = []string{"", "youtube.com", "x.com", "github.com"}
var historyThreads = []string{"t_a", "t_b", "t_c"}

func newRandomHistory(r *rand.Rand, store *Store) *randomHistory {
	for _, id := range historyThreads {
		store.CreateThread(id, "Thread "+id, "", 0, nil)
	}
	return &randomHistory{r: r, store: store, ts: time.Date(2026, 9, 28, r.Intn(24), r.Intn(60), 0, 0, time.Local).UnixMilli()}
}

func (h *randomHistory) add(at int64) {
	r := h.r
	id := fmt.Sprintf("s%d", len(h.samples))
	h.samples = append(h.samples, id)
	var url *string
	if host := historyHosts[r.Intn(len(historyHosts))]; host != "" {
		url = ptr("https://" + host + "/page")
	}
	app := historyApps[r.Intn(len(historyApps))]
	h.store.InsertSample(ActivitySample{ID: id, TS: float64(at), App: AppInfo{BundleID: "b." + app, Name: app}, Window: &WindowInfo{Title: "a window", URL: url}})
	var thread *ThreadRef
	if r.Intn(3) > 0 {
		thread = &ThreadRef{ID: historyThreads[r.Intn(len(historyThreads))]}
	}
	h.store.InsertVerdict(Verdict{SampleID: id, State: historyStates[r.Intn(len(historyStates))], Thread: thread, Source: "test"}, at)
}

func (h *randomHistory) someSamples() []string {
	if len(h.samples) == 0 {
		return nil
	}
	from := h.r.Intn(len(h.samples))
	return h.samples[from:min(len(h.samples), from+1+h.r.Intn(20))]
}

func (h *randomHistory) step() {
	r, store := h.r, h.store
	switch k := r.Intn(20); {
	case k < 11: // a stretch of samples, a few seconds to a minute and a half apart, some at the same moment
		for range 1 + r.Intn(40) {
			if r.Intn(10) > 0 {
				h.ts += int64(1+r.Intn(90)) * 1000
			}
			h.add(h.ts)
		}
	case k < 13: // time away, sometimes past midnight
		h.ts += int64(r.Intn(9*60)) * 60_000
	case k == 13: // a return, with or without the drift clock, and now and then one that arrives late
		var value *float64
		if r.Intn(2) == 0 {
			v := float64(r.Intn(4 * 3600))
			value = &v
		}
		at := h.ts + int64(r.Intn(60_000))
		if r.Intn(5) == 0 {
			at -= int64(r.Intn(30)) * 3_600_000
		}
		var thread *string
		if r.Intn(2) == 0 {
			thread = ptr(historyThreads[r.Intn(len(historyThreads))])
		}
		store.InsertEvents([]CompanionEvent{{TS: float64(at), Type: "returned", ThreadID: thread, Value: value}})
	case k == 14: // "this was work" or "this wasn't work" on a stretch, often an old one
		store.Relabel(h.someSamples(), []string{"working", "drifting"}[r.Intn(2)], h.ts)
	case k == 15: // the labeler writes a thread back onto earlier verdicts
		thread := ptr(historyThreads[r.Intn(len(historyThreads))])
		store.WriteLabels(h.someSamples(), thread, nil, nil)
	case k == 16: // a thread forgotten, and started again
		if r.Intn(3) == 0 {
			id := historyThreads[r.Intn(len(historyThreads))]
			store.ForgetThread(id)
			store.CreateThread(id, "Thread "+id+" again", "", h.ts, nil)
		}
	case k == 17: // a verdict that lands late, hours back
		h.add(h.ts - int64(1+r.Intn(30*60))*60_000)
	case k == 18: // growth
		store.InsertEvents([]CompanionEvent{{TS: float64(h.ts), Type: "focusGrowth", Value: ptr(float64(r.Intn(20)))}})
	}
}
