package brain

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// The only code that talks to a model provider: the Vercel AI Gateway, over the same wire protocol the AI SDK
// (ai 7.0.111, @ai-sdk/gateway) speaks, byte for byte in the request bodies. Credentials (LoadEnv; never printed)
// pick one of two routes, read again on every call so a key added later works without a restart:
//
//	key    JEV_VERCEL: the gateway itself (development).
//	proxy  MOKU_GATEWAY_URL + MOKU_ACCESS_TOKEN: the Moku relay with the device's own token. Wins when both are set.
//
// Jev (evaluation-model) answers bounded questions about one state; Luna (language-model) writes JSON to a schema.
// Every call asks for zero data retention.

const gatewayBase = "https://ai-gateway.vercel.sh/v4/ai"
const sdkUserAgent = "ai/7.0.111 ai-sdk/provider-utils/5.0.45 runtime/moku-brain-go"

// CallError is how a model call failed. Name follows the AI SDK's error names, which decide the error code.
type CallError struct {
	Name       string
	StatusCode int // 0 when there was no HTTP answer
	Message    string
	// RetryAfterMs: the answer's Retry-After (or retry-after-ms), 0 when it gave none.
	RetryAfterMs int64
	// Code: the relay's code word ("daily_limit", "trial_ended", "cloud_off"…), "" when it gave none.
	Code string
}

func (e *CallError) Error() string { return e.Name + ": " + e.Message }

// StringSchema: a Luna answer, an object of required strings (OpenAI refuses optional fields).
type StringSchema []StringField

type StringField struct {
	Name     string
	Min, Max int // 0 for none
}

// JSONSchema: the schema as the AI SDK sends it (draft-07), or as zod writes it for the local model (2020-12).
func (s StringSchema) JSONSchema(draft string) OMap {
	props := OMap{}
	required := make([]string, 0, len(s))
	for _, f := range s {
		p := OMap{{"type", "string"}}
		if f.Min > 0 {
			p = append(p, KV{"minLength", f.Min})
		}
		if f.Max > 0 {
			p = append(p, KV{"maxLength", f.Max})
		}
		props = append(props, KV{f.Name, p})
		required = append(required, f.Name)
	}
	return OMap{{"$schema", draft}, {"type", "object"}, {"properties", props}, {"required", required}, {"additionalProperties", false}}
}

// Parse checks an answer against the schema (as zod does: every field a string within its lengths; other keys
// dropped) and returns it in the schema's key order.
func (s StringSchema) Parse(v any) (OMap, bool) {
	m, ok := v.(map[string]any)
	if !ok {
		return nil, false
	}
	var out OMap
	for _, f := range s {
		text, isString := m[f.Name].(string)
		if !isString || Len16(text) < f.Min || (f.Max > 0 && Len16(text) > f.Max) {
			return nil, false
		}
		out = append(out, KV{f.Name, text})
	}
	return out, true
}

type Usage struct {
	TokensIn, TokensOut int64
	CostUsd             *float64
}

type EvaluateResult struct {
	Answers    Answers
	Confidence OMap
	Usage
}

type GenerateResult struct {
	Output any
	Usage
}

// Transport is the network boundary; tests use a fake.
type Transport interface {
	Evaluate(ctx context.Context, modelID string, state any, questions QuestionSet) (EvaluateResult, error)
	GenerateObject(ctx context.Context, modelID, system, prompt string, schema StringSchema, maxOutputTokens int) (GenerateResult, error)
}

type Gateway struct {
	Client *http.Client
	// APIKey, when set, is used instead of the environment (tests).
	APIKey string
	// Sleep waits between Luna's two attempts (tests shorten it).
	Sleep func(ctx context.Context, d time.Duration) error
}

func NewGateway() *Gateway {
	return &Gateway{Client: &http.Client{}, Sleep: sleepCtx}
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func (g *Gateway) route() (base, token string, err error) {
	if g.APIKey != "" {
		return gatewayBase, g.APIKey, nil
	}
	LoadEnv(DevEnvPath())
	switch ModelAccess() {
	case "proxy":
		return strings.TrimRight(os.Getenv("MOKU_GATEWAY_URL"), "/"), os.Getenv("MOKU_ACCESS_TOKEN"), nil
	case "key":
		return gatewayBase, os.Getenv("JEV_VERCEL"), nil
	}
	return "", "", &CallError{Name: "NoCredentialsError", Message: "no model credentials (MOKU_HOME/credentials.env, the environment or bunny/.env)"}
}

var gatewayPrivacy = OMap{{"gateway", OMap{{"zeroDataRetention", true}}}}

func (g *Gateway) post(ctx context.Context, url, token string, headers map[string]string, body OMap) ([]byte, http.Header, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewBufferString(JSON(body)))
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("authorization", "Bearer "+token)
	req.Header.Set("ai-gateway-protocol-version", "0.0.1")
	req.Header.Set("ai-gateway-auth-method", "api-key")
	req.Header.Set("content-type", "application/json")
	req.Header.Set("user-agent", sdkUserAgent)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	res, err := g.Client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, nil, ctx.Err()
		}
		return nil, nil, &CallError{Name: "AI_APICallError", Message: err.Error()}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(res.Body)
	if err != nil {
		if ctx.Err() != nil {
			return nil, nil, ctx.Err()
		}
		return nil, nil, &CallError{Name: "AI_APICallError", Message: err.Error()}
	}
	if res.StatusCode < 200 || res.StatusCode > 299 {
		return nil, res.Header, &CallError{Name: gatewayErrorName(res.StatusCode), StatusCode: res.StatusCode, Message: errorMessage(data),
			RetryAfterMs: headerRetryAfterMs(res.Header), Code: errorCodeWord(data)}
	}
	return data, res.Header, nil
}

