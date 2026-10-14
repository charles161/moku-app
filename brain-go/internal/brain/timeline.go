package brain

import (
	"fmt"
	"math"
	"sort"
)

// The verdict timeline turned into time. Everything the world and the Today window report comes from here:
//   - Each verdict covers the time from its sample to the next one, at most CoverMs. A longer silence is a gap.
//   - A correction from the Today window replaces the state.
//   - For focus, an unknown verdict keeps the state and thread before it, as the app does.

const CoverMs = 60_000

type Span struct {
	SampleID          string
	Start, End, Next  int64
	State             string
	Effective         string
	EffectiveThreadID *string
	ThreadID          *string
	Activity          *string
	Category          *string
	BundleID          string
	AppName           string
	Title             string
	URL               *string
	Host              *string
}

func (s Span) screen() Screen { return Screen{BundleID: s.BundleID, AppName: s.AppName, Title: s.Title, URL: s.URL} }

func toSpans(rows []TimelineRow, now int64) []Span {
	var carry spanCarry
	return carry.spans(rows, now)
}

// spanCarry is what toSpans remembers from row to row: the last known state and its thread, which an unknown verdict
// keeps. The world cache keeps one to pick up the timeline partway through.
type spanCarry struct {
	state  string
	thread *string
	known  bool
}

// follow takes a row into the carry and returns the row's own state and thread, with its relabel applied.
func (c *spanCarry) follow(row TimelineRow) (state string, threadID *string) {
	state, threadID = row.State, row.ThreadID
	if row.Relabel != nil {
		state = *row.Relabel
		if state == "drifting" {
			threadID = nil
		}
	}
	if state != "unknown" {
		c.state, c.thread, c.known = state, threadID, true
	}
	return state, threadID
}

// spans: the rows as spans, carrying on from c (and leaving c as it stands after the last row).
func (c *spanCarry) spans(rows []TimelineRow, now int64) []Span {
	spans := make([]Span, len(rows))
	for i, row := range rows {
		state, threadID := c.follow(row)
		next := max(now, row.TS)
		if i+1 < len(rows) {
			next = rows[i+1].TS
		}
		effective := "unknown"
		if c.known {
			effective = c.state
		}
		effectiveThread := threadID
		if state == "unknown" {
			effectiveThread = nil
			if c.known {
				effectiveThread = c.thread
			}
		}
		spans[i] = Span{SampleID: row.SampleID, Start: row.TS, End: min(next, row.TS+CoverMs), Next: next, State: state,
			Effective: effective, EffectiveThreadID: effectiveThread, ThreadID: threadID, Activity: row.Activity, Category: row.Category,
			BundleID: row.BundleID, AppName: row.AppName, Title: row.Title, URL: row.URL, Host: siteOf(row.URL)}
	}
	return spans
}

type Window struct{ Start, End int64 }

type threadFocus struct{ WindowMs, TotalMs int64 }

type FocusStats struct {
	FocusMs, LongestMs int64
	ByThread           map[string]*threadFocus
}

// focusStats: focus inside window (and per thread, in the window and in total). Longest: the longest stretch of
// working time that continues through short breaks and ends once the person has been away from work longer than
// shortDriftMaxMs.
func focusStats(spans []Span, w Window, shortDriftMaxMs int64) FocusStats {
	stats := FocusStats{ByThread: map[string]*threadFocus{}}
	var stretch, awayFromWork int64
	for _, s := range spans {
		working := s.Effective == "working"
		var thread *threadFocus
		if working && s.EffectiveThreadID != nil {
			thread = stats.ByThread[*s.EffectiveThreadID]
			if thread == nil {
				thread = &threadFocus{}
				stats.ByThread[*s.EffectiveThreadID] = thread
			}
			thread.TotalMs += s.End - s.Start
		}
		covered := overlap(s.Start, s.End, w)
		gap := overlap(s.End, s.Next, w)
		if covered == 0 && gap == 0 {
			continue
		}
		if working {
			if awayFromWork > shortDriftMaxMs {
				stretch = 0
			}
			awayFromWork = 0
			stretch += covered
			stats.LongestMs = max(stats.LongestMs, stretch)
			stats.FocusMs += covered
			if thread != nil {
				thread.WindowMs += covered
			}
		} else {
			awayFromWork += covered
		}
		awayFromWork += gap
	}
	return stats
}

type Segment struct {
	DaySegment
	Spans []Span
}

type SpanLabels struct{ Activity, Category *string }

// daySegments: the day's ribbon: consecutive verdicts with the same shown state, app, site, thread, activity and
// bucket, clipped to window. A gap starts a new segment. The id is the first sample's id, stable as the day goes on.
func daySegments(spans []Span, w Window, labelsOf func(Span) SpanLabels) []*Segment {
	var segments []*Segment
	for _, span := range spans {
		start, end := max(span.Start, w.Start), min(span.End, w.End)
		if end <= start {
			continue
		}
		labels := labelsOf(span)
		if n := len(segments); n > 0 {
			last := segments[n-1]
			if last.End == start && last.State == span.State && last.BundleID == span.BundleID && eqStr(last.Host, span.Host) &&
				eqStr(last.ThreadID, span.ThreadID) && eqStr(last.Activity, labels.Activity) && eqStr(last.Category, labels.Category) {
				last.End = end
				last.Spans = append(last.Spans, span)
				continue
			}
		}
		segments = append(segments, &Segment{DaySegment: DaySegment{ID: "seg-" + span.SampleID, Start: start, End: end, State: span.State,
			App: span.AppName, BundleID: span.BundleID, Host: span.Host, ThreadID: span.ThreadID, Activity: labels.Activity, Category: labels.Category},
			Spans: []Span{span}})
	}
	return segments
}

