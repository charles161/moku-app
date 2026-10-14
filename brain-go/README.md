# brain-go

Moku's brain as one native binary: the localhost server the Mac app talks to (127.0.0.1:8020). Moku.app ships it
as `Resources/brain/moku-brain`; `scripts/build-app.sh` builds it from the last commit. It began as a port of a
TypeScript brain (removed on 2026-10-01, in git history) and kept its HTTP contract, SQLite schema, rulebooks, prompts,
budgets and model wire protocol.

```bash
GOTOOLCHAIN=local go build -o moku-brain .    # pure Go (modernc SQLite), no cgo
GOTOOLCHAIN=local go test ./...               # includes the model requests, byte for byte against testdata/
./moku-brain --port 0                         # MOKU_HOME, MOKU_BRAIN_PORT, MOKU_BRAIN_TOKEN, MOKU_LOCAL_MODEL=off, MOKU_GOAL_JUDGING=1 …
# MOKU_CALIBRATE=1 works only in a brain linked for calibration (releases never are):
GOTOOLCHAIN=local go build -ldflags "-X moku/brain/internal/brain.calibrationBuild=1" -o moku-brain .
GOTOOLCHAIN=local go run ./cmd/moku-replay    # Charles's rated moments, judged again and scored (a copy of the database)
```

**Who may call it:** only Moku. Every request but `GET /health` carries `Authorization: Bearer <brain token>`, the
secret in `$MOKU_HOME/brain-token` (owner-only; made by whichever of the app and the brain starts first, and handed to
the brain as `MOKU_BRAIN_TOKEN`). Without it the brain answers 401, so another macOS user or a sandboxed app can't read
Your day or delete it. A web page never gets in, token or not: a browser's `Origin`, `Sec-Fetch-Site: cross-site` or
`same-site`, or a DNS-rebinding page's foreign `Host` is refused with 403 (`app.go`, `access_test.go`). By hand:
`curl -H "authorization: Bearer $(cat ~/.moku/brain-token)" http://127.0.0.1:8020/v1/today`.

**The port:** Moku.app starts its brain on 8020, or on the next of 8021 to 8029 when something else holds 8020 (another
program or another macOS user's Moku): it passes by anything that isn't a `moku-brain` taking its token, tells the app's
client which port it chose, and starts its own again within a minute when the one in its way is gone. A brain started by
hand keeps 8020 unless told otherwise (`BrainPorts`, `BrainSupervisor`).

**Staying small and quick over months of use** (launch QA, 2026-10-04). The brain keeps weeks of history and never reads
it whole: the world's totals of the past (all-time focus minutes, minutes per goal) are kept in `meta` ("world_past"),
built a day at a time with the brain's lock let go between days (a few MB, 8 s on 90 days, once), loaded at each start and
brought forward each day; a correction to old verdicts deletes them and they're built again (`world.go`). Screen text and the
inputs of model calls that carried it live in their own tables (`sample_text`, `call_inputs`), so forgetting them frees whole
pages that new text reuses (set to NULL inside `samples` it left every page half empty: the file kept the most text it had
ever held, about 10 MB a day); deleted bytes are zeroed (`secure_delete`) and the write-ahead log emptied after each
retention pass. **The detail is kept 90 days and each day's summary for good** (`retention.go`): the store grew 3.5 to 5
MB a day, 1.3 to 1.8 GB a year. At start and every ten minutes `Brain.Retain` saves the summary of each day about to go
(everything Your day shows for it, gzipped JSON in `day_summaries`, with the note and goal lines Luna wrote kept in
`day_words`), then deletes the day's samples, verdicts, model calls and what hangs on them, a day at a time and in small
batches that take about 15 ms each with the brain's lock let go between them. `/v1/today` and `/v1/days` answer a pruned
date from its record, looking the same; the world's totals of the deleted days are kept in `meta` ("detail_pruned"), where a
rebuild of the world's totals starts. A store older than 90 days is migrated by the same pass, resumable at any step, and
rewritten once (VACUUM) when most of its file is free; in the steady state the freed pages are reused by the next day. The first start of 0.1.8 moves what text there is and rewrites the file once (`splitOutScreenText`). A brain that Moku.app starts gets `MOKU_PARENT_PID`
and stops when that app is gone, however it ended (`parent.go`), so none is left behind. A damaged database is set aside
as `moku.sqlite.damaged` and a new one starts (`OpenStore`); the day maths follow the Mac's time zone, also when it changes
and where the clocks skip midnight (`zone.go`). `go test ./internal/brain -run TestSeedHistory` with `MOKU_SEED_DB` and
`MOKU_SEED_DAYS` writes a heavy user's months of history to a database, to measure on.

Goal-aware judging (`goaljudge.go`, `reuse.go`) and the calibration dashboard (`calibrate.go`, `calibrate.html`) run only
with `MOKU_GOAL_JUDGING=1` or `MOKU_CALIBRATE=1`; docs/rules.md has the rules.

The local model (2.1 GB) is downloaded only when the app ships the llama.cpp server to run it. Release builds for the
beta don't (MOKU_LOCAL_MODEL=0).

## How it's built

`internal/brain` kept the TypeScript brain's layout file for file (`focus.go` was `focus.ts`, and so on). That brain ran on
one thread and switched only at an `await`. Here one brain lock plays that part: requests and background work hold it
and release it only while waiting on a model, so the logic ports line for line without data races. Prompts are written
exactly as JavaScript's `JSON.stringify` writes them (`jsjson.go`): key order, no HTML escaping, U+2028 left as is.

It aims for a 24 MiB heap (GOGC 50 and a soft memory limit): about 25 MB resident, against 62 MB for Node.
