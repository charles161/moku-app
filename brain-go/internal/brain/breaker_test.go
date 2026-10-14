package brain

import "testing"

// The breaker had no tests (launch review 2026-10-09). These pin what it does today, so the governor's change to
// pauses (a long Retry-After, a new token ending it) starts from known ground.

func newTestBreaker() (*Breaker, *int64) {
	now := int64(1_000_000)
	return NewBreaker(func() int64 { return now }), &now
}

func TestThreeFailuresInARowOpenTheBreakerAndOneProbeGoesOutAfterEachWait(t *testing.T) {
	b, now := newTestBreaker()
	for i := 0; i < 2; i++ {
		b.Record(false, "provider", 500)
		if !b.Allow() {
			t.Fatalf("closed after %d failure(s)", i+1)
		}
	}
	b.Record(false, "provider", 500)
	if b.Allow() || b.Health().State != "backoff" {
		t.Fatalf("still open after three failures in a row: %+v", b.Health())
	}
	for _, wait := range breakerBackoffMs {
		*now += wait - 1
		if b.Allow() {
			t.Fatalf("a call went out before its %d ms wait was over", wait)
		}
		*now++
		if !b.Allow() {
			t.Fatalf("no probe after the %d ms wait", wait)
		}
		if b.Allow() {
			t.Fatalf("a second call went out while the probe was out")
		}
		b.Record(false, "provider", 500)
	}
	*now += breakerBackoffMs[len(breakerBackoffMs)-1]
	if !b.Allow() {
		t.Fatalf("the longest wait didn't repeat")
	}
}

func TestASuccessOrAMalformedAnswerClosesIt(t *testing.T) {
	for _, code := range []string{"", "schema"} {
		b, now := newTestBreaker()
		for i := 0; i < 3; i++ {
			b.Record(false, "provider", 500)
		}
		*now += breakerBackoffMs[0]
		b.Allow()
		b.Record(code == "", code, 0)
		if h := b.Health(); h.State != "ok" || h.Failures != 0 || !b.Allow() {
			t.Fatalf("%q didn't close it: %+v", code, h)
		}
	}
}

func TestARefusedKeyMissingCredentialsOrNoCreditPauseItForFiveMinutesAtOnce(t *testing.T) {
	for _, c := range []struct {
		code   string
		status int
	}{{"provider", 401}, {"provider", 402}, {"provider", 403}, {"credentials", 0}} {
		b, now := newTestBreaker()
		b.Record(false, c.code, c.status)
		if h := b.Health(); h.State != "paused" || b.Allow() {
			t.Fatalf("%s %d: not paused after one: %+v", c.code, c.status, h)
		}
		*now += breakerPauseMs - 1
		if b.Allow() {
			t.Fatalf("%s %d: a call went out inside the pause", c.code, c.status)
		}
		*now++
		if !b.Allow() {
			t.Fatalf("%s %d: no probe when the pause ended", c.code, c.status)
		}
	}
}

func TestAnAbortedCallCountsNeitherWay(t *testing.T) {
	b, _ := newTestBreaker()
	b.Record(false, "provider", 500)
	b.Record(false, "provider", 500)
	b.Record(false, "aborted", 0)
	if h := b.Health(); h.State != "ok" || h.Failures != 2 {
		t.Fatalf("an abort counted: %+v", h)
	}
	b.Record(false, "provider", 503)
	if b.Allow() {
		t.Fatalf("the third real failure didn't open it")
	}
	if h := b.Health(); h.LastError == nil || *h.LastError != "provider 503" {
		t.Fatalf("last error %v, want provider 503", h.LastError)
	}
}
