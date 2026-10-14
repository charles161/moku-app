package brain

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"
)

// Every number about a day comes from one store, so every view of it must say the same (Charles, 2026-10-06:
// "completely wrong metrics bruh … run one audit to catch bugs like these, and make sure these never happens"). One
// Tuesday showed 4h 3m focused and 48m longest in Your day's header, "Tue 2h 51m" in its week strip, "8 tasks, 2h 59m"
// over its tasks and "Longest stretch 24m" on a task, while the popover said 3h 30m.
//
// On random histories (corrections, late verdicts, labels written back, forgotten threads, midnights), at many moments,
// the views are read at the same instant and compared:
//   - the world: the popover, the menu bar house and the house's pieces (house_piece);
//   - Your day: its header, its house, its work rows and its tasks (Other work included);
//   - the week strip's day (GET /v1/days);
//   - "Today counted"'s day (TodayCached).
// Arithmetic is checked here, by invariants: not by an AI model.
func TestEveryViewOfADaySaysTheSame(t *testing.T) {
	r := rand.New(rand.NewSource(7))
	moments := 0
	for round := 0; round < 25; round++ {
		store, err := OpenStore(":memory:")
		if err != nil {
			t.Fatal(err)
		}
		history := newRandomHistory(r, store)
		var now int64
		b := NewBrain(BrainOptions{Store: store, Models: &fakeModels{}, Config: func() CompanionConfig { return DefaultConfig }, Now: func() int64 { return now }})
		for step := 0; step < 120; step++ {
			history.step()
			if step%3 != 2 {
				continue
			}
			now = history.ts + int64(r.Intn(120_000))
			b.Lock()
			world := b.World()
			day, err := b.TodayCached("")
			var strip DaysResponse
			if err == nil {
				strip, err = b.Days(day.Date, day.Date)
			}
			b.Unlock()
			if err != nil {
				t.Fatal(err)
			}
			if problems := dayDisagreements(world, day, strip); len(problems) > 0 {
				t.Fatalf("round %d, step %d, %s: the views disagree:\n  %s", round, step, day.Date, strings.Join(problems, "\n  "))
			}
			moments++
		}
		b.Settle()
		store.Close()
	}
	t.Logf("%d moments, every view the same", moments)
}

// dayDisagreements: every way the views of one day differ, in words.
func dayDisagreements(world WorldSnapshot, day TodaySummary, strip DaysResponse) []string {
	var out []string
	differ := func(what string, values ...[2]any) {
		first := values[0][1]
		for _, v := range values[1:] {
			if v[1] != first {
				parts := make([]string, len(values))
				for i, w := range values {
					parts[i] = fmt.Sprintf("%s %v", w[0], w[1])
				}
				out = append(out, what+": "+strings.Join(parts, ", "))
				return
			}
		}
	}
	if len(strip.Days) != 1 {
		return []string{fmt.Sprintf("the week strip has %d days for %s", len(strip.Days), day.Date)}
	}
	s := strip.Days[0]
	differ("focused minutes", [2]any{"popover", world.TodayFocusMinutes}, [2]any{"Your day", day.FocusedMinutes}, [2]any{"week strip", s.FocusedMinutes})
	differ("longest stretch", [2]any{"popover", world.LongestFocusMinutesToday}, [2]any{"Your day", day.LongestFocusMinutes}, [2]any{"week strip", s.LongestFocusMinutes})
	differ("returns", [2]any{"popover", world.TodayReturns}, [2]any{"Your day", day.Returns}, [2]any{"week strip", s.Returns})
	// The house: a piece per 10 focused minutes, wherever it's counted.
	differ("house pieces", [2]any{"one per 10 focused minutes", day.FocusedMinutes / 10}, [2]any{"popover (house_piece)", world.UnitsToday},
		[2]any{"Your day", day.UnitsToday}, [2]any{"week strip", s.Pieces})
	var rows int64
	for _, row := range day.Built {
		rows += row.Minutes
	}
	differ("work rows", [2]any{"focused", day.FocusedMinutes}, [2]any{"rows' sum", rows})
	var tasks int64
	for _, goal := range day.Goals {
		tasks += goal.Minutes
		if goal.LongestMinutes > day.LongestFocusMinutes || goal.LongestMinutes > goal.Minutes {
			out = append(out, fmt.Sprintf("task %q: longest stretch %d, beside %d minutes on it and the day's longest %d", goal.Title,
				goal.LongestMinutes, goal.Minutes, day.LongestFocusMinutes))
		}
	}
	differ("tasks", [2]any{"focused", day.FocusedMinutes}, [2]any{"tasks' sum (Other work too)", tasks})
	return out
}
