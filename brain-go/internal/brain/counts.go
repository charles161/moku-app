package brain

import (
	"math"
	"sort"
)

// Counts: GET /v1/counts?date=YYYY-MM-DD: one local day in numbers, for the opt-in daily heartbeat the app sends
// through the relay. Numbers only, by construction.
func (b *Brain) Counts(date string) (DayCounts, error) {
	bounds, ok := dayWindow(date)
	if !ok {
		return DayCounts{}, &RangeError{"not a date: " + date}
	}
	days, err := b.Days(date, date)
	if err != nil {
		return DayCounts{}, err
	}
	totals := DayTotals{Date: date}
	if len(days.Days) > 0 {
		totals = days.Days[0]
	}
	spans, _ := daySpans(b.Store, bounds, b.now())
	verdicts, feedback, events, calls := b.Store.DayCounts(bounds.Start, bounds.End)
	var cloud, local []CallRow
	for _, c := range calls {
		if c.Local {
			local = append(local, c)
		} else {
			cloud = append(cloud, c)
		}
	}
	var watchedMs int64
	for _, s := range spans {
		if s.State != "away" {
			watchedMs += s.End - s.Start
		}
	}
	var screens int64
	var byState, bySource, byKind, byType []countRow
	for _, v := range verdicts {
		screens += v.N
		byState = append(byState, countRow{Key1: v.Key1, N: v.N})
		bySource = append(bySource, countRow{Key1: v.Key2, N: v.N})
	}
	byKind = append(byKind, feedback...)
	byType = append(byType, events...)
	var errors []countRow
	var cost float64
	var cloudFailures, localFailures int64
	for _, c := range cloud {
		if !c.OK {
			cloudFailures++
			errors = append(errors, countRow{Key1: deref(c.ErrorCode), N: 1})
		}
		if c.CostUsd != nil {
			cost += *c.CostUsd
		}
	}
	for _, c := range local {
		if !c.OK {
			localFailures++
		}
	}
	return DayCounts{
		DayTotals:      totals,
		Screens:        screens,
		WatchedMinutes: minutes(watchedMs),
		Verdicts:       tally(VerdictStates, byState),
		Sources:        tally(VerdictSources, bySource),
		Feedback:       tally(FeedbackKinds, byKind),
		Events:         tally(EventTypes, byType),
		Models: ModelCounts{
			CloudCalls: int64(len(cloud)), CloudFailures: cloudFailures, LocalCalls: int64(len(local)), LocalFailures: localFailures,
			CloudP50Ms: percentile(cloud, 0.5), CloudP90Ms: percentile(cloud, 0.9), LocalP50Ms: percentile(local, 0.5),
			CostUsd: Round(cost*1e6) / 1e6, Errors: tally(CallErrorKinds, errors),
		},
	}, nil
}

// tally: every key at 0, plus the rows' counts (rows with keys outside the list are left out).
func tally(keys []string, rows []countRow) OMap {
	counts := map[string]int64{}
	for _, r := range rows {
		counts[r.Key1] += r.N
	}
	out := make(OMap, len(keys))
	for i, k := range keys {
		out[i] = KV{k, counts[k]}
	}
	return out
}

// percentile: the answered calls' latency at p (0 when there were none).
func percentile(calls []CallRow, p float64) int64 {
	var sorted []int64
	for _, c := range calls {
		if c.OK {
			sorted = append(sorted, c.LatencyMs)
		}
	}
	if len(sorted) == 0 {
		return 0
	}
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	return sorted[min(len(sorted)-1, int(math.Floor(p*float64(len(sorted)))))]
}
