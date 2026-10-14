package brain

import (
	"fmt"
	"sync"
)

// Breaker stops calling a model that keeps failing, so an outage never hammers the provider or burns a device's
// daily allowance at the relay.
//   - Three failures in a row open it. Calls then fail at once, without a request, for 30 s, then 1, 2 and 5 minutes
//     while the probes keep failing. When a wait is over exactly one probe goes out; a success closes it.
//   - A refused key, missing credentials or no credit (401, 402, 403) pause it for 5 minutes at once.
//   - The relay's "not now" for a long while (Rest: a Mac's daily share used, a trial ended; docs/specs/governor.md)
//     pauses it until the time the relay gives, at most a day, with no probe before. A daily share is "resting" (the
//     popover says for the rest of today); anything else is "paused". A new token (an invite typed in) ends it at once.
//   - A malformed answer means the model is reachable: a success here. An aborted call counts neither way.
type Breaker struct {
	mu       sync.Mutex
	failures int
	opens    int
	since    *int64
	retryAt  *int64
	paused   bool
	resting  bool
	// The token a Rest was for: a different one (an invite typed in, a renewal) ends the rest at once.
	restToken string
	probing   bool
	lastError *string
	now       func() int64
}

var breakerBackoffMs = []int64{30_000, 60_000, 120_000, 300_000}

const (
	breakerFailuresToOpen = 3
	breakerPauseMs        = 300_000
	// LongRestMs: a Retry-After this long or longer is the relay's "not now" (Rest), not a blip to retry.
	LongRestMs = 60_000
	maxRestMs  = 86_400_000
)

// ModelHealth: ok (calls go out), backoff (failing, waiting to probe), paused (the key, credit or trial was refused) or
// resting (this Mac's daily share is used, until the relay's time).
type ModelHealth struct {
	State     string  `json:"state"`
	Failures  int     `json:"failures"`
	Since     *int64  `json:"since"`
	RetryAt   *int64  `json:"retryAt"`
	LastError *string `json:"lastError"`
}

func NewBreaker(now func() int64) *Breaker { return &Breaker{now: now} }

// Allow: whether a call may go out now. While open, one probe goes out once the wait is over.
func (b *Breaker) Allow() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.retryAt == nil {
		return true
	}
	if b.probing || b.now() < *b.retryAt {
		return false
	}
	b.probing = true
	return true
}

// Record how a call that went out ended.
func (b *Breaker) Record(ok bool, code string, httpStatus int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if ok || code == "schema" {
		b.reset()
		return
	}
	if code == "aborted" {
		b.probing = false
		return
	}
	now := b.now()
	b.probing = false
	b.failures++
	if b.since == nil {
		b.since = ptr(now)
	}
	last := code
	if httpStatus != 0 {
		last = fmt.Sprintf("%s %d", code, httpStatus)
	}
	b.lastError = &last
	if code == "credentials" || httpStatus == 401 || httpStatus == 402 || httpStatus == 403 {
		b.paused = true
		b.retryAt = ptr(now + breakerPauseMs)
		return
	}
	b.paused = false
	if b.retryAt != nil || b.failures >= breakerFailuresToOpen {
		b.retryAt = ptr(now + breakerBackoffMs[min(b.opens, len(breakerBackoffMs)-1)])
		b.opens++
	}
}

func (b *Breaker) reset() {
	b.failures, b.opens, b.since, b.retryAt, b.paused, b.resting, b.restToken, b.probing, b.lastError = 0, 0, nil, nil, false, false, "", false, nil
}

// Rest: the relay said "not now" (`code`, e.g. daily_limit or trial_ended) until `retryAfterMs` from now. Nothing
// goes out before then, at most a day; `token` is the one that was refused.
func (b *Breaker) Rest(code string, httpStatus int, retryAfterMs int64, token string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	b.failures++
	if b.since == nil {
		b.since = ptr(now)
	}
	last := fmt.Sprintf("%s %d", code, httpStatus)
	b.lastError = &last
	b.paused, b.resting, b.restToken, b.probing = true, code == "daily_limit", token, false
	b.retryAt = ptr(now + min(retryAfterMs, maxRestMs))
}

// NewToken ends a Rest when the token is no longer the one refused (an invite typed in, a renewed token).
func (b *Breaker) NewToken(token string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.restToken != "" && token != b.restToken {
		b.reset()
	}
}

func (b *Breaker) Health() ModelHealth {
	b.mu.Lock()
	defer b.mu.Unlock()
	state := "ok"
	if b.retryAt != nil {
		state = "backoff"
		if b.resting {
			state = "resting"
		} else if b.paused {
			state = "paused"
		}
	}
	return ModelHealth{State: state, Failures: b.failures, Since: b.since, RetryAt: b.retryAt, LastError: b.lastError}
}
