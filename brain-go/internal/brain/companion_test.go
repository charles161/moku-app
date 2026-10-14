package brain

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The app tells the brain who keeps the person company; the notes then name that companion's home and pieces.
func TestCompanionConfigNamesItsHomesPieces(t *testing.T) {
	patch, issues, err := ParseConfigPatch([]byte(`{"companion": "tetsu"}`))
	if err != nil || len(issues) > 0 || patch["companion"] != "tetsu" {
		t.Fatalf("companion patch: %v %v %v", patch, issues, err)
	}
	if _, issues, _ := ParseConfigPatch([]byte(`{"companion": "clippy"}`)); len(issues) == 0 {
		t.Fatal("an unknown companion must be refused")
	}
	if _, issues, _ := ParseConfigPatch([]byte(`{"companion": "yuzu"}`)); len(issues) == 0 {
		t.Fatal("Yuzu is retired: the app can't choose her")
	}
	path := filepath.Join(t.TempDir(), "config.json")
	if LoadConfig(path).Companion != "moku" {
		t.Fatal("Moku by default")
	}
	saved, err := SaveConfig(patch, path)
	if err != nil || saved.Companion != "tetsu" || LoadConfig(path).GraceSec != DefaultConfig.GraceSec {
		t.Fatalf("saved: %+v %v", saved, err)
	}

	if h := houseOf(150, HomeOf("tetsu")); h.pieces != 15 || *h.lastPiece != "the left fin" {
		t.Fatalf("tetsu at 150 min: %d %v", h.pieces, *h.lastPiece)
	}
	if h := houseOf(150, HomeOf("someone")); *h.lastPiece != "the left roof" {
		t.Fatalf("anyone else builds the cottage: %v", *h.lastPiece)
	}
	for _, id := range Companions {
		if len(HomeOf(id).Pieces) != len(HousePieces) {
			t.Fatalf("%s: every home has %d pieces", id, len(HousePieces))
		}
	}
	// Moku's note instructions are word for word what they were.
	moku := noteSystemFor(HomeOf("moku"))
	for _, words := range []string{"You are Moku, a small bunny who builds a little house", `("I put up the round door")`, `("We finished the house!")`} {
		if !strings.Contains(moku, words) {
			t.Fatalf("Moku's note lost %q", words)
		}
	}
	summary := TodaySummary{FocusedMinutes: 240}
	if note := templateNote(summary, HomeOf("tetsu")); !strings.Contains(note, "we finished the rocket") {
		t.Fatalf("template: %s", note)
	}
}

// Someone who chose Yuzu before she was retired keeps their name and timings, with Moku for company.
func TestRetiredCompanionFallsBackToMokuKeepingTheRest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"companion": "yuzu", "userName": "Charles", "drinkEverySec": 1200}`), 0o600); err != nil {
		t.Fatal(err)
	}
	config := LoadConfig(path)
	if config.Companion != "moku" || config.UserName != "Charles" || config.DrinkEverySec != 1200 {
		t.Fatalf("a retired companion must not cost the rest of the config: %+v", config)
	}
}

// ...and saving a setting later neither loses them nor leaves a config.json.bad behind for a key that was retired on purpose.
func TestSavingASettingWithARetiredCompanionKeepsTheRestAndLeavesNoBadCopy(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	os.WriteFile(path, []byte(`{"companion": "yuzu", "userName": "Charles", "graceSec": 7}`), 0o600)
	config, err := SaveConfig(map[string]any{"awayAfterIdleSec": float64(400)}, path)
	if err != nil {
		t.Fatal(err)
	}
	// graceSec was the drift pace's: one behaviour (RetiredConfigKeys) puts it back to the default with the rest kept.
	if config.UserName != "Charles" || config.GraceSec != DefaultConfig.GraceSec || config.AwayAfterIdleSec != 400 || config.Companion != "moku" {
		t.Errorf("the save lost something: %+v", config)
	}
	if _, err := os.Stat(path + ".bad"); err == nil {
		t.Error("a retired companion left a config.json.bad on every save")
	}
	if saved, _ := os.ReadFile(path); strings.Contains(string(saved), "yuzu") {
		t.Errorf("the retired choice is still saved: %s", saved)
	}
}
