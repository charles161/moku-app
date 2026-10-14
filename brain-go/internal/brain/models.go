package brain

import (
	"context"
	"errors"
	"math/rand"
	"regexp"
	"time"
)

// Model calls with their budgets:
//
//	Jev: 5 s per attempt, one retry (two with jittered backoff on 503/429), at most 8 in flight, and a 7 s total
//	     deadline so a verdict lands inside the app's 8 s request timeout. Never throws, never guesses: a failure is
//	     {OK: false}.
//	Luna: one call with a hard timeout (voice 6 s, naming 15 s); output failing the schema is rejected, not coerced.
//
// Each model has a breaker. When the cloud fails (or is skipped) the local model answers instead: the focus question
// for callers that ask for it, and every write. Callers log each call's content (model_calls); this only measures.

type CallMeta struct {
	Model     string
	LatencyMs int64
	Attempts  int
	Usage
}

type JudgeOutcome struct {
	OK         bool
	Answers    Answers
	Confidence OMap
	ErrorCode  string
	HTTPStatus int
	// RetryAfterMs and RelayCode: the relay's Retry-After and code word on a refusal (docs/specs/governor.md).
	RetryAfterMs int64
	RelayCode    string
	CallMeta
}

type WriteOutcome struct {
	OK        bool
	Output    OMap
	ErrorCode string
	CallMeta
}

type WriteRequest struct {
	System, Prompt  string
	Schema          StringSchema
	TimeoutMs       int64
	MaxOutputTokens int
}

type Models interface {
	// Judge asks Jev; local lets the local model answer the focus question when Jev fails.
	Judge(state any, questions QuestionSet, local bool) JudgeOutcome
	Write(req WriteRequest) WriteOutcome
	Health() *CloudHealth
}

type CloudHealth struct {
	Judge ModelHealth `json:"judge"`
	Write ModelHealth `json:"write"`
	Local LocalHealth `json:"local"`
}

type ModelOptions struct {
	Transport       Transport
	JudgeTimeoutMs  int64
	JudgeDeadlineMs int64
	JudgeBackoffMs  int64
	JudgeModel      string
	WriterModel     string
	Now             func() int64
	Local           LocalModel
}

type cloudModels struct {
	opts         ModelOptions
	judgeBreaker *Breaker
	writeBreaker *Breaker
	judgeSlots   chan struct{}
}

// minAttemptMs: Jev answers in about 0.5 s; a retry with less time than this would only add a timeout.
const minAttemptMs = 1000

func NewModels(o ModelOptions) Models {
	if o.JudgeTimeoutMs == 0 {
		o.JudgeTimeoutMs = int64(Rules.JevFailed.AttemptTimeoutMs)
	}
	if o.JudgeDeadlineMs == 0 {
		o.JudgeDeadlineMs = int64(Rules.JevFailed.DeadlineMs)
	}
	if o.JudgeBackoffMs == 0 {
		o.JudgeBackoffMs = 400
	}
	judge, writer := ModelIDs()
	if o.JudgeModel == "" {
		o.JudgeModel = judge
	}
	if o.WriterModel == "" {
		o.WriterModel = writer
	}
	if o.Now == nil {
		o.Now = func() int64 { return time.Now().UnixMilli() }
	}
	return &cloudModels{opts: o, judgeBreaker: NewBreaker(o.Now), writeBreaker: NewBreaker(o.Now), judgeSlots: make(chan struct{}, Rules.JevFailed.MaxInFlight)}
}

func nowMs() int64 { return time.Now().UnixMilli() }

func (m *cloudModels) skipped(model string) CallMeta { return CallMeta{Model: model} }

