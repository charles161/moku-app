package brain

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// "Delete my data" must leave nothing on disk while the brain keeps running, not only after it quits: Moku runs all day,
// and Time Machine copies ~/.moku every hour. Before the fix the write-ahead log still held every window title and every
// excerpt of screen text (thousands of copies) until the brain closed the database.
func TestDeleteMyDataLeavesNoTitleOrScreenTextOnDiskWhileTheBrainRuns(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moku.sqlite")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	title, text := "Quarterly-plan-ZQX-title", "a private message ZQX-screen-text"
	for i := 0; i < 200; i++ {
		store.InsertSample(ActivitySample{ID: fmt.Sprintf("s-%d", i), TS: float64(1_000_000 + i*1000), App: AppInfo{BundleID: "b", Name: "App"},
			Window: &WindowInfo{Title: title}, Text: &text})
	}

	store.DeleteEverything()

	for _, suffix := range []string{"", "-wal", "-shm"} {
		data, err := os.ReadFile(path + suffix)
		if err != nil {
			continue // a file that isn't there holds nothing
		}
		if n := bytes.Count(data, []byte(title)); n > 0 {
			t.Errorf("moku.sqlite%s still holds the window title %d times after Delete my data", suffix, n)
		}
		if n := bytes.Count(data, []byte(text)); n > 0 {
			t.Errorf("moku.sqlite%s still holds the screen text %d times after Delete my data", suffix, n)
		}
	}
	// The store still works afterwards.
	store.InsertSample(ActivitySample{ID: "after", TS: 2_000_000, App: AppInfo{BundleID: "b", Name: "App"}})
	if store.Sample("after") == nil {
		t.Error("the store doesn't take writes after Delete my data")
	}
}