// toStones: one stone per returned event: how long the drift was, where it went, and the focus that followed.
func toStones(spans []Span, returns []ReturnEvent, threadTitle func(id string) *string) []StoneMemory {
	stones := make([]StoneMemory, 0, len(returns))
	for _, r := range returns {
		stones = append(stones, draftStone(spans, r).titled(threadTitle))
	}
	return stones
}

// stoneDraft: a stone before its thread's title is looked up, and the spans it was read from: lo to hi (hi is
// len(spans) when it ran on past the last one). The world cache keeps the drafts whose spans can no longer change.
type stoneDraft struct {
	stone    StoneMemory
	threadID *string
	lo, hi   int
	// pastStart: the drift before the return ran back past the first span, so earlier spans could change it.
	pastStart bool
}

func draftStone(spans []Span, r ReturnEvent) stoneDraft {
	d := stoneDraft{lo: len(spans), hi: -1}
	read := func(first, last int) { d.lo, d.hi = min(d.lo, first), max(d.hi, last) }
	var driftSeconds int64
	if r.Value != nil && *r.Value > 0 {
		driftSeconds = int64(Round(*r.Value))
	} else {
		var first, last int
		driftSeconds, first, last = driftBefore(spans, r.TS)
		d.pastStart = first < 0
		read(max(first, 0), last)
	}
	followingMs, followingThread, first, last := followingFocus(spans, r.TS)
	read(first, last)
	place, first, last := driftPlace(spans, r.TS-driftSeconds*1000, r.TS)
	read(first, last)
	d.threadID = followingThread
	if d.threadID == nil {
		d.threadID = r.ThreadID
	}
	d.stone = StoneMemory{ID: fmt.Sprintf("stone-%d", r.ID), TS: r.TS, DriftSeconds: driftSeconds, From: place,
		FollowingFocusMinutes: int64(math.Floor(float64(followingMs) / 60_000))}
	return d
}

func (d stoneDraft) titled(threadTitle func(id string) *string) StoneMemory {
	stone := d.stone
	if d.threadID != nil {
		stone.ThreadTitle = threadTitle(*d.threadID)
	}
	return stone
}

// Spans are in time order (Start, and so Next, never go back), so each stone looks only at the spans around its
// return instead of the whole history: with every stone ever made, scanning all spans for each one cost seconds of
// CPU per /v1/world (2026-10-02).

// firstStartingAt: the index of the first span starting at or after ts.
func firstStartingAt(spans []Span, ts int64) int {
	return sort.Search(len(spans), func(i int) bool { return spans[i].Start >= ts })
}

// driftPlace: the site or app where most of the drift in [from, to) was spent. It reads spans first to last (last is
// len(spans) when it ran past the end).
func driftPlace(spans []Span, from, to int64) (place string, first, last int) {
	order := []string{}
	time := map[string]int64{}
	// A span ends at most CoverMs after it starts, so one starting earlier can't reach from.
	first, last = firstStartingAt(spans, from-CoverMs), len(spans)
	for i := first; i < len(spans); i++ {
		s := spans[i]
		if s.Start >= to {
			last = i
			break
		}
		if s.Effective != "drifting" {
			continue
		}
		ms := overlap(s.Start, s.End, Window{from, to})
		if ms > 0 {
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
	return best, first, last
}

// returnSlackMs: the app stamps a return a moment after the working sample that ended the drift, so work (or drift)
// within this much of the return belongs to the return itself.
const returnSlackMs = 60_000

// driftBefore: seconds of non-working time right before a return, when the event didn't say. It reads spans last
// back to first (first is -1 when it ran back past the first span).
func driftBefore(spans []Span, ts int64) (seconds int64, first, last int) {
	var ms int64
	inDrift := false
	last, first = firstStartingAt(spans, ts)-1, -1
	for i := last; i >= 0; i-- {
		s := spans[i]
		if s.Effective == "working" {
			if !inDrift && s.Start >= ts-returnSlackMs {
				continue // the return's own working sample
			}
			first = i
			break
		}
		inDrift = true
		ms += min(s.Next, ts) - s.Start
	}
	return int64(Round(float64(ms) / 1000)), first, last
}

// followingFocus: working time from a return until the person leaves work again (or over two minutes of silence).
// It reads spans first to last (last is len(spans) when it ran past the end).
func followingFocus(spans []Span, ts int64) (ms int64, threadID *string, first, last int) {
	threadSet := false
	started := false
	first, last = sort.Search(len(spans), func(i int) bool { return spans[i].Next > ts }), len(spans)
	for i := first; i < len(spans); i++ {
		s := spans[i]
		if s.Effective != "working" {
			if !started && s.Start < ts+returnSlackMs {
				continue
			}
			last = i
			break
		}
		started = true
		if !threadSet && s.EffectiveThreadID != nil {
			threadID, threadSet = s.EffectiveThreadID, true
		}
		ms += max(0, s.End-max(s.Start, ts))
		if s.Next-s.End > CoverMs {
			last = i
			break
		}
	}
	return ms, threadID, first, last
}

func overlap(start, end int64, w Window) int64 {
	return max(0, min(end, w.End)-max(start, w.Start))
}
