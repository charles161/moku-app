package brain

import (
	"fmt"
	"math"
	"slices"
)

// The LABELING pipeline: what is the person doing, in their words? For each context (the scope of a learned rule: an
// app window, a site, or one page of a content site) it assigns the thread, the activity phrase and the bucket, by
// executing the labeling rulebook. It runs in the background, one context at a time (so two contexts never start the
// same thread twice), and never changes the state.
//
// A verdict carries whatever labels are cached for its context (nil at first). When the labeler finishes it writes
// its labels into the verdicts that were waiting for them. A context is labeled again when its labels are over 10
// minutes old (1 minute for work with no thread) and its text has changed.

type Labels struct {
	Thread      *ThreadRef
	Activity    *string
	Category    *string
	IsNewThread bool
}

// retryAfterMs: after a failed labeling call, a context waits this long before the next try.
const retryAfterMs = minute

type labeler struct {
	b        *Brain
	queue    serialQueue
	queued   map[string]bool
	waiting  map[string][]string
	failedAt map[string]int64
	// When each placeholder-titled thread was last sent to Luna again.
	namingTriedAt map[string]int64
}

func newLabeler(b *Brain) *labeler {
	return &labeler{b: b, queued: map[string]bool{}, waiting: map[string][]string{}, failedAt: map[string]int64{}, namingTriedAt: map[string]int64{}}
}

// labelKey: the state, the app, and the scope a learned rule would have here.
func labelKey(s Screen, state string) string {
	return state + "|" + s.BundleID + "|" + scopeOf(s).describe()
}

func ref(t *ThreadRow) *ThreadRef {
	if t == nil {
		return nil
	}
	return &ThreadRef{ID: t.ID, Title: t.Title, Provisional: t.Provisional}
}

// labelsFor: the labels known now for this screen in this state, queueing a (re)label if needed.
func (l *labeler) labelsFor(sampleID string, s Screen, text *string, state string, ts int64) Labels {
	store := l.b.Store
	if state == "meeting" {
		return Labels{Activity: ptr(NeutralWords.Meeting), Category: ptr("communicating")}
	}
	if state != "working" && state != "drifting" {
		return Labels{}
	}
	key := labelKey(s, state)
	cached := store.ContextLabel(key)
	fresh := Rules.LabelCache.FreshMinutes
	if l.b.goalJudging {
		fresh = Rules.Goal.LabelFreshMinutes
	}
	if state == "working" && (cached == nil || cached.ThreadID == nil) {
		fresh = Rules.LabelCache.ThreadlessFreshMinutes
	}
	isFresh := cached != nil && (ts-cached.LabeledAt < int64(fresh)*minute || eqStr(cached.TextHash, s.TextHash))
	lastFailure, failedBefore := l.failedAt[key]
	if !isFresh && !(failedBefore && ts-lastFailure < retryAfterMs) {
		l.enqueue(key, s, text, state, ts)
	}
	if l.queued[key] || cached == nil {
		l.waiting[key] = append(l.waiting[key], sampleID)
	}
	if cached != nil {
		var thread *ThreadRow
		if cached.ThreadID != nil {
			thread = store.Thread(*cached.ThreadID)
		}
		if thread != nil {
			store.TouchThread(thread.ID, ts)
		}
		activity := cached.Activity
		if activity == nil && state == "working" {
			activity = l.b.activity.phrase(thread, s, text)
		}
		return Labels{Thread: ref(thread), Activity: activity, Category: cached.Category, IsNewThread: thread != nil && store.TakeNewThread(key)}
	}
	if state == "drifting" {
		if category := driftCategory(s.AppName, s.URL, s.BundleID, nil); category != "other" {
			return Labels{Category: &category, Activity: ptr(driftPhrase(category, s.AppName, s.URL))}
		}
	}
	return Labels{}
}

func (l *labeler) enqueue(key string, s Screen, text *string, state string, ts int64) {
	if l.queued[key] {
		return
	}
	l.queued[key] = true
	l.b.bg.add()
	l.queue.push(func() {
		defer l.b.bg.done()
		l.b.mu.Lock()
		defer l.b.mu.Unlock()
		defer delete(l.queued, key)
		defer func() {
			if p := recover(); p != nil {
				LogError(ErrTask, "moku background task failed: %v", p)
			}
		}()
		l.label(key, s, text, state, ts)
	})
}

