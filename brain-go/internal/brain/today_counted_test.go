package brain

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"
)

// "Today counted" (docs/specs/next-three.md §3) reads the day with GET /v1/today?cached=1: Your day's own numbers, and
// only what Luna has already written. The card never makes a model call of its own.

// countedDay: a brain on the evening of a day of work (2026-10-03, 09:00 to 17:00, two goals, a drift every ninth
// verdict), and the day's date.
func countedDay(t *testing.T) (*Brain, *Store, string) {
	t.Helper()
	store := newPastStore(t)
	seedDays(t, store, time.Date(2026, 10, 4, 12, 0, 0, 0, Zone()), 1)
	now := time.Date(2026, 10, 3, 18, 0, 0, 0, Zone()).UnixMilli()
	b := NewBrain(BrainOptions{Store: store, Models: &fakeModels{}, Config: func() CompanionConfig { return DefaultConfig }, Now: func() int64 { return now }})
	return b, store, "2026-10-03"
}

func TestTheCardsDayHasYourDaysNumbersAndMakesNoModelCall(t *testing.T) {
	b, store, date := countedDay(t)
	b.Lock()
	card, err := b.TodayCached("")
	b.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	b.Settle()
	if calls := store.ModelCalls(""); len(calls) != 0 {
		t.Fatalf("the card's day made %d model calls (%s first)", len(calls), calls[0].Purpose)
	}
	if card.Note != nil {
		t.Errorf("no note was written yet, but the card got %q", *card.Note)
	}
	if card.Date != date || card.FocusedMinutes < 20 {
		t.Fatalf("the day: %s, %d focused minutes", card.Date, card.FocusedMinutes)
	}
	b.Lock()
	day, _ := b.Today("")
	b.Unlock()
	b.Settle()
	if card.FocusedMinutes != day.FocusedMinutes || card.Returns != day.Returns || card.LongestFocusMinutes != day.LongestFocusMinutes {
		t.Errorf("the card says %d focused, %d returns, %d longest; Your day %d, %d, %d", card.FocusedMinutes, card.Returns,
			card.LongestFocusMinutes, day.FocusedMinutes, day.Returns, day.LongestFocusMinutes)
	}
	if len(card.Goals) != len(day.Goals) || len(card.Goals) == 0 {
		t.Fatalf("the card has %d goals, Your day %d", len(card.Goals), len(day.Goals))
	}
	for i := range card.Goals {
		if card.Goals[i].ID != day.Goals[i].ID || card.Goals[i].Title != day.Goals[i].Title || card.Goals[i].Minutes != day.Goals[i].Minutes {
			t.Errorf("goal %d: the card's %s %q %d min, Your day's %s %q %d min", i, card.Goals[i].ID, card.Goals[i].Title,
				card.Goals[i].Minutes, day.Goals[i].ID, day.Goals[i].Title, day.Goals[i].Minutes)
		}
	}
}

func TestTheCardReusesLunasNoteOnlyWhileItsStillTrueAndItsTheCompanionsOwn(t *testing.T) {
	b, store, date := countedDay(t)
	read := func() *string {
		t.Helper()
		b.Lock()
		defer b.Unlock()
		day, err := b.TodayCached(date)
		if err != nil {
			t.Fatal(err)
		}
		return day.Note
	}
	// Your day opened: Luna wrote the note (the fake writes "x"). The card says the same note, and asks for nothing.
	b.Lock()
	_, _ = b.Today("")
	b.Unlock()
	b.Settle()
	before := len(store.ModelCalls(""))
	if note := read(); note == nil || *note != b.today.notes[date].text {
		t.Fatalf("the card didn't reuse the note Your day has: %v", note)
	}
	if after := len(store.ModelCalls("")); after != before {
		t.Errorf("reading the note for the card made %d calls", after-before)
	}

	// A note whose numbers are the day's is still true; one with a number the day no longer has isn't.
	b.Lock()
	day, _ := b.Today("")
	b.Unlock()
	b.Settle()
	cached := b.today.notes[date]
	cached.text = "You came back " + itoa(day.Returns) + " times. I put up the chimney."
	b.today.notes[date] = cached
	if note := read(); note == nil || *note != cached.text {
		t.Errorf("a note true of the day was dropped: %v", note)
	}
	cached.text = "You came back " + itoa(day.Returns+3) + " times."
	b.today.notes[date] = cached
	if note := read(); note != nil {
		t.Errorf("a note with numbers the day doesn't have was kept: %q", *note)
	}

	// A template (Luna was down) is the brain's own words: the card says its own line instead.
	cached.text, cached.template = "A wandering kind of day.", true
	b.today.notes[date] = cached
	if note := read(); note != nil {
		t.Errorf("a template note reached the card: %q", *note)
	}
	// Another companion's note is in another voice.
	cached.template, cached.companion = false, "someone else"
	b.today.notes[date] = cached
	if note := read(); note != nil {
		t.Errorf("another companion's note reached the card: %q", *note)
	}
}

func TestTheAppAsksForTheCardsDayWithCachedOne(t *testing.T) {
	b, store, date := countedDay(t)
	h := NewHandler(b, AppOptions{Port: 8020, Token: testToken})
	get := func(path string) TodaySummary {
		t.Helper()
		r := httptest.NewRequest("GET", "http://127.0.0.1:8020"+path, nil)
		r.Header.Set("Authorization", "Bearer "+testToken)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", path, w.Code, w.Body.String())
		}
		var day TodaySummary
		if err := json.Unmarshal(w.Body.Bytes(), &day); err != nil {
			t.Fatal(err)
		}
		return day
	}
	card := get("/v1/today?cached=1&date=" + date)
	b.Settle()
	if n := len(store.ModelCalls("")); n != 0 {
		t.Fatalf("GET /v1/today?cached=1 made %d model calls", n)
	}
	day := get("/v1/today?date=" + date)
	b.Settle()
	if card.FocusedMinutes != day.FocusedMinutes || card.Returns != day.Returns || card.LongestFocusMinutes != day.LongestFocusMinutes {
		t.Errorf("cached=1 changed the numbers: %+v vs %+v", card, day)
	}
	if len(store.ModelCalls("note")) == 0 {
		t.Errorf("the plain request should still write Your day's note")
	}
}

func itoa(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}
