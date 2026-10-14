package brain

import (
	"path/filepath"
	"testing"
)

// Settings › Breaks & Water can turn the water reminder and the break suggestion off: 0 for those two keys is
// accepted (saved, loaded back, and served), and still refused for every other timing.
func TestWaterAndBreaksCanBeTurnedOff(t *testing.T) {
	patch, issues, err := ParseConfigPatch([]byte(`{"drinkEverySec": 0, "breakAfterSec": 0}`))
	if err != nil || len(issues) > 0 || patch["drinkEverySec"] != 0.0 || patch["breakAfterSec"] != 0.0 {
		t.Fatalf("off patch: %v %v %v", patch, issues, err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	saved, err := SaveConfig(patch, path)
	if err != nil || saved.DrinkEverySec != 0 || saved.BreakAfterSec != 0 {
		t.Fatalf("saved: %+v %v", saved, err)
	}
	// The file isn't refused on the next read (a refused file would fall back to the defaults).
	loaded := LoadConfig(path)
	if loaded.DrinkEverySec != 0 || loaded.BreakAfterSec != 0 || loaded.SmileEverySec != DefaultConfig.SmileEverySec {
		t.Fatalf("loaded: %+v", loaded)
	}
	// Back on.
	if again, err := SaveConfig(map[string]any{"drinkEverySec": 1800.0}, path); err != nil || again.DrinkEverySec != 1800 || again.BreakAfterSec != 0 {
		t.Fatalf("back on: %+v %v", again, err)
	}
	for _, body := range []string{`{"smileEverySec": 0}`, `{"teaBreakMaxSec": 0}`, `{"drinkEverySec": -1}`, `{"breakAfterSec": -60}`} {
		if _, issues, _ := ParseConfigPatch([]byte(body)); len(issues) == 0 {
			t.Fatalf("%s must be refused", body)
		}
	}
}
