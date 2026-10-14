package brain

import (
	"path/filepath"
	"testing"
)

// OriginSample once built its query by prefixing every column of sampleColumns with an alias; the last column became a
// sub-select, so the query was a syntax error and the start-up thread upkeep (the rename of old titles, the merge of
// threads named the same, the world's warm-up) stopped for a database that still had threads to rename (launch QA, lens 3).
func TestAThreadsOriginSampleIsFoundWithItsText(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "moku.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	store.InsertSample(ActivitySample{ID: "s1", TS: 1_000, App: AppInfo{BundleID: "com.apple.dt.Xcode", Name: "Xcode"}, Window: &WindowInfo{Title: "handler.go"}, Text: ptr("func handler() {}")})
	store.CreateThread("t1", "A thread", "About it", 1_000, ptr("s1"))
	store.CreateThread("t2", "Another", "Without an origin", 1_000, nil)

	origin := store.OriginSample("t1")
	if origin == nil {
		t.Fatal("the thread's origin sample wasn't found")
	}
	if origin.ID != "s1" || origin.Title != "handler.go" {
		t.Errorf("the wrong sample: %+v", origin)
	}
	if origin.Text == nil || *origin.Text != "func handler() {}" {
		t.Errorf("the sample's text didn't come with it: %v", origin.Text)
	}
	if store.OriginSample("t2") != nil {
		t.Error("a thread with no origin sample should have none")
	}
}
