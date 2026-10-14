package brain

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// The gateway's wire protocol, pinned to what the AI SDK (ai 7.0.111, @ai-sdk/gateway) sent, captured byte for byte
// into testdata/ (the requests the TypeScript brain made). Any change to a request body fails here.

type recorded struct {
	path    string
	headers http.Header
	body    string
}

func fakeGateway(t *testing.T, status int, answer string) (*httptest.Server, *[]recorded) {
	var seen []recorded
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seen = append(seen, recorded{r.URL.Path, r.Header.Clone(), string(body)})
		w.WriteHeader(status)
		io.WriteString(w, answer)
	}))
	t.Cleanup(server.Close)
	return server, &seen
}

func proxyTo(t *testing.T, server *httptest.Server) *Gateway {
	t.Setenv("MOKU_HOME", t.TempDir())
	t.Setenv("MOKU_DEV_ENV", "/nonexistent")
	t.Setenv("MOKU_GATEWAY_URL", server.URL+"/v4/ai")
	t.Setenv("MOKU_ACCESS_TOKEN", "moku1.test")
	g := NewGateway()
	g.Sleep = func(context.Context, time.Duration) error { return nil }
	return g
}

func fixture(t *testing.T, name string) string {
	data, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(data))
}

func TestJevRequestIsTheSDKsByteForByte(t *testing.T) {
	server, seen := fakeGateway(t, 200, `{"answers":{"kind":{"type":"choice","choice":"work","probabilities":{"work":1,"distraction":0}}},"usage":{"inputTokens":10,"outputTokens":2},"providerMetadata":{"gateway":{"cost":"0.00001"}}}`)
	g := proxyTo(t, server)
	state := OMap{{"user_app", "Code"}, {"window", "x"}, {"screen_contents", ""}}
	result, err := g.Evaluate(context.Background(), "typesafe-ai/jev", state, QuestionSet{{"kind", kindQuestion}})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := (*seen)[0].body, fixture(t, "evaluate-kind.json"); got != want {
		t.Fatalf("body differs from the SDK's:\n got %s\nwant %s", got, want)
	}
	h := (*seen)[0].headers
	for k, v := range map[string]string{"authorization": "Bearer moku1.test", "ai-gateway-protocol-version": "0.0.1", "ai-gateway-auth-method": "api-key",
		"ai-evaluation-model-specification-version": "4", "ai-model-id": "typesafe-ai/jev", "content-type": "application/json"} {
		if h.Get(k) != v {
			t.Errorf("header %s = %q, want %q", k, h.Get(k), v)
		}
	}
	if (*seen)[0].path != "/v4/ai/evaluation-model" {
		t.Errorf("path %s", (*seen)[0].path)
	}
	kind, _ := result.Answers.Get("kind")
	if kind.Choice != "work" || result.TokensIn != 10 || result.CostUsd == nil || *result.CostUsd != 0.00001 {
		t.Errorf("result %+v", result)
	}

	// A yes/no question has no criteria.
	server2, seen2 := fakeGateway(t, 200, `{"answers":{"done":{"type":"boolean","probability":0.9}}}`)
	g2 := proxyTo(t, server2)
	if _, err := g2.Evaluate(context.Background(), "typesafe-ai/jev", OMap{{"a", 1}}, QuestionSet{{"done", completionQuestion(CompletionPatterns[0])}}); err != nil {
		t.Fatal(err)
	}
	if got, want := (*seen2)[0].body, fixture(t, "evaluate-completion.json"); got != want {
		t.Fatalf("body differs from the SDK's:\n got %s\nwant %s", got, want)
	}
}

func TestLunaRequestsAreTheSDKsByteForByte(t *testing.T) {
	answer := `{"content":[{"type":"text","text":"{\"line\":\"hi\",\"title\":\"t\",\"summary\":\"s\",\"activity\":\"a\",\"note\":\"n\"}"}],"finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":5},"outputTokens":{"total":3}},"providerMetadata":{"gateway":{"cost":"0.0002"}}}`
	for _, c := range []struct {
		schema  StringSchema
		fixture string
	}{{lineSchema, "generate-line.json"}, {threadName, "generate-name.json"}, {noteSchema, "generate-note.json"}, {activityAnswer, "generate-activity.json"}} {
		server, seen := fakeGateway(t, 200, answer)
		g := proxyTo(t, server)
		result, err := g.GenerateObject(context.Background(), "openai/gpt-6-luna", "SYS", "PROMPT", c.schema, 600)
		if err != nil {
			t.Fatal(c.fixture, err)
		}
		if got, want := (*seen)[0].body, fixture(t, c.fixture); got != want {
			t.Fatalf("%s: body differs from the SDK's:\n got %s\nwant %s", c.fixture, got, want)
		}
		h := (*seen)[0].headers
		if h.Get("ai-language-model-id") != "openai/gpt-6-luna" || h.Get("ai-language-model-streaming") != "false" || h.Get("ai-language-model-specification-version") != "4" {
			t.Errorf("%s: headers %v", c.fixture, h)
		}
		if result.TokensIn != 5 || result.TokensOut != 3 {
			t.Errorf("%s: usage %+v", c.fixture, result.Usage)
		}
	}
}