type labelResult struct {
	threadID  *string
	activity  *string
	category  *string
	newThread bool
	reason    string
	naming    *Task
}

// label: one context through the labeling rulebook. A failed labeling call caches nothing: the context stays
// unlabeled and is tried again after retryAfterMs.
func (l *labeler) label(key string, s Screen, text *string, state string, ts int64) {
	store := l.b.Store
	var result *labelResult
	if state == "drifting" {
		result = l.labelDrift(s, text)
	} else {
		result = l.labelWork(s, text, ts)
	}
	if result == nil {
		l.failedAt[key] = ts
		return
	}
	delete(l.failedAt, key)
	store.SetContextLabel(key, ContextLabel{ThreadID: result.threadID, Activity: result.activity, Category: result.category,
		TextHash: s.TextHash, LabeledAt: ts, NewThread: result.newThread, Reason: result.reason})
	samples := l.waiting[key]
	delete(l.waiting, key)
	var thread *ThreadRow
	if result.threadID != nil {
		thread = store.Thread(*result.threadID)
	}
	write := func() {
		threadID, activity := result.threadID, result.activity
		if threadID != nil {
			// A new goal may have been merged into an existing one while it was being named (goal-aware judging).
			if named := l.b.resolveGoal(*threadID); named != nil {
				threadID = &named.ID
				if activity == nil {
					activity = named.Activity
				}
			}
		}
		store.WriteLabels(samples, threadID, activity, result.category)
	}
	if len(samples) > 0 {
		write()
	}
	// A new thread's phrase arrives with its name: fill it in then.
	if len(samples) > 0 && result.naming != nil {
		naming := result.naming
		l.b.background(func() {
			l.b.await(naming)
			write()
		})
	}
	if thread != nil {
		store.TouchThread(thread.ID, ts)
		store.UpdateThreadCategory(thread.ID)
	}
}

// labelDrift: the bucket (a well-known site decides; otherwise Jev picks) and the phrase "watching YouTube".
func (l *labeler) labelDrift(s Screen, text *string) *labelResult {
	category := driftCategory(s.AppName, s.URL, s.BundleID, nil)
	reason := fmt.Sprintf("[category] %s: a well-known drift", category)
	if category == "other" {
		answers := l.askJev(s, text, nil, QuestionSet{{"category", categoryQuestion()}})
		if answers == nil {
			return nil
		}
		category = driftCategory(s.AppName, s.URL, s.BundleID, answers.category)
		reason = fmt.Sprintf("[category] %s: Jev's pick", category)
	}
	return &labelResult{activity: ptr(driftPhrase(category, s.AppName, s.URL)), category: &category, reason: reason}
}

