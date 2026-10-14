package brain

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// The governor (docs/specs/governor.md): when the relay says "not now" for a long while (a Mac's daily share used,
// a trial ended), the brain asks no more until then, without retries, and a new token (an invite typed in) ends
// the wait at once. Before, a 402 paused 5 minutes and asked again, up to 288 times a day.

type relayStub struct {
	calls      int
	status     int
	retryAfter string
	body       string
}

func relayFor(t *testing.T, stub *relayStub) *httptest.Server {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		stub.calls++
		if stub.retryAfter != "" {
			w.Header().Set("retry-after", stub.retryAfter)
		}
		w.WriteHeader(stub.status)
		io.WriteString(w, stub.body)
	}))
	t.Cleanup(server.Close)
	return server
}

func credentialsFor(t *testing.T, server *httptest.Server) func(token string) {
	home := t.TempDir()
	t.Setenv("MOKU_HOME", home)
	t.Setenv("MOKU_DEV_ENV", "/nonexistent")
	for _, k := range CredentialKeys {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}
	return func(token string) {
		t.Helper()
		file := "MOKU_GATEWAY_URL=" + server.URL + "/v4/ai\nMOKU_ACCESS_TOKEN=" + token + "\n"
		if err := os.WriteFile(filepath.Join(home, "credentials.env"), []byte(file), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

const jevWork = `{"answers":{"kind":{"type":"choice","choice":"work","probabilities":{"work":1,"distraction":0}}},"usage":{"inputTokens":1,"outputTokens":1}}`

func TestADailyLimitRestsJevUntilTheRelaySaysAndANewTokenEndsItAtOnce(t *testing.T) {
	stub := &relayStub{status: 429, retryAfter: "3600", body: `{"error":"daily limit reached","code":"daily_limit"}`}
	server := relayFor(t, stub)
	useToken := credentialsFor(t, server)
	useToken("moku1.trial")
	now := int64(1_000_000)
	m := NewModels(ModelOptions{Transport: NewGateway(), Now: func() int64 { return now }})
	judge := func() JudgeOutcome { return m.Judge(OMap{{"window", "x"}}, QuestionSet{{"kind", kindQuestion}}, false) }

	if out := judge(); out.OK || stub.calls != 1 {
		t.Fatalf("a daily limit was retried: %d calls (ok=%v)", stub.calls, out.OK)
	}
	if h := m.Health().Judge; h.State != "resting" || h.RetryAt == nil || *h.RetryAt != now+3_600_000 {
		t.Fatalf("not resting until the relay's time: %+v", h)
	}
	now += 3_600_000 - 1
	judge()
	if stub.calls != 1 {
		t.Fatalf("asked again while resting: %d calls", stub.calls)
	}
	now++
	stub.status, stub.retryAfter, stub.body = 200, "", jevWork
	if out := judge(); !out.OK || stub.calls != 2 {
		t.Fatalf("no call when the rest was over: %d calls (ok=%v)", stub.calls, out.OK)
	}

	stub.status, stub.retryAfter, stub.body = 429, "3600", `{"error":"daily limit reached","code":"daily_limit"}`
	judge()
	useToken("moku1.invite")
	stub.status, stub.retryAfter, stub.body = 200, "", jevWork
	if out := judge(); !out.OK || stub.calls != 4 {
		t.Fatalf("a new token didn't end the rest: %d calls (ok=%v)", stub.calls, out.OK)
	}
	if h := m.Health().Judge; h.State != "ok" {
		t.Fatalf("still %q after a success", h.State)
	}
}

func TestAnEndedTrialPausesForTheRelaysSixHoursNotFiveMinutes(t *testing.T) {
	stub := &relayStub{status: 402, retryAfter: "21600", body: `{"error":"trial ended","code":"trial_ended"}`}
	server := relayFor(t, stub)
	credentialsFor(t, server)("moku1.ended")
	now := int64(1_000_000)
	m := NewModels(ModelOptions{Transport: NewGateway(), Now: func() int64 { return now }})
	judge := func() { m.Judge(OMap{{"window", "x"}}, QuestionSet{{"kind", kindQuestion}}, false) }

	judge()
	if h := m.Health().Judge; h.State != "paused" || h.RetryAt == nil || *h.RetryAt != now+21_600_000 {
		t.Fatalf("not paused for six hours: %+v", h)
	}
	now += breakerPauseMs
	judge()
	if stub.calls != 1 {
		t.Fatalf("asked again after 5 minutes: %d calls", stub.calls)
	}
}

func TestAPauseNeverOutlastsADay(t *testing.T) {
	b, now := newTestBreaker()
	b.Rest("daily_limit", 429, 7*86_400_000, "moku1.a")
	if h := b.Health(); *h.RetryAt != *now+86_400_000 {
		t.Fatalf("a relay asking for a week got %d ms", *h.RetryAt-*now)
	}
}