func (m *cloudModels) Judge(state any, questions QuestionSet, local bool) JudgeOutcome {
	started := nowMs()
	var outcome JudgeOutcome
	m.judgeBreaker.NewToken(AccessToken()) // an invite typed in ends a rest at once
	if m.judgeBreaker.Allow() {
		outcome = m.judgeCloud(state, questions)
	} else {
		outcome = JudgeOutcome{ErrorCode: "unavailable", CallMeta: m.skipped(m.opts.JudgeModel)}
	}
	if outcome.OK || m.opts.Local == nil {
		return outcome
	}
	m.opts.Local.Warm() // the cloud is failing: have the local model ready for what comes next
	if !local || len(questions) != 1 {
		return outcome
	}
	id, question := questions[0].Key, questions[0].Value.(EvaluationQuestion)
	left := max(minAttemptMs, m.opts.JudgeDeadlineMs-(nowMs()-started))
	answer, ok := m.opts.Local.JudgeKind(state, question, left)
	if !ok {
		return outcome
	}
	choice := "distraction"
	if answer.PWork >= 0.5 {
		choice = "work"
	}
	a := EvaluationAnswer{Type: "choice", Choice: choice, Probabilities: map[string]float64{"work": answer.PWork, "distraction": 1 - answer.PWork}, order: []string{"work", "distraction"}}
	return JudgeOutcome{OK: true, Answers: Answers{byID: map[string]EvaluationAnswer{id: a}, order: []string{id}},
		CallMeta: CallMeta{Model: LocalModelInfo.ID, LatencyMs: nowMs() - started, Attempts: outcome.Attempts + 1}}
}

func (m *cloudModels) judgeCloud(state any, questions QuestionSet) JudgeOutcome {
	started := nowMs()
	left := func() int64 { return m.opts.JudgeDeadlineMs - (nowMs() - started) }
	attempts := 0
	var outcome JudgeOutcome
	for {
		attempts++
		m.judgeSlots <- struct{}{}
		outcome = m.judgeOnce(state, questions, max(1, min(m.opts.JudgeTimeoutMs, left())))
		<-m.judgeSlots
		if outcome.OK || outcome.ErrorCode == "schema" || outcome.ErrorCode == "credentials" {
			break
		}
		if outcome.HTTPStatus == 401 || outcome.HTTPStatus == 402 || outcome.HTTPStatus == 403 {
			break // a refused key won't be accepted on a retry
		}
		if outcome.RetryAfterMs >= LongRestMs {
			break // the relay's "not now" (a daily share used): a retry would be refused too
		}
		overloaded := outcome.HTTPStatus == 503 || outcome.HTTPStatus == 429
		limit := Rules.JevFailed.Retries
		if overloaded {
			limit = Rules.JevFailed.OverloadedRetries
		}
		if attempts > limit {
			break
		}
		if overloaded {
			wait := min(float64(m.opts.JudgeBackoffMs)*float64(int64(1)<<(attempts-1))*(1+rand.Float64()/2), float64(max(0, left())))
			time.Sleep(time.Duration(wait * float64(time.Millisecond)))
		}
		if left() < minAttemptMs {
			break
		}
	}
	if refused := outcome.HTTPStatus == 429 || outcome.HTTPStatus == 402; !outcome.OK && refused && outcome.RetryAfterMs >= LongRestMs {
		code := outcome.RelayCode
		if code == "" {
			code = outcome.ErrorCode
		}
		m.judgeBreaker.Rest(code, outcome.HTTPStatus, outcome.RetryAfterMs, AccessToken())
	} else {
		m.judgeBreaker.Record(outcome.OK, outcome.ErrorCode, outcome.HTTPStatus)
	}
	outcome.Attempts = attempts
	outcome.LatencyMs = nowMs() - started
	return outcome
}

func (m *cloudModels) judgeOnce(state any, questions QuestionSet, timeoutMs int64) JudgeOutcome {
	started := nowMs()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	meta := func(u Usage) CallMeta {
		return CallMeta{Model: m.opts.JudgeModel, LatencyMs: nowMs() - started, Attempts: 1, Usage: u}
	}
	result, err := m.opts.Transport.Evaluate(ctx, m.opts.JudgeModel, state, questions)
	if err != nil {
		code := errorCode(err)
		if ctx.Err() == context.DeadlineExceeded {
			code = "timeout"
		}
		out := JudgeOutcome{ErrorCode: code, CallMeta: meta(Usage{})}
		var ce *CallError
		if errors.As(err, &ce) {
			out.HTTPStatus, out.RetryAfterMs, out.RelayCode = ce.StatusCode, ce.RetryAfterMs, ce.Code
		}
		return out
	}
	if !validAnswers(result.Answers, questions) {
		return JudgeOutcome{ErrorCode: "schema", CallMeta: meta(result.Usage)}
	}
	return JudgeOutcome{OK: true, Answers: result.Answers, Confidence: result.Confidence, CallMeta: meta(result.Usage)}
}

