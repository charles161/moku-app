package brain

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// There is one drift behaviour (2026-10-04, Charles: "there should be just one behaviour"). Someone who saved Gentle,
// Quick or their own minutes keeps their name, companion and Breaks & Water, and gets the one behaviour.
func TestSavedDriftPaceIsClearedAndTheRestKept(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	saved := `{
  "userName": "Charles",
  "annoyedAfterSec": 180,
  "standUpAfterSec": 600,
  "askAfterSec": 1200,
  "smileEverySec": 420,
  "drinkEverySec": 0,
  "breakAfterSec": 3600,
  "teaBreakMaxSec": 900,
  "graceSec": 5,
  "companion": "tetsu"
}
`
	if err := os.WriteFile(path, []byte(saved), 0o600); err != nil {
		t.Fatal(err)
	}
	// Read as it is, before the clearing: the old values don't apply and nothing else is lost (a refused file would
	// fall back to every default, the name too).
	before := LoadConfig(path)
	if before.GraceSec != DefaultConfig.GraceSec || before.AnnoyedAfterSec != DefaultConfig.AnnoyedAfterSec ||
		before.StandUpAfterSec != DefaultConfig.StandUpAfterSec || before.AskAfterSec != DefaultConfig.AskAfterSec ||
		before.SmileEverySec != DefaultConfig.SmileEverySec {
		t.Fatalf("the old drift pace must not apply: %+v", before)
	}
	if before.UserName != "Charles" || before.Companion != "tetsu" || before.DrinkEverySec != 0 || before.BreakAfterSec != 3600 || before.TeaBreakMaxSec != 900 {
		t.Fatalf("everything else must be kept: %+v", before)
	}
	cleared := ClearRetiredConfig(path)
	if strings.Join(cleared, ",") != "graceSec,annoyedAfterSec,standUpAfterSec,askAfterSec,smileEverySec" {
		t.Fatalf("cleared: %v", cleared)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range RetiredConfigKeys {
		if strings.Contains(string(data), key) {
			t.Fatalf("%s is still in the file:\n%s", key, data)
		}
	}
	if _, err := os.Stat(path + ".bad"); err == nil {
		t.Fatal("a retired key is not a refused one: no .bad copy")
	}
	after := LoadConfig(path)
	if after != before {
		t.Fatalf("clearing changed what is served:\n%+v\n%+v", before, after)
	}
	// Once: a second start finds nothing to clear and leaves the file alone.
	if again := ClearRetiredConfig(path); len(again) != 0 {
		t.Fatalf("second clear: %v", again)
	}
	// Everyone else is untouched too: no file, a file without them, and a file that isn't JSON.
	if got := ClearRetiredConfig(filepath.Join(t.TempDir(), "none.json")); got != nil {
		t.Fatalf("no file: %v", got)
	}
	broken := filepath.Join(t.TempDir(), "broken.json")
	os.WriteFile(broken, []byte("not json"), 0o600)
	if got := ClearRetiredConfig(broken); got != nil {
		t.Fatalf("a file that isn't JSON is left alone: %v", got)
	}
}

// The drift timings can't be saved any more (an old Settings or a stray request can't bring the choice back), and
// saving something else carries a stale file's retired keys away.
func TestDriftTimingsAreNoLongerSettable(t *testing.T) {
	for _, body := range []string{`{"graceSec": 5}`, `{"annoyedAfterSec": 120}`, `{"standUpAfterSec": 600}`, `{"askAfterSec": 1200}`} {
		if _, issues, _ := ParseConfigPatch([]byte(body)); len(issues) == 0 {
			t.Fatalf("%s must be refused: the drift ladder is one behaviour", body)
		}
	}
	path := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(path, []byte(`{"userName": "Riley", "askAfterSec": 99999}`), 0o600)
	saved, err := SaveConfig(map[string]any{"drinkEverySec": 1800.0}, path)
	if err != nil || saved.UserName != "Riley" || saved.AskAfterSec != DefaultConfig.AskAfterSec {
		t.Fatalf("saved: %+v %v", saved, err)
	}
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), "askAfterSec") {
		t.Fatalf("a retired key must not be written back:\n%s", data)
	}
	if _, err := os.Stat(path + ".bad"); err == nil {
		t.Fatal("no .bad copy for a retired key")
	}
}

// A key this brain doesn't know comes from a newer Moku, after the person went back to an older one. Charles's Mac,
// 2026-10-06, 0.1.7's brain on 0.1.8's file: "config.json ignored (companion: Unrecognized key); using defaults", so Moku
// forgot his name and his Breaks & Water. The key is skipped; everything this brain knows still applies.
func TestAKeyFromANewerMokuIsSkippedAndTheRestKept(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"userName": "Charles", "drinkEverySec": 0, "breakAfterSec": 3600, "somethingNewer": true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	got := LoadConfig(path)
	if got.UserName != "Charles" || got.DrinkEverySec != 0 || got.BreakAfterSec != 3600 {
		t.Fatalf("the keys it knows must apply: %+v", got)
	}
	// A bad value for a key it knows still refuses the file: a typo never half-applies.
	if err := os.WriteFile(path, []byte(`{"userName": "Charles", "drinkEverySec": -5}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := LoadConfig(path); got != DefaultConfig {
		t.Fatalf("a bad value must refuse the file: %+v", got)
	}
}
