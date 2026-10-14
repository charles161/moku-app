package brain

import (
	"encoding/json"
	"net/http/httptest"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// The brain's own errors (errors.go): counted by kind and place for the app to read on /health, never their message.

// A place the app and the relay take (MokuKit ErrorReports.isPlace, proxy events.js PLACE).
var placeInCode = regexp.MustCompile(`^[A-Za-z0-9_+]{1,48}\.(?:swift|go):[A-Za-z_][A-Za-z0-9_.]{0,63}$`)

func countOf(kind, where string) int {
	for _, c := range ErrorCounts() {
		if c.Kind == kind && c.Where == where {
			return c.Count
		}
	}
	return 0
}

func resetErrorCounts(t *testing.T) {
	errorCounts.Lock()
	errorCounts.byPlace = map[[2]string]int{}
	errorCounts.Unlock()
	t.Cleanup(func() {
		errorCounts.Lock()
		errorCounts.byPlace = map[[2]string]int{}
		errorCounts.Unlock()
	})
}

func giveSpaceBack() {
	LogError(ErrDisk, "moku brain: couldn't give space back (%v)", "/Users/priya/.moku/moku.sqlite: disk full")
}

func TestAnErrorIsCountedByKindAndTheFunctionThatLoggedIt(t *testing.T) {
	resetErrorCounts(t)
	giveSpaceBack()
	giveSpaceBack()
	if n := countOf(ErrDisk, "errors_test.go:giveSpaceBack"); n != 2 {
		t.Fatalf("counts %+v, want 2 for errors_test.go:giveSpaceBack", ErrorCounts())
	}
	out := JSON(ErrorCounts())
	if strings.Contains(out, "priya") || strings.Contains(out, "disk full") {
		t.Errorf("a count carried the message: %s", out)
	}
}

func TestAPanicIsCountedWhereItHappenedNotWhereItWasRecovered(t *testing.T) {
	resetErrorCounts(t)
	<-NewBackground().Go(func() { panicInATask(nil) }).Done()
	if n := countOf(ErrTask, "errors_test.go:panicInATask"); n != 1 {
		t.Fatalf("counts %+v, want the task's panic at errors_test.go:panicInATask", ErrorCounts())
	}
}

func panicInATask(m map[string]int) { m["boom"] = 1 } // a nil map: a runtime panic, below our own frame

func TestARequestThatFailsInsideTheBrainIsCountedAndListedOnHealth(t *testing.T) {
	resetErrorCounts(t)
	b := newTestBrain(t, &fakeModels{}, false)
	handler := NewHandler(b, AppOptions{Port: 8020})
	b.Store.Close() // every read now fails inside the brain: a 500
	get := func(path string) *httptest.ResponseRecorder {
		req := httptest.NewRequest("GET", path, nil)
		req.Host = "127.0.0.1:8020"
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		return w
	}
	if w := get("/v1/world"); w.Code != 500 {
		t.Fatalf("/v1/world on a closed store: %d", w.Code)
	}
	var health struct {
		Errors []ErrorCount `json:"errors"`
	}
	if err := json.Unmarshal(get("/health").Body.Bytes(), &health); err != nil {
		t.Fatal(err)
	}
	if len(health.Errors) != 1 || health.Errors[0].Kind != ErrRequest || health.Errors[0].Count != 1 {
		t.Fatalf("/health errors: %+v", health.Errors)
	}
	t.Logf("counted at %s", health.Errors[0].Where)
	if where := health.Errors[0].Where; !placeInCode.MatchString(where) || strings.HasPrefix(where, "app.go:NewHandler") || where == "store.go:must" {
		t.Errorf("the place should be the function whose read failed, as a place in code: %q", where)
	}
}

func TestAPlaceIsTheFileAndTheFunctionWithoutPackageOrPointer(t *testing.T) {
	for _, c := range []struct{ function, file, want string }{
		{"moku/brain/internal/brain.(*Brain).Judge", "moku/brain/internal/brain/judge.go", "judge.go:Brain.Judge"},
		{"moku/brain/internal/brain.NewHandler.func1.1", "moku/brain/internal/brain/app.go", "app.go:NewHandler.func1.1"},
		{"moku/brain/internal/brain.mustParse[...]", "moku/brain/internal/brain/app.go", "app.go:mustParse"},
		{"main.main.func2", "moku/brain/main.go", "main.go:main.func2"},
		{"moku/brain/internal/brain.(*Store).Retain", "/Users/priya/My Code/retention.go", "retention.go:Store.Retain"},
		{"moku/brain/internal/brain.(*Store).Split", "/tmp/notes.v2.go", "notesv2.go:Store.Split"},
		{"moku/brain/internal/brain.", "x.go", "unknown.go:unknown"},
	} {
		if got := codePlace(runtime.Frame{Function: c.function, File: c.file}); got != c.want {
			t.Errorf("codePlace(%s, %s) = %q, want %q", c.function, c.file, got, c.want)
		}
	}
}

func TestPlacesAreAlwaysWordsInCodeAndThereAreNeverTooMany(t *testing.T) {
	resetErrorCounts(t)
	for i := 0; i < maxErrorPlaces+10; i++ {
		countError(ErrTask, "f"+strings.Repeat("x", i%40)+".go:Function"+strings.Repeat("y", i))
	}
	if n := len(ErrorCounts()); n != maxErrorPlaces+1 {
		t.Errorf("%d places, want %d and one for the rest", n, maxErrorPlaces+1)
	}
	if n := countOf(ErrTask, "other.go:other"); n != 10 {
		t.Errorf("the rest: %d, want 10", n)
	}
	for _, c := range ErrorCounts() {
		if !placeInCode.MatchString(c.Where) {
			t.Errorf("not a place in code: %q", c.Where)
		}
	}
}