func TestFailuresAreNamedAsTheSDKNamesThem(t *testing.T) {
	cases := []struct {
		status          int
		answer          string
		luna            bool
		code            string
		calls, httpCode int
	}{
		{503, `{"error":{"message":"overloaded"}}`, false, "provider", 1, 503},
		{401, `{"error":{"message":"bad key"}}`, false, "provider", 1, 401},
		{200, `{"answers":{"kind":{"type":"choice","choice":"work","probabilities":{"work":0.4,"distraction":0.4}}}}`, false, "provider", 1, 0},
		{200, `{"answers":{"kind":{"type":"choice","choice":"work","probabilities":{"work":0.3,"distraction":0.7}}}}`, false, "provider", 1, 0},
		{200, `not json`, false, "schema", 1, 0},
		{503, `{"error":{"message":"overloaded"}}`, true, "provider", 2, 0}, // Luna tries once more
		{400, `{"error":{"message":"bad request"}}`, true, "provider", 1, 400},
		{200, `{"content":[{"type":"text","text":"not json"}]}`, true, "schema", 1, 0},
		{200, `{"content":[{"type":"text","text":"{\"line\":\"\"}"}]}`, true, "schema", 1, 0},
		// The relay's own error shape for a gateway error (proxy.js gatewayError): the status decides, as ever.
		{429, `{"error":"the model gateway answered 429","code":"gateway_rate_limited"}`, false, "provider", 1, 429},
		{402, `{"error":"the model gateway answered 402","code":"gateway_no_credit"}`, false, "provider", 1, 402},
		{503, `{"error":"the model gateway answered 503","code":"gateway_down"}`, true, "provider", 2, 0},
	}
	for i, c := range cases {
		server, seen := fakeGateway(t, c.status, c.answer)
		g := proxyTo(t, server)
		var err error
		if c.luna {
			_, err = g.GenerateObject(context.Background(), "openai/gpt-6-luna", "s", "p", lineSchema, 600)
		} else {
			_, err = g.Evaluate(context.Background(), "typesafe-ai/jev", OMap{{"a", 1}}, QuestionSet{{"kind", kindQuestion}})
		}
		if err == nil || errorCode(err) != c.code || len(*seen) != c.calls {
			t.Errorf("case %d: err %v (code %s), %d calls; want %s, %d calls", i, err, errorCode(err), len(*seen), c.code, c.calls)
		}
		if ce, ok := err.(*CallError); ok && !c.luna && ce.StatusCode != c.httpCode {
			t.Errorf("case %d: status %d, want %d", i, ce.StatusCode, c.httpCode)
		}
	}
	if got := errorMessage([]byte(`{"error":"the model gateway answered 429","code":"gateway_rate_limited"}`)); got != "the model gateway answered 429" {
		t.Errorf("the relay's error message reads as %q", got)
	}
	t.Setenv("MOKU_HOME", t.TempDir())
	t.Setenv("MOKU_DEV_ENV", "/nonexistent")
	t.Setenv("MOKU_GATEWAY_URL", "")
	t.Setenv("MOKU_ACCESS_TOKEN", "")
	t.Setenv("JEV_VERCEL", "")
	if _, err := NewGateway().Evaluate(context.Background(), "typesafe-ai/jev", OMap{}, QuestionSet{{"kind", kindQuestion}}); errorCode(err) != "credentials" {
		t.Errorf("no credentials: %v", err)
	}
}

func TestJSONIsWrittenAsJavaScriptWritesIt(t *testing.T) {
	tenth, fifth := 0.1, 0.2 // variables: Go folds constant arithmetic exactly
	for _, c := range []struct {
		value any
		want  string
	}{
		{OMap{{"b", 1}, {"a", "<tag> & \u2028 line\u2029 \b\f\n"}}, "{\"b\":1,\"a\":\"<tag> & \u2028 line\u2029 \\b\\f\\n\"}"},
		{[]any{tenth + fifth, 1e21, 1e-7, 123456789012.0, nil}, "[0.30000000000000004,1e+21,1e-7,123456789012,null]"},
		{OMap{{"s", `a\u2028b`}}, `{"s":"a\\u2028b"}`},
	} {
		if got := JSON(c.value); got != c.want {
			t.Errorf("JSON(%v) = %s, want %s", c.value, got, c.want)
		}
	}
	for _, c := range []struct {
		x    float64
		d    int
		want string
	}{{0.125, 2, "0.13"}, {0.145, 2, "0.14"}, {1.005, 2, "1.00"}, {2.5, 0, "3"}, {0.5, 0, "1"}, {0.85, 2, "0.85"}, {1, 2, "1.00"}} {
		if got := ToFixed(c.x, c.d); got != c.want {
			t.Errorf("ToFixed(%v, %d) = %s, want %s", c.x, c.d, got, c.want)
		}
	}
	if JSONIndent(OMap{{"user_app", "Code"}, {"your_work", []string{"a"}}}, 1) != "{\n \"user_app\": \"Code\",\n \"your_work\": [\n  \"a\"\n ]\n}" {
		t.Errorf("indent: %q", JSONIndent(OMap{{"user_app", "Code"}, {"your_work", []string{"a"}}}, 1))
	}
	if Clip("hello world", 6) != "hello…" || Len16("a😀") != 3 || Slice16("a😀b", 2) != "a" {
		t.Errorf("clip/len16/slice16")
	}
	if sentenceCount("One. Two! Three?") != 3 || sentenceCount("A day. You came back 6 times.") != 2 || sentenceCount("No end") != 1 {
		t.Errorf("sentenceCount")
	}
}