func gatewayErrorName(status int) string {
	switch {
	case status == 401 || status == 403:
		return "GatewayAuthenticationError"
	case status == 429:
		return "GatewayRateLimitError"
	case status == 400:
		return "GatewayInvalidRequestError"
	case status >= 500:
		return "GatewayInternalServerError"
	}
	return "GatewayResponseError"
}

func errorMessage(data []byte) string {
	var body struct {
		Error any `json:"error"`
	}
	if json.Unmarshal(data, &body) == nil {
		switch e := body.Error.(type) {
		case string:
			return e
		case map[string]any:
			if m, ok := e["message"].(string); ok {
				return m
			}
		}
	}
	return "unknown error"
}

// Evaluate asks Jev. The answers are checked as the AI SDK checks them: exactly the asked questions, each of the
// asked type, an allowed choice with a complete distribution in which it is the most likely, P(true) in [0, 1].
func (g *Gateway) Evaluate(ctx context.Context, modelID string, state any, questions QuestionSet) (EvaluateResult, error) {
	base, token, err := g.route()
	if err != nil {
		return EvaluateResult{}, err
	}
	body := OMap{{"state", state}, {"questions", questions}, {"providerOptions", gatewayPrivacy}}
	data, _, err := g.post(ctx, base+"/evaluation-model", token, map[string]string{
		"ai-evaluation-model-specification-version": "4", "ai-model-id": modelID,
	}, body)
	if err != nil {
		return EvaluateResult{}, err
	}
	var res struct {
		Answers  json.RawMessage `json:"answers"`
		Rounding *struct {
			ProbabilityDecimals *float64 `json:"probabilityDecimals"`
		} `json:"rounding"`
		Usage *struct {
			InputTokens  *float64 `json:"inputTokens"`
			OutputTokens *float64 `json:"outputTokens"`
		} `json:"usage"`
		ProviderMetadata *struct {
			Typesafe *struct {
				Confidence json.RawMessage `json:"confidence"`
			} `json:"typesafe"`
			Gateway *struct {
				Cost any `json:"cost"`
			} `json:"gateway"`
		} `json:"providerMetadata"`
	}
	if err := json.Unmarshal(data, &res); err != nil {
		return EvaluateResult{}, &CallError{Name: "AI_JSONParseError", Message: err.Error()}
	}
	var decimals *float64
	if res.Rounding != nil {
		decimals = res.Rounding.ProbabilityDecimals
	}
	answers, err := checkAnswers(res.Answers, questions, decimals)
	if err != nil {
		return EvaluateResult{}, err
	}
	out := EvaluateResult{Answers: answers}
	if res.Usage != nil {
		out.TokensIn, out.TokensOut = tokens(res.Usage.InputTokens), tokens(res.Usage.OutputTokens)
	}
	if res.ProviderMetadata != nil {
		if res.ProviderMetadata.Typesafe != nil && len(res.ProviderMetadata.Typesafe.Confidence) > 0 {
			var m map[string]any
			if json.Unmarshal(res.ProviderMetadata.Typesafe.Confidence, &m) == nil {
				for _, k := range ordered(res.ProviderMetadata.Typesafe.Confidence, m) {
					out.Confidence = append(out.Confidence, KV{k, m[k]})
				}
			}
		}
		if res.ProviderMetadata.Gateway != nil {
			out.CostUsd = gatewayCost(res.ProviderMetadata.Gateway.Cost)
		}
	}
	return out, nil
}

func tokens(p *float64) int64 {
	if p == nil {
		return 0
	}
	return int64(*p)
}

func gatewayCost(cost any) *float64 {
	var n float64
	switch c := cost.(type) {
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(leadingNumber(c)), 64)
		if err != nil {
			return nil
		}
		n = f
	case float64:
		n = c
	default:
		return nil
	}
	if math.IsNaN(n) || math.IsInf(n, 0) || n <= 0 {
		return nil
	}
	return &n
}

