package brain

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A damaged database (a bad disk, a copy that was cut short, something else writing into ~/.moku) used to keep the
// brain from ever starting: it exited at once, the app restarted it five times and rested ten minutes, for ever.
// Moku would stay calm without a word. Now the damaged file is set aside and a new one starts.

func seedStore(t *testing.T, path string, rows int) {
	t.Helper()
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < rows; i++ {
		store.InsertSample(ActivitySample{ID: fmt.Sprintf("seed-%d", i), TS: float64(1_000_000 + i*1000), App: AppInfo{BundleID: "b", Name: "App"},
			Window: &WindowInfo{Title: strings.Repeat("a window title ", 8)}})
	}
	store.Close()
}

func TestAFileThatIsNotADatabaseIsSetAsideAndANewOneStarts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moku.sqlite")
	os.WriteFile(path, []byte(strings.Repeat("this is not a database ", 400)), 0o600)

	store, err := OpenStore(path)
	if err != nil {
		t.Fatalf("the brain can't start: %v", err)
	}
	defer store.Close()
	store.InsertSample(ActivitySample{ID: "fresh", TS: 1, App: AppInfo{BundleID: "b", Name: "App"}})
	if store.Sample("fresh") == nil {
		t.Error("the new database doesn't take writes")
	}
	kept, err := os.ReadFile(path + ".damaged")
	if err != nil || !strings.HasPrefix(string(kept), "this is not a database") {
		t.Errorf("the damaged file wasn't kept beside the new one: %v", err)
	}
	if info, _ := os.Stat(path + ".damaged"); info != nil && info.Mode().Perm() != 0o600 {
		t.Errorf("the set-aside file is %v, it holds screen text and must stay owner-only", info.Mode().Perm())
	}
}

func TestADatabaseWithADamagedPageIsSetAsideAndANewOneStarts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moku.sqlite")
	seedStore(t, path, 3000)
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	info, _ := file.Stat()
	// A run of zeros through the middle of the file: whole pages of a table, gone.
	file.WriteAt(make([]byte, 64*1024), info.Size()/2)
	file.Close()

	store, err := OpenStore(path)
	if err != nil {
		t.Fatalf("the brain can't start: %v", err)
	}
	defer store.Close()
	if store.LatestSample() != nil {
		t.Error("the new database isn't empty")
	}
	if _, err := os.Stat(path + ".damaged"); err != nil {
		t.Errorf("the damaged file wasn't kept: %v", err)
	}
}

func TestAHealthyDatabaseIsLeftAlone(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moku.sqlite")
	seedStore(t, path, 200)
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if store.Sample("seed-199") == nil {
		t.Error("history was lost")
	}
	if _, err := os.Stat(path + ".damaged"); err == nil {
		t.Error("a healthy database was set aside")
	}
}

func TestALockedDatabaseIsNotCalledDamaged(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moku.sqlite")
	seedStore(t, path, 10)
	holder, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close()
	holder.SetMaxOpenConns(1)
	if _, err := holder.Exec("PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE"); err != nil {
		t.Fatal(err)
	}
	// What the brain sees from a database another process holds: not damage, so nothing may be set aside.
	other, _ := sql.Open("sqlite", path)
	defer other.Close()
	other.Exec("PRAGMA busy_timeout = 50")
	_, err = other.Exec("CREATE TABLE IF NOT EXISTS probe (x)")
	if err == nil {
		t.Skip("this SQLite let a second writer in")
	}
	if isDamage(err) {
		t.Errorf("%q counts as damage", err)
	}
	if _, statErr := os.Stat(path + ".damaged"); statErr == nil {
		t.Error("a locked database was set aside")
	}
}

func TestOnlyCorruptionErrorsCountAsDamage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.sqlite")
	os.WriteFile(path, []byte(strings.Repeat("not sqlite ", 500)), 0o600)
	db, _ := sql.Open("sqlite", path)
	defer db.Close()
	_, err := db.Exec("CREATE TABLE t (x)")
	if err == nil || !isDamage(err) {
		t.Errorf("%v isn't called damage", err)
	}
	if isDamage(fmt.Errorf("database or disk is full (13)")) || isDamage(nil) {
		t.Error("a full disk or no error is called damage")
	}
}

func TestDeleteMyDataAlsoRemovesTheDamagedCopy(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moku.sqlite")
	os.WriteFile(path, []byte(strings.Repeat("this is not a database ", 400)), 0o600)
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	store.DeleteEverything()
	if _, err := os.Stat(path + ".damaged"); err == nil {
		t.Error(`"Delete my data" left the damaged copy, which still holds the screen history`)
	}
}

// What 0.1.7 leaves behind: its shadow-mode table, a row per judgment, which nothing reads any more.
func TestTheStoreOfVersion017MigratesAndLosesNothing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moku.sqlite")
	seedStore(t, path, 50)
	old, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	old.Exec(`CREATE TABLE reuse_shadow (id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, kind TEXT NOT NULL, sample_id TEXT, state TEXT NOT NULL, detail TEXT NOT NULL)`)
	old.Exec(`INSERT INTO reuse_shadow (ts, kind, sample_id, state, detail) VALUES (1, 'judge', 'seed-1', 'working', '{}')`)
	old.Close()

	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	var tables int
	store.db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'reuse_shadow'`).Scan(&tables)
	if tables != 0 {
		t.Error("the shadow table is still there")
	}
	if store.Sample("seed-49") == nil {
		t.Error("history was lost")
	}
}

// A home folder with a space or a percent sign in its name (a Mac's account is named by its owner).
func TestTheStoreOpensInAFolderWithOddCharactersInItsName(t *testing.T) {
	path := filepath.Join(t.TempDir(), "Charles Maria's moku %41 & co", "moku.sqlite")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	store.InsertSample(ActivitySample{ID: "x", TS: 1, App: AppInfo{BundleID: "b", Name: "App"}})
	store.Close()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("the database isn't where it was asked to be: %v", err)
	}
	again, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	if again.Sample("x") == nil {
		t.Error("what was written isn't there on the next open")
	}
}