func (m *cloudModels) Write(req WriteRequest) WriteOutcome {
	started := nowMs()
	outcome := WriteOutcome{ErrorCode: "unavailable", CallMeta: m.skipped(m.opts.WriterModel)}
	if m.writeBreaker.Allow() {
		outcome = m.writeOnce(req)
		m.writeBreaker.Record(outcome.OK, outcome.ErrorCode, 0)
	}
	if outcome.OK || outcome.ErrorCode == "schema" || m.opts.Local == nil {
		return outcome
	}
	m.opts.Local.Warm()
	left := req.TimeoutMs - (nowMs() - started)
	if left < minAttemptMs {
		return outcome
	}
	local := m.opts.Local.Write(req.System, req.Prompt, req.Schema, left, req.MaxOutputTokens)
	if !local.OK {
		return outcome
	}
	parsed, ok := req.Schema.Parse(local.Output)
	if !ok {
		return outcome
	}
	return WriteOutcome{OK: true, Output: parsed, CallMeta: CallMeta{Model: LocalModelInfo.ID, LatencyMs: nowMs() - started, Attempts: outcome.Attempts + 1,
		Usage: Usage{TokensIn: local.TokensIn, TokensOut: local.TokensOut}}}
}

func (m *cloudModels) writeOnce(req WriteRequest) WriteOutcome {
	started := nowMs()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(req.TimeoutMs)*time.Millisecond)
	defer cancel()
	meta := func(u Usage) CallMeta {
		return CallMeta{Model: m.opts.WriterModel, LatencyMs: nowMs() - started, Attempts: 1, Usage: u}
	}
	tokens := req.MaxOutputTokens
	if tokens == 0 {
		tokens = 600
	}
	result, err := m.opts.Transport.GenerateObject(ctx, m.opts.WriterModel, req.System, req.Prompt, req.Schema, tokens)
	if err != nil {
		code := errorCode(err)
		if ctx.Err() == context.DeadlineExceeded {
			code = "timeout"
		}
		return WriteOutcome{ErrorCode: code, CallMeta: meta(Usage{})}
	}
	parsed, ok := req.Schema.Parse(result.Output)
	if !ok {
		return WriteOutcome{ErrorCode: "schema", CallMeta: meta(result.Usage)}
	}
	return WriteOutcome{OK: true, Output: parsed, CallMeta: meta(result.Usage)}
}

func (m *cloudModels) Health() *CloudHealth {
	local := LocalHealth{State: "missing"}
	if m.opts.Local != nil {
		local = m.opts.Local.Health()
	}
	return &CloudHealth{Judge: m.judgeBreaker.Health(), Write: m.writeBreaker.Health(), Local: local}
}

var schemaErrorName = regexp.MustCompile(`NoObjectGenerated|TypeValidation|JSONParse`)

func errorCode(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	if errors.Is(err, context.Canceled) {
		return "aborted"
	}
	var ce *CallError
	if !errors.As(err, &ce) {
		return "provider"
	}
	switch {
	case ce.Name == "TimeoutError":
		return "timeout"
	case ce.Name == "AbortError":
		return "aborted"
	case ce.Name == "NoCredentialsError":
		return "credentials"
	case schemaErrorName.MatchString(ce.Name):
		return "schema"
	}
	return "provider"
}

// validAnswers: every asked question answered with the asked type, an allowed choice, in-range probabilities.
func validAnswers(answers Answers, questions QuestionSet) bool {
	if answers.byID == nil {
		return false
	}
	for _, kv := range questions {
		q := kv.Value.(EvaluationQuestion)
		a, ok := answers.byID[kv.Key]
		if !ok || a.Type != q.Type {
			return false
		}
		if q.Type == "boolean" && (a.Probability == nil || !isProbability(*a.Probability)) {
			return false
		}
		if q.Type == "choice" {
			if _, known := q.Criteria.Get(a.Choice); !known {
				return false
			}
		}
	}
	return true
}