// leadingNumber: the numeric prefix Number.parseFloat reads.
func leadingNumber(s string) string {
	s = strings.TrimLeft(s, " \t\n\r")
	end := 0
	for end < len(s) && strings.ContainsRune("+-0123456789.eE", rune(s[end])) {
		end++
	}
	return s[:end]
}

const answerTolerance = 1e-6

func invalidAnswer(msg string) error { return &CallError{Name: "AI_InvalidResponseDataError", Message: msg} }

func checkAnswers(raw json.RawMessage, questions QuestionSet, decimals *float64) (Answers, error) {
	roundingError := 0.0
	if decimals != nil {
		d := *decimals
		if d != math.Trunc(d) || d < 0 || d > 15 {
			return Answers{}, invalidAnswer("Evaluation rounding decimals must be integers between 0 and 15.")
		}
		roundingError = 0.5 * math.Pow(10, -d)
	}
	var byID map[string]EvaluationAnswer
	if len(raw) == 0 || json.Unmarshal(raw, &byID) != nil || byID == nil || len(byID) != len(questions) {
		return Answers{}, invalidAnswer("Evaluation must return exactly one answer for every question.")
	}
	var generic map[string]any
	json.Unmarshal(raw, &generic)
	for _, kv := range questions {
		q := kv.Value.(EvaluationQuestion)
		a, ok := byID[kv.Key]
		if !ok {
			return Answers{}, invalidAnswer("Evaluation must return exactly one answer for every question.")
		}
		if a.Type != q.Type {
			return Answers{}, invalidAnswer(fmt.Sprintf("Question %q returned an answer with the wrong type.", kv.Key))
		}
		switch q.Type {
		case "choice":
			if _, known := q.Criteria.Get(a.Choice); !known {
				return Answers{}, invalidAnswer(fmt.Sprintf("Question %q selected an unknown option.", kv.Key))
			}
			if hasKey(generic[kv.Key], "probabilities") {
				keys := q.Criteria.Keys()
				if len(a.Probabilities) != len(keys) {
					return Answers{}, invalidAnswer(fmt.Sprintf("Question %q must have a complete distribution of finite probabilities in [0, 1].", kv.Key))
				}
				sum := 0.0
				for _, k := range keys {
					p, found := a.Probabilities[k]
					if !found || !isProbability(p) {
						return Answers{}, invalidAnswer(fmt.Sprintf("Question %q must have a complete distribution of finite probabilities in [0, 1].", kv.Key))
					}
					sum += p
				}
				if math.Abs(sum-1) > answerTolerance+float64(len(keys))*roundingError {
					return Answers{}, invalidAnswer(fmt.Sprintf("Question %q probabilities must sum to 1 within the declared rounding precision.", kv.Key))
				}
				selected := a.Probabilities[a.Choice]
				for _, p := range a.Probabilities {
					if p > selected+answerTolerance {
						return Answers{}, invalidAnswer(fmt.Sprintf("Question %q did not select a highest-probability option.", kv.Key))
					}
				}
			} else {
				a.Probabilities = nil
			}
		case "boolean":
			if a.Probability == nil || !isProbability(*a.Probability) {
				return Answers{}, invalidAnswer(fmt.Sprintf("Question %q must return P(true) as a finite probability in [0, 1].", kv.Key))
			}
		}
		byID[kv.Key] = a
	}
	var m map[string]any
	json.Unmarshal(raw, &m)
	return Answers{byID: byID, order: ordered(raw, m)}, nil
}

func hasKey(v any, key string) bool {
	m, ok := v.(map[string]any)
	if !ok {
		return false
	}
	_, found := m[key]
	return found
}

func isProbability(p float64) bool { return !math.IsNaN(p) && !math.IsInf(p, 0) && p >= 0 && p <= 1 }

