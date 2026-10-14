package brain

import "testing"

// "This is work" / "This isn't work" from the companion's right-click (Charles, 2026-10-14) names no Your day segment:
// it says since when. Every moment from then until the correction is relabeled, and nothing before it.
func TestACorrectionFromTheCompanionRelabelsEverythingSinceItsStart(t *testing.T) {
	b := newTestBrain(t, &fakeModels{oracle: charlesDay}, false)
	for i := int64(0); i < 3; i++ {
		judgeAt(b, baseTs+i*minute, leetcode)
	}
	since := float64(baseTs + minute)
	b.Feedback(Feedback{TS: float64(baseTs + 3*minute), Kind: "markedNotWork", Since: &since})
	rows := b.Store.Timeline(baseTs-1, baseTs+3*minute)
	if len(rows) != 3 {
		t.Fatalf("%d timeline rows, want 3", len(rows))
	}
	if rows[0].Relabel != nil {
		t.Errorf("the moment before the correction's start was relabeled %q", *rows[0].Relabel)
	}
	for _, row := range rows[1:] {
		if row.Relabel == nil || *row.Relabel != "drifting" {
			t.Errorf("moment at %d not relabeled drifting: %v", row.TS-baseTs, row.Relabel)
		}
	}
}
