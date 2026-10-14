package brain

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Who may talk to the brain on 127.0.0.1 (app.go): the Mac app, which holds the brain token. Never a web page, and
// never another local process without the token (another macOS user, a sandboxed app).

const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func TestOnlyTheAppTalksToTheBrain(t *testing.T) {
	store, err := OpenStore(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.Close)
	// A config file of its own (never ~/.moku), so the app's PUT has somewhere to go.
	b := NewBrain(BrainOptions{Store: store, Models: &fakeModels{}, ConfigFile: filepath.Join(t.TempDir(), "config.json"), Now: func() int64 { return baseTs }})
	h := NewHandler(b, AppOptions{Port: 8020, Token: testToken})
	do := func(method, path string, headers map[string]string, body string) int {
		t.Helper()
		r := httptest.NewRequest(method, "http://127.0.0.1:8020"+path, strings.NewReader(body))
		for k, v := range headers {
			if k == "Host" {
				r.Host = v
			} else {
				r.Header.Set(k, v)
			}
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	app := map[string]string{"Authorization": "Bearer " + testToken}
	with := func(extra map[string]string) map[string]string {
		out := map[string]string{"Authorization": "Bearer " + testToken}
		for k, v := range extra {
			out[k] = v
		}
		return out
	}

	// The app, with its token: everything works, and the scheme's case doesn't matter.
	if code := do("GET", "/v1/config", app, ""); code != 200 {
		t.Fatalf("the app's config: %d", code)
	}
	if code := do("PUT", "/v1/config", map[string]string{"Authorization": "bearer " + testToken}, `{"userName":"Charles"}`); code != 200 {
		t.Fatalf("the app sets the name: %d", code)
	}
	// The supervisor's liveness check needs no token.
	if code := do("GET", "/health", nil, ""); code != 200 {
		t.Fatalf("health: %d", code)
	}

	// Another local process without the token, or with a wrong one: nothing, read or write.
	routes := [][3]string{
		{"GET", "/v1/config", ""}, {"GET", "/v1/world", ""}, {"GET", "/v1/threads", ""}, {"GET", "/v1/today", ""},
		{"GET", "/v1/days", ""}, {"GET", "/v1/counts", ""}, {"PUT", "/v1/config", `{"userName":"pwned"}`},
		{"POST", "/v1/judge", `{}`}, {"POST", "/v1/voice", `{}`}, {"POST", "/v1/feedback", `{"ts":1,"kind":"pat"}`},
		{"POST", "/v1/events", `[]`}, {"DELETE", "/v1/data", ""}, {"DELETE", "/v1/threads/t1", ""}, {"PATCH", "/v1/threads/t1", `{"title":"x"}`},
	}
	for _, r := range routes {
		for _, headers := range []map[string]string{nil, {"Authorization": "Bearer nope"}, {"Authorization": testToken}, {"Authorization": "Bearer " + testToken[:63]}} {
			if code := do(r[0], r[1], headers, r[2]); code != 401 {
				t.Errorf("%s %s with %v: %d, want 401", r[0], r[1], headers, code)
			}
		}
	}
	if b.Config().UserName != "Charles" {
		t.Fatalf("a refused PUT changed the name: %q", b.Config().UserName)
	}

	// A web page: never, even if it somehow had the token. A browser sends Origin on fetch and on form posts,
	// Sec-Fetch-Site on <img>, <script> and navigations, and a DNS-rebinding page's own Host.
	for name, extra := range map[string]map[string]string{
		"a fetch from another site":           {"Origin": "https://evil.example"},
		"a sandboxed frame":                   {"Origin": "null"},
		"an <img> or <script> tag":            {"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "no-cors"},
		"a page on another local port":        {"Sec-Fetch-Site": "same-site", "Sec-Fetch-Mode": "no-cors"},
		"a link to the brain from a web page": {"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "navigate"},
		"DNS rebinding":                       {"Host": "evil.example:8020"},
	} {
		for _, path := range []string{"/v1/today", "/health"} {
			if code := do("GET", path, with(extra), ""); code != 403 {
				t.Errorf("%s, %s: %d, want 403", name, path, code)
			}
		}
	}
	// Typed into the address bar (Sec-Fetch-Site: none) it's the person's own browser, but still no token: 401.
	if code := do("GET", "/v1/today", map[string]string{"Sec-Fetch-Site": "none"}, ""); code != 401 {
		t.Fatalf("address bar: %d", code)
	}
}

func TestTheCalibrationDashboardStillWorksInItsOwnBuild(t *testing.T) {
	b, _ := calibratingBrain(t)
	h := NewHandler(b, AppOptions{Port: 8020, Token: testToken})
	do := func(method, path string, headers map[string]string) int {
		r := httptest.NewRequest(method, "http://127.0.0.1:8020"+path, nil)
		for k, v := range headers {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	// Opened by the app (a navigation the person started), then the page's own same-origin requests.
	if code := do("GET", "/calibrate", map[string]string{"Sec-Fetch-Site": "none", "Sec-Fetch-Mode": "navigate"}); code != 200 {
		t.Fatalf("the page: %d", code)
	}
	if code := do("GET", "/calibrate/report", map[string]string{"Sec-Fetch-Site": "same-origin"}); code != 200 {
		t.Fatalf("its report: %d", code)
	}
	if code := do("GET", "/calibrate/report", map[string]string{"Sec-Fetch-Site": "cross-site"}); code != 403 {
		t.Fatalf("another site reading it: %d", code)
	}
	// The dashboard's origin opens /calibrate only.
	if code := do("GET", "/v1/today", map[string]string{"Sec-Fetch-Site": "same-origin"}); code != 401 {
		t.Fatalf("the dashboard reaching /v1: %d", code)
	}
}

func TestTheBrainTokenIsMadeOnceAndOwnerOnly(t *testing.T) {
	t.Setenv("MOKU_BRAIN_TOKEN", "")
	home := filepath.Join(t.TempDir(), ".moku")
	first, err := LoadBrainToken(home)
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(first) {
		t.Fatalf("token %q", first)
	}
	info, _ := os.Stat(filepath.Join(home, "brain-token"))
	if info == nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("file mode %v", info)
	}
	if dir, _ := os.Stat(home); dir.Mode().Perm() != 0o700 {
		t.Fatalf("home mode %v", dir.Mode().Perm())
	}
	again, _ := LoadBrainToken(home)
	if again != first {
		t.Fatalf("a second start made a new token")
	}
	// What the app wrote (the same file) is what the brain uses; a damaged file is replaced.
	os.WriteFile(filepath.Join(home, "brain-token"), []byte("short\n"), 0o600)
	fixed, _ := LoadBrainToken(home)
	if fixed == first || len(fixed) != 64 {
		t.Fatalf("damaged file kept: %q", fixed)
	}
	// The app hands its brain the token in the environment; that wins.
	t.Setenv("MOKU_BRAIN_TOKEN", testToken)
	if got, _ := LoadBrainToken(home); got != testToken {
		t.Fatalf("env token ignored: %q", got)
	}
	t.Setenv("MOKU_BRAIN_TOKEN", "too-short")
	if _, err := LoadBrainToken(home); err == nil {
		t.Fatalf("a weak env token was accepted")
	}
}

func TestTheDevelopmentEnvGivesTheBrainOnlyWhatItUses(t *testing.T) {
	t.Setenv("MOKU_HOME", t.TempDir()) // never ~/.moku
	keys := []string{"JEV_VERCEL", "MOKU_MODEL_JUDGE", "POSTHOG_PERSONAL_API_KEY", "AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN"}
	for _, k := range keys {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}
	dev := filepath.Join(t.TempDir(), ".env")
	os.WriteFile(dev, []byte("JEV_VERCEL=dev-gateway-key\nMOKU_MODEL_JUDGE=typesafe-ai/jev-next\nPOSTHOG_PERSONAL_API_KEY=phx_personal\nexport AI_GATEWAY_API_KEY='relay-key'\nVERCEL_OIDC_TOKEN=\"oidc\"\n"), 0o600)
	LoadEnv(dev)
	if os.Getenv("JEV_VERCEL") != "dev-gateway-key" || os.Getenv("MOKU_MODEL_JUDGE") != "typesafe-ai/jev-next" {
		t.Fatalf("the brain's own keys didn't load")
	}
	for _, k := range []string{"POSTHOG_PERSONAL_API_KEY", "AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN"} {
		if _, set := os.LookupEnv(k); set {
			t.Errorf("%s reached the brain's environment (and its children's)", k)
		}
	}
}

// The token handoff every new Mac depends on (launch review 2026-10-09): Moku.app writes credentials.env exactly as
// RelayAccess.save does (other lines kept, then the relay's address and the token), and the brain's next model call
// carries that token to that address. When the app writes a new token (an invite code typed in), the very next call
// carries the new one, with no restart.
func TestTheAppsCredentialsFileReachesTheRelayAndANewTokenWinsAtOnce(t *testing.T) {
	server, seen := fakeGateway(t, 200, `{"answers":{"kind":{"type":"choice","choice":"work","probabilities":{"work":1,"distraction":0}}},"usage":{"inputTokens":1,"outputTokens":1}}`)
	home := t.TempDir()
	t.Setenv("MOKU_HOME", home)
	t.Setenv("MOKU_DEV_ENV", "/nonexistent")
	for _, k := range CredentialKeys {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}
	write := func(token string) {
		t.Helper()
		file := "# kept by Moku.app\nMOKU_GATEWAY_URL=" + server.URL + "/v4/ai\nMOKU_ACCESS_TOKEN=" + token + "\n"
		if err := os.WriteFile(filepath.Join(home, "credentials.env"), []byte(file), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	judge := func() {
		t.Helper()
		if _, err := NewGateway().Evaluate(t.Context(), "typesafe-ai/jev", OMap{{"window", "x"}}, QuestionSet{{"kind", kindQuestion}}); err != nil {
			t.Fatal(err)
		}
	}

	write("moku1.trial-token")
	judge()
	write("moku1.invite-token")
	judge()

	if len(*seen) != 2 {
		t.Fatalf("%d calls reached the relay, want 2", len(*seen))
	}
	for i, want := range []string{"Bearer moku1.trial-token", "Bearer moku1.invite-token"} {
		if got := (*seen)[i].headers.Get("authorization"); got != want {
			t.Errorf("call %d carried %q, want %q", i+1, got, want)
		}
		if (*seen)[i].path != "/v4/ai/evaluation-model" {
			t.Errorf("call %d went to %s", i+1, (*seen)[i].path)
		}
	}
}