// GenerateObject asks Luna for JSON matching `schema`, with one retry after about 2 s on a retryable failure
// (408, 409, 429, 5xx or no answer), as the SDK's maxRetries: 1 does. The caller's deadline caps both attempts.
func (g *Gateway) GenerateObject(ctx context.Context, modelID, system, prompt string, schema StringSchema, maxOutputTokens int) (GenerateResult, error) {
	base, token, err := g.route()
	if err != nil {
		return GenerateResult{}, err
	}
	options := gatewayPrivacy
	if strings.HasPrefix(modelID, "openai/") {
		options = append(append(OMap{}, gatewayPrivacy...), KV{"openai", OMap{{"reasoningEffort", "low"}}})
	}
	body := OMap{
		{"maxOutputTokens", maxOutputTokens},
		{"toolChoice", OMap{{"type", "auto"}}},
		{"responseFormat", OMap{{"type", "json"}, {"schema", schema.JSONSchema("http://json-schema.org/draft-07/schema#")}}},
		{"prompt", []any{
			OMap{{"role", "system"}, {"content", system}},
			OMap{{"role", "user"}, {"content", []any{OMap{{"type", "text"}, {"text", prompt}}}}},
		}},
		{"providerOptions", options},
		{"headers", OMap{{"user-agent", "ai/7.0.111"}}},
	}
	headers := map[string]string{
		"ai-language-model-specification-version": "4", "ai-language-model-id": modelID, "ai-language-model-streaming": "false",
	}
	var data []byte
	for attempt := 0; ; attempt++ {
		var respHeaders http.Header
		data, respHeaders, err = g.post(ctx, base+"/language-model", token, headers, body)
		if err == nil {
			break
		}
		var ce *CallError
		retryable := errors.As(err, &ce) && (ce.StatusCode == 0 || ce.StatusCode == 408 || ce.StatusCode == 409 || ce.StatusCode == 429 || ce.StatusCode >= 500)
		if !retryable || attempt >= 1 {
			if retryable {
				return GenerateResult{}, &CallError{Name: "AI_RetryError", Message: err.Error()}
			}
			return GenerateResult{}, err
		}
		if err := g.Sleep(ctx, retryDelay(respHeaders)); err != nil {
			return GenerateResult{}, err
		}
	}
	var res struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
		Usage *struct {
			InputTokens  json.RawMessage `json:"inputTokens"`
			OutputTokens json.RawMessage `json:"outputTokens"`
		} `json:"usage"`
		ProviderMetadata *struct {
			Gateway *struct {
				Cost any `json:"cost"`
			} `json:"gateway"`
		} `json:"providerMetadata"`
	}
	if err := json.Unmarshal(data, &res); err != nil {
		return GenerateResult{}, &CallError{Name: "AI_JSONParseError", Message: err.Error()}
	}
	var text strings.Builder
	for _, part := range res.Content {
		if part.Type == "text" {
			text.WriteString(part.Text)
		}
	}
	out := GenerateResult{}
	if res.Usage != nil {
		out.TokensIn, out.TokensOut = usageTotal(res.Usage.InputTokens), usageTotal(res.Usage.OutputTokens)
	}
	if res.ProviderMetadata != nil && res.ProviderMetadata.Gateway != nil {
		out.CostUsd = gatewayCost(res.ProviderMetadata.Gateway.Cost)
	}
	var parsed any
	if err := json.Unmarshal([]byte(text.String()), &parsed); err != nil {
		return out, &CallError{Name: "AI_NoObjectGeneratedError", Message: "No object generated: could not parse the response."}
	}
	if _, ok := schema.Parse(parsed); !ok {
		return out, &CallError{Name: "AI_NoObjectGeneratedError", Message: "No object generated: response did not match schema."}
	}
	out.Output = parsed
	return out, nil
}

// usageTotal reads a token count given as a number or as {total: n}.
func usageTotal(raw json.RawMessage) int64 {
	var n float64
	if json.Unmarshal(raw, &n) == nil {
		return int64(n)
	}
	var nested struct {
		Total *float64 `json:"total"`
	}
	if json.Unmarshal(raw, &nested) == nil && nested.Total != nil {
		return int64(*nested.Total)
	}
	return 0
}

// headerRetryAfterMs: retry-after-ms, else retry-after in seconds, as asked; 0 when neither is a number.
func headerRetryAfterMs(h http.Header) int64 {
	if ms, err := strconv.ParseFloat(h.Get("retry-after-ms"), 64); err == nil && ms >= 0 {
		return int64(ms)
	}
	if s, err := strconv.ParseFloat(h.Get("retry-after"), 64); err == nil && s >= 0 {
		return int64(s * 1000)
	}
	return 0
}

// errorCodeWord: the relay's `code` in an error body ("daily_limit"), or "".
func errorCodeWord(data []byte) string {
	var body struct {
		Code string `json:"code"`
	}
	if json.Unmarshal(data, &body) == nil && len(body.Code) <= 40 {
		return body.Code
	}
	return ""
}

// retryDelay: retry-after-ms or retry-after when it says less than a minute, else 2 s.
func retryDelay(h http.Header) time.Duration {
	if h != nil {
		if ms, err := strconv.ParseFloat(h.Get("retry-after-ms"), 64); err == nil && ms >= 0 && ms < 60_000 {
			return time.Duration(ms * float64(time.Millisecond))
		}
		if s, err := strconv.ParseFloat(h.Get("retry-after"), 64); err == nil && s >= 0 && s < 60 {
			return time.Duration(s * float64(time.Second))
		}
	}
	return 2 * time.Second
}
