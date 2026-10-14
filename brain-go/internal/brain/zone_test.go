package brain

import (
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The brain's days follow the Mac's time zone, also after the zone changes and across daylight saving.

// useZone makes the brain's zone `name` for one test.
func useZone(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Skipf("no zone data for %s: %v", name, err)
	}
	before := Zone()
	zone.Store(loc)
	t.Cleanup(func() { zone.Store(before) })
	return loc
}

// pointAtZoneFile makes the brain read the system zone from a file in a temp dir, holding `name`'s zone data.
func pointAtZoneFile(t *testing.T, name string) (set func(name string)) {
	t.Helper()
	dir := t.TempDir()
	file := filepath.Join(dir, "localtime")
	set = func(name string) {
		data, err := os.ReadFile("/usr/share/zoneinfo/" + name)
		if err != nil {
			t.Skipf("no zone file for %s: %v", name, err)
		}
		if err := os.WriteFile(file, data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	set(name)
	oldPath, oldFile, oldFrom, oldZone := localtimePath, zoneFile, zoneFromTZ, Zone()
	localtimePath, zoneFile, zoneFromTZ = file, nil, false
	t.Cleanup(func() {
		localtimePath, zoneFile, zoneFromTZ = oldPath, oldFile, oldFrom
		zone.Store(oldZone)
	})
	return set
}

func TestADayStartsAtMidnightInTheNewZoneAfterTheMacChangesZone(t *testing.T) {
	set := pointAtZoneFile(t, "Asia/Kolkata")
	refreshZoneNow()
	window, _ := dayWindow("2026-10-04")
	if want := time.Date(2026, 10, 3, 18, 30, 0, 0, time.UTC).UnixMilli(); window.Start != want {
		t.Fatalf("in Chennai the 4th starts at %d, want %d", window.Start, want)
	}

	set("Europe/London") // the lid was shut over the Atlantic
	if !refreshZoneNow() {
		t.Fatal("the change wasn't noticed")
	}
	window, _ = dayWindow("2026-10-04")
	if want := time.Date(2026, 10, 3, 23, 0, 0, 0, time.UTC).UnixMilli(); window.Start != want {
		t.Errorf("in London (BST) the 4th starts at %d, want %d", window.Start, want)
	}
	if got := localDate(time.Date(2026, 10, 4, 0, 30, 0, 0, time.UTC).UnixMilli()); got != "2026-10-04" {
		t.Errorf("00:30 UTC is on the 4th in London, got %s", got)
	}
}

func TestEveryRequestNoticesATimeZoneChange(t *testing.T) {
	set := pointAtZoneFile(t, "Asia/Kolkata")
	b := newTestBrain(t, &fakeModels{}, false)
	handler := NewHandler(b, AppOptions{Port: 8020})
	ask := func() {
		req := httptest.NewRequest("GET", "/health", nil)
		req.Host = "127.0.0.1:8020"
		handler.ServeHTTP(httptest.NewRecorder(), req)
	}
	ask()
	set("America/New_York")
	zoneCheck.Store(0) // the 5 seconds between looks have passed
	ask()
	if _, offset := time.UnixMilli(baseTs).In(Zone()).Zone(); offset != -4*3600 {
		t.Errorf("after the change Moku's day is still at UTC%+d s, want New York's -4 h", offset)
	}
}

func TestATimeZoneInTheBrainsEnvironmentIsNeverReread(t *testing.T) {
	set := pointAtZoneFile(t, "Asia/Kolkata")
	refreshZoneNow()
	zoneFromTZ = true // TZ was set when the brain started, as Go reads it
	set("Europe/London")
	zoneCheck.Store(0)
	RefreshZone()
	if _, offset := time.UnixMilli(baseTs).In(Zone()).Zone(); offset != 5*3600+1800 {
		t.Errorf("the zone moved to UTC%+d s although TZ pins it", offset)
	}
}

func TestADayIsAsLongAsTheClockSaysAcrossDaylightSaving(t *testing.T) {
	cases := []struct {
		zone, date string
		hours      float64
	}{
		{"America/New_York", "2026-03-07", 24}, {"America/New_York", "2026-03-08", 23}, {"America/New_York", "2026-03-09", 24},
		{"America/New_York", "2026-11-01", 25},
		{"Europe/London", "2026-03-29", 23}, {"Europe/London", "2026-10-25", 25},
		{"Australia/Lord_Howe", "2026-04-05", 24.5}, {"Australia/Lord_Howe", "2026-10-04", 23.5},
		{"Pacific/Auckland", "2026-09-27", 23}, {"Asia/Kolkata", "2026-10-04", 24},
	}
	for _, c := range cases {
		t.Run(c.zone+" "+c.date, func(t *testing.T) {
			useZone(t, c.zone)
			window, ok := dayWindow(c.date)
			if !ok {
				t.Fatal("not a day")
			}
			if got := float64(window.End-window.Start) / 3_600_000; got != c.hours {
				t.Errorf("%s in %s lasts %.1f h, want %.1f", c.date, c.zone, got, c.hours)
			}
			if got := localDate(window.Start); got != c.date {
				t.Errorf("the day's first moment is on %s", got)
			}
			if got := localDate(window.End - 1); got != c.date {
				t.Errorf("the day's last moment is on %s", got)
			}
		})
	}
}

// In Cairo, Havana, Santiago, Beirut and the Azores the clocks jump from 00:00 to 01:00, so midnight doesn't exist that
// day. Go's time.Date then answers with 23:00 the evening before, which put the day's start on the wrong date.
var skippedMidnights = []struct{ zone, date string }{
	{"America/Havana", "2026-03-08"}, {"Africa/Cairo", "2026-04-24"}, {"America/Santiago", "2026-09-06"},
	{"Asia/Beirut", "2026-03-29"}, {"Atlantic/Azores", "2026-03-29"},
}

func TestADayWhoseMidnightIsSkippedStartsAt0100(t *testing.T) {
	tried := 0
	for _, c := range skippedMidnights {
		t.Run(c.zone, func(t *testing.T) {
			loc := useZone(t, c.zone)
			y, m, d := 0, time.Month(0), 0
			fmt.Sscanf(c.date, "%d-%d-%d", &y, (*int)(&m), &d)
			if time.Date(y, m, d, 0, 0, 0, 0, loc).Day() == d {
				t.Skipf("this Mac's zone data has midnight on %s in %s", c.date, c.zone)
			}
			tried++
			window, ok := dayWindow(c.date)
			if !ok {
				t.Fatalf("%s isn't a day in %s, but it is", c.date, c.zone)
			}
			if got := time.UnixMilli(window.Start).In(loc); got.Hour() != 1 || got.Day() != d {
				t.Errorf("the day starts at %s, want 01:00 on the %dth", got, d)
			}
			if got := float64(window.End-window.Start) / 3_600_000; got != 23 {
				t.Errorf("the day lasts %.1f h, want 23", got)
			}
			if got := localDate(window.Start); got != c.date {
				t.Errorf("the day's first moment is on %s", got)
			}
		})
	}
}

func TestYourDayListsEachDateOnceWhenAMidnightIsSkipped(t *testing.T) {
	for _, c := range skippedMidnights {
		t.Run(c.zone, func(t *testing.T) {
			loc := useZone(t, c.zone)
			day, _ := time.ParseInLocation("2006-01-02 15:04", c.date+" 12:00", loc) // noon: midnight may not exist
			from, to := day.AddDate(0, 0, -1).Format("2006-01-02"), day.AddDate(0, 0, 1).Format("2006-01-02")
			store, err := OpenStore(":memory:")
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			now := day.AddDate(0, 0, 3).UnixMilli()
			b := NewBrain(BrainOptions{Store: store, Models: &fakeModels{}, Config: func() CompanionConfig { return DefaultConfig }, Now: func() int64 { return now }})
			days, err := b.Days(from, to)
			if err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, d := range days.Days {
				got = append(got, d.Date)
			}
			want := []string{from, c.date, to}
			if fmt.Sprint(got) != fmt.Sprint(want) {
				t.Errorf("Your day lists %v, want %v", got, want)
			}
		})
	}
}

// A minute of work, every minute, for days around a clock change: Your day lists each date once, in order, and the
// minutes land on the day the wall clock says.
func TestYourDayAcrossAClockChangeListsEachDateOnceWithTheRightMinutes(t *testing.T) {
	cases := []struct {
		zone, from, to string
		minutes        []int64
	}{
		{"America/New_York", "2026-03-07", "2026-03-09", []int64{1440, 1380, 1440}},
		{"America/New_York", "2026-10-31", "2026-11-02", []int64{1440, 1500, 1440}},
		{"Europe/London", "2026-03-28", "2026-03-30", []int64{1440, 1380, 1440}},
		{"Australia/Lord_Howe", "2026-10-03", "2026-10-05", []int64{1440, 1410, 1440}},
		{"America/Havana", "2026-03-07", "2026-03-09", []int64{1440, 1380, 1440}},
	}
	for _, c := range cases {
		t.Run(c.zone+" "+c.from, func(t *testing.T) {
			loc := useZone(t, c.zone)
			first, _ := dayWindow(c.from)
			last, _ := dayWindow(c.to)
			now := last.End + 6*3_600_000
			store, err := OpenStore(":memory:")
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			b := NewBrain(BrainOptions{Store: store, Models: &fakeModels{}, Config: func() CompanionConfig { return DefaultConfig }, Now: func() int64 { return now }})
			n := 0
			for ts := first.Start; ts < last.End; ts += 60_000 {
				n++
				id := fmt.Sprintf("dst-%d", n)
				store.InsertSample(ActivitySample{ID: id, TS: float64(ts), App: AppInfo{BundleID: "com.apple.dt.Xcode", Name: "Xcode"}, Window: &WindowInfo{Title: "x.swift"}})
				store.InsertVerdict(Verdict{SampleID: id, State: "working", Confidence: 1, Source: "shortcut", Reason: "test"}, ts)
			}
			days, err := b.Days(c.from, c.to)
			if err != nil {
				t.Fatal(err)
			}
			if len(days.Days) != len(c.minutes) {
				t.Fatalf("%d days listed, want %d: %+v", len(days.Days), len(c.minutes), days.Days)
			}
			for i, day := range days.Days {
				want := time.UnixMilli(first.Start).In(loc).Add(12*time.Hour).AddDate(0, 0, i).Format("2006-01-02")
				if day.Date != want {
					t.Errorf("day %d is %s, want %s", i, day.Date, want)
				}
				if got := day.FocusedMinutes; got < c.minutes[i]-2 || got > c.minutes[i] {
					t.Errorf("%s: %d focused minutes, want about %d", day.Date, got, c.minutes[i])
				}
			}
		})
	}
}
