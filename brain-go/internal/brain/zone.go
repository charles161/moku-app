package brain

import (
	"bytes"
	"log"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// The brain runs for weeks, and Go reads the Mac's time zone once, when the process starts. Someone who flies from
// Chennai to London with the lid shut would have Moku's days begin and end five and a half hours off until Moku was
// quit. So the brain asks again, and every "today", "this day's window" and clock it writes goes through Zone().
//
// The zone is read from /etc/localtime (a link to the system's zone file, which macOS repoints when the zone changes).
// A TZ set in the brain's own environment wins, as it does for Go, and is never re-read.

// localtimePath is where the system's zone is (a variable so a test can point it elsewhere).
var localtimePath = "/etc/localtime"

const zoneCheckEveryMs = 5_000

var (
	zone       atomic.Pointer[time.Location]
	zoneMu     sync.Mutex
	zoneFile   []byte // the zone file the current zone was made from
	zoneCheck  atomic.Int64
	zoneFromTZ = os.Getenv("TZ") != ""
)

func init() { zone.Store(time.Local) }

// Zone: the Mac's time zone now, as of the last RefreshZone.
func Zone() *time.Location { return zone.Load() }

// RefreshZone picks up a time zone change. It reads one small file and does nothing at all more often than every
// 5 seconds, so a request can call it freely.
func RefreshZone() {
	if zoneFromTZ {
		return
	}
	now := time.Now().UnixMilli()
	if last := zoneCheck.Load(); now-last < zoneCheckEveryMs || !zoneCheck.CompareAndSwap(last, now) {
		return
	}
	refreshZoneNow()
}

// refreshZoneNow: RefreshZone without the wait.
func refreshZoneNow() bool {
	data, err := os.ReadFile(localtimePath)
	if err != nil || len(data) == 0 {
		return false
	}
	zoneMu.Lock()
	defer zoneMu.Unlock()
	if bytes.Equal(data, zoneFile) {
		return false
	}
	loc, err := time.LoadLocationFromTZData("Local", data)
	if err != nil {
		return false
	}
	first := zoneFile == nil
	zoneFile = data
	zone.Store(loc)
	if !first {
		name, offset := time.Now().In(loc).Zone()
		log.Printf("moku brain: the Mac's time zone changed; days now follow %s (UTC%+d min)", name, offset/60)
	}
	return !first
}

// localClock: the wall clock time ("15:04") in the Mac's zone.
func localClock(ms int64) string { return time.UnixMilli(ms).In(Zone()).Format("15:04") }

// dayStart: the first moment of the calendar day y-m-d (d may run past the month, as time.Date lets it) in the Mac's
// zone. Where the clocks jump over midnight (Havana, Santiago, the Azores: 00:00 becomes 01:00) midnight doesn't exist
// that day, and time.Date answers with 23:00 the evening before: a day that starts on the wrong date, and one Your day
// listed 62 times. The day starts when the jump ends.
func dayStart(y int, m time.Month, d int) time.Time {
	loc := Zone()
	wantY, wantM, wantD := time.Date(y, m, d, 12, 0, 0, 0, loc).Date()
	start := time.Date(y, m, d, 0, 0, 0, 0, loc)
	for hour := 1; hour <= 3; hour++ {
		if gotY, gotM, gotD := start.Date(); gotY == wantY && gotM == wantM && gotD == wantD {
			break
		}
		start = time.Date(y, m, d, hour, 0, 0, 0, loc)
	}
	return start
}
