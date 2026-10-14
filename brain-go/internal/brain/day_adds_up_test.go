package brain

import "testing"

// Your day adds up: the work rows (grouped by app) come to the day's focused minutes. A stretch Moku couldn't judge
// (a neutral app, Jev failing) keeps the state before it, so after work it counts as focus, and builds the house: its
// row must be there too. Found by qa-behaviour's student session (2026-10-06): 10 minutes in Preview between two
// pieces of work made the rows 217 minutes against 227 focused.
func TestYourDaysWorkRowsAddUpToItsFocusedMinutes(t *testing.T) {
	const minute = int64(60_000)
	thread, studying, learning := "t1", "studying organic chemistry", "learning"
	var rows []TimelineRow
	add := func(from, to int64, state, bundle, app string, work bool) {
		for m := from; m < to; m++ {
			row := TimelineRow{SampleID: "s" + string(rune('a'+len(rows))), TS: m * minute, State: state, BundleID: bundle, AppName: app}
			if work {
				row.ThreadID, row.Activity, row.Category = &thread, &studying, &learning
			}
			rows = append(rows, row)
		}
	}
	add(0, 20, "working", "com.readdle.PDFExpert-Mac", "PDF Expert", true)
	add(20, 30, "unknown", "com.apple.Preview", "Preview", false) // neither work nor drift: Moku keeps working
	add(30, 45, "working", "com.apple.Notes", "Notes", true)
	add(45, 50, "drifting", "net.whatsapp.WhatsApp", "WhatsApp", false)
	add(50, 55, "unknown", "com.apple.systempreferences", "System Settings", false) // after a drift: not focus
	add(55, 60, "working", "com.apple.Notes", "Notes", true)
	window := Window{0, 60 * minute}
	spans := toSpans(rows, window.End)
	segments := daySegments(spans, window, func(s Span) SpanLabels { return SpanLabels{Activity: s.Activity, Category: s.Category} })

	focused := minutes(focusStats(spans, window, 120_000).FocusMs)
	var built int64
	for _, row := range builtRows(segments) {
		built += row.Minutes
	}
	if focused != 50 {
		t.Fatalf("focused %d minutes, want 50 (work and the unknown stretch after it)", focused)
	}
	if built != focused {
		t.Errorf("the work rows come to %d minutes, the day says %d focused", built, focused)
	}
	for _, row := range builtRows(segments) {
		if row.App == "System Settings" {
			t.Errorf("the unknown stretch after a drift became a work row (%d min)", row.Minutes)
		}
	}
}