// labelWork: the thread (learned-thread, on-thread, media-thread, new-thread, unclear-thread), bucket and phrase.
func (l *labeler) labelWork(s Screen, text *string, ts int64) *labelResult {
	store := l.b.Store
	taught := findLearnedRule(store, s)
	var taughtThread *ThreadRow
	if taught != nil && taught.Effect == "work" && taught.ThreadID != nil {
		taughtThread = store.Thread(*taught.ThreadID)
	}
	var threads []ThreadRow
	if taughtThread == nil {
		threads = l.offeredThreads(s, ts)
	}
	questions := QuestionSet{}
	if len(threads) > 0 {
		questions = append(questions, KV{"thread", threadQuestion(threads)})
	}
	questions = append(questions, KV{"category", categoryQuestion()})
	answers := l.askJev(s, text, threads, questions)
	if answers == nil {
		return nil
	}
	thread := taughtThread
	var naming *Task
	reason := ""
	if taughtThread != nil {
		reason = fmt.Sprintf("[learned-thread] rule %d puts %s on \"%s\"", taught.ID, taught.describe(), taughtThread.Title)
	} else {
		pick := answers.thread
		var picked *ThreadRow
		if pick != nil && pick.choice != noneChoice {
			for i := range threads {
				if threads[i].ID == pick.choice {
					picked = &threads[i]
					break
				}
			}
		}
		host := siteOf(s.URL)
		media := slices.ContainsFunc(Rules.Media.Sites, func(site string) bool { return onSite(host, site) })
		minP := Rules.OnThread.MinP
		if media {
			minP = Rules.MediaThreadMinP
		}
		confidentNone := pick == nil || (pick.choice == noneChoice && pick.p >= Rules.NewThreadMinNoneP)
		switch {
		case picked != nil && pick.p >= minP:
			thread = picked
			rule := "on-thread"
			if media {
				rule = "media-thread"
			}
			reason = fmt.Sprintf("[%s] p=%s \"%s\"", rule, ToFixed(pick.p, 2), picked.Title)
		case confidentNone && !media:
			thread, naming = l.b.startThread(s, text, ts, nil)
			if pick != nil {
				reason = "[new-thread] none p=" + ToFixed(pick.p, 2)
			} else {
				reason = "[new-thread] no threads yet"
			}
		default:
			if pick != nil {
				what := "a thread"
				if pick.choice == noneChoice {
					what = "none"
				}
				reason = fmt.Sprintf("[unclear-thread] %s p=%s", what, ToFixed(pick.p, 2))
			} else {
				reason = "[unclear-thread] no pick"
			}
			if media {
				reason += " on a media site"
			}
		}
	}
	renaming := (*Task)(nil)
	if thread != nil && naming == nil {
		renaming = l.b.retryNaming(thread, s, text, ts, l.namingTriedAt)
	}
	category := workCategory(answers.category, thread)
	var threadID *string
	if thread != nil {
		threadID = &thread.ID
	}
	result := &labelResult{threadID: threadID, activity: l.b.activity.phrase(thread, s, text), category: &category, newThread: naming != nil, reason: reason, naming: naming}
	if result.naming == nil {
		result.naming = renaming
	}
	return result
}

// offeredThreads: the 8 most recently active threads (last 14 days), plus the one last worked on at this site.
func (l *labeler) offeredThreads(s Screen, ts int64) []ThreadRow {
	store := l.b.Store
	threads := store.Threads(ts-int64(Rules.OnThread.ActiveWithinDays)*24*60*minute, Rules.OnThread.OfferedThreads)
	host := siteOf(s.URL)
	for _, r := range store.RecentThreadsOn(s.BundleID, ts, 200) {
		if !eqStr(siteOf(r.URL), host) {
			continue
		}
		if slices.ContainsFunc(threads, func(t ThreadRow) bool { return t.ID == r.ThreadID }) {
			break
		}
		if t := store.Thread(r.ThreadID); t != nil {
			threads = append(threads, *t)
		}
		break
	}
	return threads
}

type pick struct {
	choice string
	p      float64
}

type labelAnswers struct {
	thread   *pick
	category *string
}

// askJev: one labeling Jev call; nil if it failed (the labels then stay unknown until the next try).
func (l *labeler) askJev(s Screen, text *string, threads []ThreadRow, questions QuestionSet) *labelAnswers {
	titles := make([]string, len(threads))
	for i, t := range threads {
		titles[i] = t.Title
	}
	var excerpt *string
	if text != nil {
		excerpt = ptr(Slice16(*text, TextExcerpt))
	}
	state := labelState(ScreenInput{App: s.AppName, WindowTitle: s.Title, Site: hostAndPath(s.URL), ScreenContents: excerpt}, titles)
	outcome := l.b.judgeModel(state, questions, false)
	var output any
	if outcome.OK {
		output = judgeOutput(outcome, false)
	}
	l.b.Store.InsertModelCall(ModelCallRecord{
		Purpose: "label", Model: outcome.Model, OK: outcome.OK, ErrorCode: errorCodePtr(outcome.OK, outcome.ErrorCode),
		LatencyMs: outcome.LatencyMs, Attempts: outcome.Attempts, TokensIn: outcome.TokensIn, TokensOut: outcome.TokensOut,
		CostUsd: outcome.CostUsd, Input: OMap{{"state", state}, {"questions", questions}}, Output: output,
	})
	if !outcome.OK {
		return nil
	}
	out := &labelAnswers{}
	if a, ok := outcome.Answers.Get("thread"); ok {
		p, given := a.Probabilities[a.Choice]
		if !given || math.IsNaN(p) {
			p = 0
		}
		out.thread = &pick{choice: a.Choice, p: p}
	}
	if a, ok := outcome.Answers.Get("category"); ok {
		out.category = ptr(a.Choice)
	}
	return out
}
