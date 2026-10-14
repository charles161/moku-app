# Moku gateway proxy

Testers' brains reach Jev and Luna through this proxy, each with their own token. The Vercel AI Gateway key (`JEV_VERCEL`) stays in Vercel, server-side, so no tester ever holds it.

```
tester's Mac                         Vercel (this project)                     Vercel AI Gateway
brain ── Bearer moku_… ──▶  /v4/ai/evaluation-model  ── Bearer <gateway key> ──▶  Jev
                           /v4/ai/language-model                                Luna
```

## What it does, per request

- **Token:** it checks the tester's token against `MOKU_TESTER_TOKENS`. That variable holds only SHA-256 hashes, never tokens. An unknown token gets `401`.
- **What it allows:** only the two endpoints the brain uses, each with its own model only (`typesafe-ai/jev` for `evaluation-model`, `openai/gpt-6-luna` for `language-model`), and only requests in the shape and sizes the brain sends (`api/_lib/shape.js`): bodies up to 24 KB, Luna calls of one system string and one text part with a JSON response format, asking for 600 output tokens at most. Anyone can mint a trial, so this keeps the relay from being a general model API. Anything else gets `404`, `403`, `413` or `400`.
- **Rate limits:** per token, 60 requests a minute and 3,000 a day by default. Over the limit it answers `429` with `Retry-After`. A normal day of use is about 300–600 calls.
- **Forwarding:** it sends the request to `https://ai-gateway.vercel.sh/v4/ai/…` with the real key and returns the gateway's answer as is. A gateway error comes back as its status and a code word only, `{"error":"the model gateway answered 429","code":"gateway_rate_limited"}`, with `Retry-After` (and `Retry-After-Ms`) kept: never the gateway's own body, which can name the provider or the account, or quote the request back. The log line adds the error's type word (`upstream=invalid_request_error`), never its message.
- **Logs:** one line per request: `moku-proxy <tester> <model> <status> <ms> in=<tokens> out=<tokens> $<cost>`. It never logs a body or a credential.
- **Usage per friend** (`api/_lib/usage.js`): with `POSTHOG_KEY` set, each answer also becomes a PostHog `model_call` event. It carries the friend (the invite's name, or `trial`), a 12-character device id, the model, tokens in and out, the gateway's cost, and the status. It never carries the prompt or the answer. It's sent after the response, so it adds no delay.

It has no dependencies. `api/_lib/proxy.js` holds all the logic, `api/proxy.js` is the Vercel function, and `vercel.json` routes `/v4/ai/*` and `/health` to it.

## Deploy (Charles, in the morning; about 10 minutes)

You need your Vercel login and the value of `JEV_VERCEL` from `bunny/.env`.

1. **Link a project.** Run from `bunny/proxy`:
   ```bash
   cd proxy
   npx vercel login            # if needed
   npx vercel link             # create a new project, e.g. "moku-proxy" (framework: Other)
   ```
2. **Make one token per tester.** Keep the token and the entry the command prints.
   ```bash
   npm run new-token -- alice
   npm run new-token -- bob
   ```
   Give each tester their own token, privately; it isn't stored anywhere else. Keep the `name:hash` entries.
3. **Set the environment** (Production):
   ```bash
   npx vercel env add AI_GATEWAY_API_KEY production    # paste the JEV_VERCEL value
   npx vercel env add MOKU_TESTER_TOKENS production    # paste: alice:<hash>,bob:<hash>
   ```
   These are optional:
   - `MOKU_RATE_PER_MINUTE` (default 60) and `MOKU_RATE_PER_DAY` (default 3000).
   - `MOKU_JUDGE_MODELS` (default `typesafe-ai/jev`) and `MOKU_VOICE_MODELS` (default `openai/gpt-6-luna`): the models allowed on `evaluation-model` and on `language-model`, comma-separated. `MOKU_ALLOWED_MODELS`, the one list for both, is no longer read (the relay logs a line when it's still set).
   - `MOKU_MAX_OUTPUT_TOKENS` (default `600`, and it can only lower that): the most a Luna call may ask to write.
   - Moku Pro through Dodo (`api/_lib/payments.js`, docs/specs/payments.md): `DODO_PAYMENTS_API_KEY`,
     `DODO_PAYMENTS_WEBHOOK_KEY` (the webhook's `whsec_` secret), `DODO_PRODUCT_MONTHLY`, `DODO_PRODUCT_YEARLY`, and
     `DODO_ENVIRONMENT` (`live_mode`; anything else is test mode), and `DODO_TEST_DEVICES` (the Mac ids, comma-separated,
     that get a checkout in test mode; every other Mac hears "not open yet"). Dodo's webhook: `https://moku-proxy.vercel.app/v1/dodo`
     with the `subscription.*` events. Without them, `/v1/checkout` and `/v1/dodo` answer 503.
4. **Exact rate limits (recommended).** Without Redis, each function instance counts on its own, so the limits are only approximate. For exact limits shared by every instance, add Upstash Redis from the Vercel Marketplace (Storage → Upstash for Redis → connect to this project). The proxy picks up `KV_REST_API_URL` and `KV_REST_API_TOKEN`, or `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`, by itself. Each address's limit is counted in the instance's memory first, so a refused request costs no Redis command. If Redis is configured but down (or slower than 2 s), trial calls get `503 {"code":"cloud_off"}` and the brain judges by its rules; other counts fall back to per-instance counting.
5. **Deploy:**
   ```bash
   npx vercel deploy --prod
   ```
   `vercel.json` pins the function to `bom1` (Mumbai), close to you and the testers. Change `regions` if they're elsewhere.
6. **Check it:**
   ```bash
   curl https://<your-proxy>.vercel.app/health
   # {"ok":true,"service":"moku-proxy","configured":true}
   ```
   Then open a release build of Moku (it reaches the models through the relay) and work for a minute. The Vercel
   logs should show lines like `moku-proxy trial:… typesafe-ai/jev 200 412ms in=870 out=37 $0.000036`.

## Installs, invites and the daily heartbeat

- **`POST /v1/install {device, invite?}`** (`api/_lib/access.js`): the app sends a hash of the Mac's hardware id and gets a signed token (`MOKU_TOKEN_SECRET`). With an invite code from `MOKU_INVITES` (`npm run new-invite -- <name>`) the Mac becomes a tester. Otherwise it gets a 21-day trial, dated from the first time that Mac was seen (kept in Upstash when it's configured). An ended trial gets `402`, and the brain then judges by its rules (release builds carry no local model).
- **Token expiry:** every call checks the token's `exp`. A trial's is its end (`402 trial ended`). A pro token must have one (`402 pro ended` after it, `401` without one; none has been minted yet). A tester token is checked when it has one (`401 token expired`). Tester tokens from `/v1/install` still have none, because the apps shipped so far (0.1.4–0.1.9) never renew: they keep working, and taking the invite's name out of `MOKU_INVITES` revokes them.
- **`POST /v1/renew`** with the install's token (`Authorization: Bearer moku1.…`): a fresh token, same answer shape as `/v1/install`. A tester's lasts 30 more days while its invite is still listed (even one without an expiry, or one that lapsed less than 30 days ago). A trial's or a pro token's end never moves here. 24 a day per token. No shipped app calls it yet.
- **Per-address limits** (installs, heartbeats, usage events, website errors, counted downloads; `api/_lib/address.js`): an IPv4 address counts as itself, an IPv6 address by its /64 (one home or phone owns a whole /64), and an IPv4-mapped one (`::ffff:a.b.c.d`) as its IPv4 address.
- **`POST /v1/heartbeat`** (`api/_lib/heartbeat.js`): once a day, only when the person has turned on "Share daily counts" in Settings, the app sends the previous day in numbers (the brain's `/v1/counts` plus the app's version, macOS, chip, plan, permissions, CPU and memory). The relay drops anything that isn't a number, a boolean or one of a few strictly shaped strings, and passes the rest to PostHog as one `daily_counts` event keyed by the device hash. Set `POSTHOG_KEY` (the project API key, `phc_…`; `POSTHOG_HOST` defaults to `https://eu.i.posthog.com`) and redeploy. Until then each heartbeat is one log line, `moku-proxy heartbeat <device prefix> <day> {…}`, readable with `npx vercel logs`.
- **`POST /v1/web-error`** (`api/_lib/web-errors.js`): hellomoku.com's own script failing in someone's browser (`website/src/error-reports.js`, by `navigator.sendBeacon`). Only with the site's Origin; 4 KB at most; 20 a day per address (keyed on a hash of it) and `MOKU_WEB_ERRORS_PER_DAY` (2,000) in all; headless browsers and bots are dropped. It keeps the error's name, its message (web addresses cut to origin and path, emails removed, 300 characters), the file, line and column in the site's script, the page, and the browser's and OS's family from the User-Agent, and passes them to PostHog as an `$exception` with level error, a new random `web-…` id each time, no person profile and no location. Logs `moku-proxy web-error <page> <type> forwarded`.

## Remote switches: `/v1/flags` and the kill switch

`api/_lib/flags.js`. The switches: `cloudJudging` (Jev), `cloudVoice` (Luna), `forceCalm` (the app never reacts to a
drift), `minVersion` (older builds ask Sparkle for an update), the call limits `callsPerMinute` and `callsPerDay`
(starting from `MOKU_RATE_PER_MINUTE` and `MOKU_RATE_PER_DAY`; a trial at most 3,000 a day), `newInstallsPerDay` (new
trials a UTC day, for everyone; `null` is no cap, `0` is closed; invites always get in), and the governor's
`dailyBudgetUsd` (default 1.6, `null` is off) and `costPerCall` (default 0.00004), for everyone only.

- **The governor** (`api/_lib/governor.js`, `docs/specs/governor.md`): the day's budget in calls is shared equally by the
  trial Macs active that day (the larger of yesterday's and today's count), a quarter of it by Macs in their first 3
  days; a hard pool stops the day's governed spend at the budget in dollars (what the gateway says each call cost) even on a surge. Past either: `429
  {"code":"daily_limit"}` with Retry-After until UTC midnight, and later calls that day are refused from memory.
  Testers, static tokens and pro aren't governed. Redis: one `HINCRBY` per call into a hash per day and group, and
  one read a minute per instance (`HLEN`s and an `INCRBYFLOAT` of its dollars). Once a day one instance sends PostHog
  `governor_day` (yesterday's active Macs and dollars, today's shares; never a device). An ended trial gets `402
  {"code":"trial_ended"}` with Retry-After six hours.

- **Where they're set:** defaults in code; the env var `MOKU_FLAGS` (JSON, needs a redeploy) overrides them for
  everyone, one plan (`tester`, `trial`, `pro`) or one device (its 12-character id from PostHog, or the whole hash):
  `{"everyone":{"cloudJudging":false},"plans":{"trial":{"callsPerDay":2000}},"devices":{"a1b2c3d4e5f6":{"forceCalm":true}}}`.
  With a Global Config (formerly Edge Config) store connected (`GLOBAL_CONFIG` or `EDGE_CONFIG`), its `flags` item,
  in the same shape, is read every 30 s and wins over `MOKU_FLAGS`, with no redeploy. The most specific scope wins.
- **Check a value first:** `npm run check-flags -- '<json>'`. A bad entry is dropped and the rest applies; `/health`
  says `"flags":{"source":…,"problems":N}` and the logs name what was dropped.
- **`POST /v1/flags {device, version}`** with the install's token: the app's switches (`cloudJudging`, `cloudVoice`,
  `forceCalm`, `minVersion`). The app asks at launch and every 10 minutes and keeps the last answer.
- **What the relay enforces itself:** with `cloudJudging` or `cloudVoice` off for an install, its Jev or Luna calls get
  `503 {"code":"cloud_off"}` with `Retry-After: 600`, never reaching the gateway. The brain treats that as the cloud
  resting: it judges by its rules (or uses built-in lines), and its breaker stops asking for a while. The call limits
  apply per plan and device, the day's from UTC midnight. `newInstallsPerDay` answers a new trial past the cap with `429 {"code":"installs_full"}`
  until the next UTC midnight; the app asks again every hour. **Without Upstash** each function instance counts on its
  own from its own start, so the real number can be the cap times the instances running, a cold start forgets the
  count, and a reinstall counts as new. With Upstash the count is shared and exact, and a Mac seen before isn't new.

## Give a tester access

Put two lines in their `~/.moku/credentials.env`, and make the file owner-only:

```bash
mkdir -p ~/.moku && chmod 700 ~/.moku
cat > ~/.moku/credentials.env <<'EOF'
MOKU_GATEWAY_URL=https://<your-proxy>.vercel.app/v4/ai
MOKU_ACCESS_TOKEN=moku_…
EOF
chmod 600 ~/.moku/credentials.env
```

The brain reads it when it starts. Its `/health` then says `"models":"proxy"`. Credentials are read in this order: `$MOKU_HOME/credentials.env`, then the environment, then `bunny/.env` (development only).

## Revoke a tester

Remove their entry from `MOKU_TESTER_TOKENS` (`npx vercel env rm` then `add`, or edit it in the dashboard) and redeploy with `npx vercel deploy --prod`. A changed environment variable only takes effect on a new deployment.

## Try it locally first (optional)

```bash
cd proxy
npm test                                                              # the proxy's tests, no network
AI_GATEWAY_API_KEY=… MOKU_TESTER_TOKENS=alice:<hash> PORT=8787 npm run local
# in another terminal, a brain pointed at it:
cd ../brain-go && GOTOOLCHAIN=local go build -o moku-brain . && MOKU_GATEWAY_URL=http://127.0.0.1:8787/v4/ai MOKU_ACCESS_TOKEN=<alice's token> ./moku-brain
```

## Costs and limits to keep in mind

- **Cost:** every tester's calls bill to your AI Gateway account. At 3,000 calls a day the rate limit caps one tester at about $0.06 a day of Jev, plus Luna's share (about $0.001 per 40 calls in the smoke runs).
- **Payload:** Vercel Functions accept request and response bodies up to 4.5 MB. The brain sends at most about 10 KB.
- **Time:** the function times out at 60 s (`maxDuration`). The brain gives up sooner (Jev after 7 s, Luna after 15 s).
