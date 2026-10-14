package brain

import (
	"math/rand"
	"testing"
)

// The stone helpers look only at spans near their return; they must answer exactly as a scan of every span does.
// The scans below are the versions they replaced.

func driftBeforeScan(spans []Span, ts int64) int64 {
	var ms int64
	inDrift := false
	for i := len(spans) - 1; i >= 0; i-- {
		s := spans[i]
		if s.Start >= ts {
			continue
		}
		if s.Effective == "working" {
			if !inDrift && s.Start >= ts-returnSlackMs {
				continue
			}
			break
		}
		inDrift = true
		ms += min(s.Next, ts) - s.Start
	}
	return int64(Round(float64(ms) / 1000))
}

func followingFocusScan(spans []Span, ts int64) (int64, *string) {
	var ms int64
	var threadID *string
	threadSet, started := false, false
	for _, s := range spans {
		if s.Next <= ts {
			continue
		}
		if s.Effective != "working" {
			if !started && s.Start < ts+returnSlackMs {
				continue
			}
			break
		}
		started = true
		if !threadSet && s.EffectiveThreadID != nil {
			threadID, threadSet = s.EffectiveThreadID, true
		}
		ms += max(0, s.End-max(s.Start, ts))
		if s.Next-s.End > CoverMs {
			break
		}
	}
	return ms, threadID
}

func driftPlaceScan(spans []Span, from, to int64) string {
	order := []string{}
	time := map[string]int64{}
	for _, s := range spans {
		if s.Effective != "drifting" {
			continue
		}
		if ms := overlap(s.Start, s.End, Window{from, to}); ms > 0 {
			place := s.AppName
			if s.Host != nil {
				place = *s.Host
			}
			if _, seen := time[place]; !seen {
				order = append(order, place)
			}
			time[place] += ms
		}
	}
	best, bestMs := "somewhere else", int64(0)
	for _, place := range order {
		if time[place] > bestMs {
			best, bestMs = place, time[place]
		}
	}
	return best
}

// randomTimeline: verdicts a few seconds to a few minutes apart (some at the same moment), working, drifting, away
// or unknown, across a handful of apps, sites and threads.
func randomTimeline(r *rand.Rand, n int) []Span {
	states := []string{"working", "working", "drifting", "away", "unknown"}
	apps := []string{"Chrome", "Cursor", "WhatsApp", "VLC"}
	hosts := []*string{nil, ptr("youtube.com"), ptr("x.com")}
	threads := []*string{nil, ptr("t_a"), ptr("t_b")}
	rows := make([]TimelineRow, n)
	ts := int64(1_000_000)
	for i := range rows {
		if r.Intn(10) > 0 {
			ts += int64(r.Intn(4)) * 1000 * int64(1+r.Intn(60))
		}
		var url *string
		if h := hosts[r.Intn(len(hosts))]; h != nil {
			url = ptr("https://" + *h + "/watch")
		}
		rows[i] = TimelineRow{SampleID: string(rune('a' + i%26)), TS: ts, State: states[r.Intn(len(states))],
			ThreadID: threads[r.Intn(len(threads))], AppName: apps[r.Intn(len(apps))], URL: url}
	}
	return toSpans(rows, ts+90_000)
}

func TestStoneHelpersMatchFullScans(t *testing.T) {
	r := rand.New(rand.NewSource(7))
	for round := 0; round < 300; round++ {
		spans := randomTimeline(r, 1+r.Intn(400))
		first, last := spans[0].Start, spans[len(spans)-1].Next
		for probe := 0; probe < 40; probe++ {
			ts := first - 120_000 + r.Int63n(last-first+240_000)
			if got, _, _ := driftBefore(spans, ts); got != driftBeforeScan(spans, ts) {
				want := driftBeforeScan(spans, ts)
				t.Fatalf("round %d: driftBefore(%d) = %d, the full scan says %d", round, ts, got, want)
			}
			gotMs, gotThread, _, _ := followingFocus(spans, ts)
			wantMs, wantThread := followingFocusScan(spans, ts)
			if gotMs != wantMs || !eqStr(gotThread, wantThread) {
				t.Fatalf("round %d: followingFocus(%d) = %d %v, the full scan says %d %v", round, ts, gotMs, gotThread, wantMs, wantThread)
			}
			from := ts - r.Int63n(30*60_000)
			if got, _, _ := driftPlace(spans, from, ts); got != driftPlaceScan(spans, from, ts) {
				want := driftPlaceScan(spans, from, ts)
				t.Fatalf("round %d: driftPlace(%d, %d) = %q, the full scan says %q", round, from, ts, got, want)
			}
		}
	}
}
