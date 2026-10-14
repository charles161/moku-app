// @ts-check
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { createProxy, hashToken, memoryLimiter, parseAllowlist, redisLimiter, testerFor, UPSTREAM } from '../api/_lib/proxy.js';
import { LUNA_BODY } from './support/brain-requests.js';

const TOKEN = 'moku_alice-token';
const ENV = {
  AI_GATEWAY_API_KEY: 'real-gateway-key',
  MOKU_TESTER_TOKENS: `alice:${hashToken(TOKEN)}, bob:${hashToken('moku_bob-token')}`,
  MOKU_RATE_PER_MINUTE: '3',
  MOKU_RATE_PER_DAY: '5',
};

/** A fake gateway that records what reached it. */
function gateway(status = 200, body = { answers: { kind: { type: 'choice', choice: 'work' } } }) {
  /** @type {{ url: string, headers: Headers, body: string }[]} */
  const calls = [];
  /** @type {typeof fetch} */
  const fetchImpl = async (input, init) => {
    calls.push({ url: String(input), headers: new Headers(init?.headers), body: new TextDecoder().decode(/** @type {ArrayBuffer} */ (init?.body)) });
    return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'set-cookie': 'x=1' } });
  };
  return { calls, fetchImpl };
}

/** Jev's question, as the brain asks it (brain-go questions.go). */
const KIND = { type: 'choice', instructions: 'Is this screen work or a distraction?', criteria: { work: 'Work', distraction: 'Not work' } };

function jevCall(token = TOKEN, over = {}) {
  return new Request('https://moku-proxy.example/api/proxy?path=evaluation-model', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`, 'content-type': 'application/json', 'ai-model-id': 'typesafe-ai/jev',
      'ai-gateway-protocol-version': '0.0.1', cookie: 'session=secret', 'x-forwarded-for': '1.2.3.4', ...over,
    },
    body: JSON.stringify({ state: { window: 'tree.py' }, questions: { kind: KIND } }),
  });
}

describe('the allowlist', () => {
  it('holds hashes, never tokens; finds the tester in constant time; skips malformed entries', () => {
    const list = parseAllowlist(`${ENV.MOKU_TESTER_TOKENS},junk,carol:not-hex,:abc`);
    assert.deepEqual(list.map((e) => e.name), ['alice', 'bob']);
    assert.equal(testerFor(TOKEN, list), 'alice');
    assert.equal(testerFor('moku_bob-token', list), 'bob');
    assert.equal(testerFor('moku_mallory', list), null);
    assert.equal(hashToken('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
});

describe('the proxy', () => {
  it('forwards a tester\'s Jev call with the real key, server-side, and returns the gateway\'s answer', async () => {
    const { calls, fetchImpl } = gateway();
    const lines = /** @type {string[]} */ ([]);
    const proxy = createProxy({ env: ENV, fetch: fetchImpl, log: (l) => lines.push(l) });
    const res = await proxy(jevCall());
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { answers: { kind: { type: 'choice', choice: 'work' } } });
    assert.equal(res.headers.get('set-cookie'), null);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, `${UPSTREAM}/evaluation-model`);
    assert.equal(calls[0].headers.get('authorization'), 'Bearer real-gateway-key');
    assert.equal(calls[0].headers.get('ai-gateway-auth-method'), 'api-key');
    assert.equal(calls[0].headers.get('ai-model-id'), 'typesafe-ai/jev');
    assert.equal(calls[0].headers.get('cookie'), null);
    assert.equal(calls[0].headers.get('x-forwarded-for'), null);
    assert.deepEqual(JSON.parse(calls[0].body), { state: { window: 'tree.py' }, questions: { kind: KIND }, providerOptions: { gateway: { zeroDataRetention: true } } });
    assert.equal(lines.length, 1);
    assert.match(lines[0], /^moku-proxy alice typesafe-ai\/jev 200 \d+ms$/);
    assert.ok(!lines[0].includes(TOKEN) && !lines[0].includes('real-gateway-key'));
  });

  it('works without the rewrite too, and for Luna (language-model)', async () => {
    const { calls, fetchImpl } = gateway();
    const proxy = createProxy({ env: ENV, fetch: fetchImpl, log: () => {} });
    const luna = new Request('https://moku-proxy.example/v4/ai/language-model', {
      method: 'POST', headers: { authorization: `Bearer ${TOKEN}`, 'ai-language-model-id': 'openai/gpt-6-luna' }, body: LUNA_BODY,
    });
    assert.equal((await proxy(luna)).status, 200);
    assert.equal(calls[0].url, `${UPSTREAM}/language-model`);
  });

  it('sends the gateway only what the brain sends: no fallback models, provider tools, streaming or extra headers, and always zero data retention', async () => {
    const { calls, fetchImpl } = gateway(200, { content: [], usage: { inputTokens: { total: 10 }, outputTokens: { total: 5 } } });
    const proxy = createProxy({ env: ENV, fetch: fetchImpl, log: () => {} });
    const { prompt, responseFormat } = JSON.parse(LUNA_BODY);
    // What someone holding any token (a trial anyone can mint) might try.
    const luna = new Request('https://moku-proxy.example/v4/ai/language-model', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json', 'user-agent': 'ai/7.0.111',
        'ai-gateway-protocol-version': '0.0.1', 'ai-language-model-specification-version': '4', 'ai-language-model-id': 'openai/gpt-6-luna',
        'ai-language-model-streaming': 'true', 'x-evil': '1', 'ai-gateway-auth-method': 'oidc',
      },
      body: JSON.stringify({
        maxOutputTokens: 600, prompt, toolChoice: { type: 'auto' }, responseFormat,
        tools: [{ type: 'provider-defined', id: 'openai.web_search', name: 'web_search', args: {} }],
        providerOptions: { gateway: { models: ['openai/gpt-6-pro'], only: ['bogus'], zeroDataRetention: false }, openai: { reasoningEffort: 'high' } },
        headers: { 'user-agent': 'ai/7.0.111', 'x-provider-key': 'theirs' },
        temperature: 2,
      }),
    });
    assert.equal((await proxy(luna)).status, 200);
    const sent = calls[0];
    assert.equal(sent.headers.get('ai-language-model-streaming'), 'false');
    assert.equal(sent.headers.get('x-evil'), null);
    assert.equal(sent.headers.get('ai-gateway-auth-method'), 'api-key');
    assert.equal(sent.headers.get('ai-language-model-id'), 'openai/gpt-6-luna');
    assert.equal(sent.headers.get('ai-language-model-specification-version'), '4');
    assert.deepEqual(JSON.parse(sent.body), {
      prompt, maxOutputTokens: 600, responseFormat, toolChoice: { type: 'auto' },
      headers: { 'user-agent': 'ai/7.0.111' },
      providerOptions: { gateway: { zeroDataRetention: true }, openai: { reasoningEffort: 'low' } },
    });

    // Jev keeps its state and questions only (no output tokens to ask for), and a body that isn't a JSON object goes nowhere.
    const jev = jevCall(TOKEN, { 'x-evil': '1' });
    const sneaky = new Request(jev.url, { method: 'POST', headers: jev.headers, body: JSON.stringify({ state: {}, questions: { kind: KIND }, maxOutputTokens: 1e6, providerOptions: { gateway: { models: ['x'] } } }) });
    assert.equal((await proxy(sneaky)).status, 200);
    assert.deepEqual(JSON.parse(calls[1].body), { state: {}, questions: { kind: KIND }, providerOptions: { gateway: { zeroDataRetention: true } } });
    assert.equal(calls[1].headers.get('x-evil'), null);
    for (const body of ['not json', '[1,2]', 'null']) {
      assert.equal((await proxy(new Request(jev.url, { method: 'POST', headers: jevCall().headers, body }))).status, 400, body);
    }
    assert.equal(calls.length, 2);
  });

  it('refuses: no token or an unknown one (401), another model (403), another endpoint (404), GET (405), a big body (413)', async () => {
    const { calls, fetchImpl } = gateway();
    const proxy = createProxy({ env: ENV, fetch: fetchImpl, log: () => {} });
    assert.equal((await proxy(jevCall('moku_mallory'))).status, 401);
    const noAuth = jevCall();
    const bare = new Request(noAuth.url, { method: 'POST', headers: { 'ai-model-id': 'typesafe-ai/jev' }, body: '{}' });
    assert.equal((await proxy(bare)).status, 401);
    assert.equal((await proxy(jevCall(TOKEN, { 'ai-model-id': 'anthropic/claude-opus-5' }))).status, 403);
    assert.equal((await proxy(new Request('https://p.example/api/proxy?path=image-model', { method: 'POST', headers: { authorization: `Bearer ${TOKEN}` }, body: '{}' }))).status, 404);
    assert.equal((await proxy(new Request('https://p.example/api/proxy?path=evaluation-model'))).status, 405);
    const big = new Request('https://p.example/api/proxy?path=evaluation-model', {
      method: 'POST', headers: { authorization: `Bearer ${TOKEN}`, 'ai-model-id': 'typesafe-ai/jev' }, body: 'x'.repeat(40 * 1024),
    });
    assert.equal((await proxy(big)).status, 413);
    assert.equal(calls.length, 0);
  });

  // 256 KB let one trial cost ~25× more per call than Moku ever asks (launch review 2026-10-09, B2); 32 KB was still three
  // times the largest (open-source review 2026-10-14). The largest a brain sends is 16 KB, with a 3-byte script (shape.js).
  it('takes a body up to 24 KB, half again over the largest Moku sends', async () => {
    const { calls, fetchImpl } = gateway();
    const proxy = createProxy({ env: ENV, fetch: fetchImpl, log: () => {} });
    const sized = (/** @type {number} */ n) => JSON.stringify({ state: { window: 'tree.py', screen_contents: '語'.repeat(n) }, questions: { kind: KIND } });
    assert.ok(Buffer.byteLength(sized(8_000)) > 24_000 && Buffer.byteLength(sized(8_000)) <= 24 * 1024);
    assert.equal((await proxy(new Request(jevCall().url, { method: 'POST', headers: jevCall().headers, body: sized(8_000) }))).status, 200);
    assert.equal((await proxy(new Request(jevCall().url, { method: 'POST', headers: jevCall().headers, body: sized(8_200) }))).status, 413);
    assert.equal(calls.length, 1);
  });

  // Security review low (2026-10-05): one allowlist for both endpoints, so Luna could be asked on Jev's endpoint (where
  // no output cap applies) and Jev on Luna's.
  it('allows each model on its own endpoint only: Jev for judging, Luna for lines', async () => {
    const { calls, fetchImpl } = gateway();
    const proxy = createProxy({ env: ENV, fetch: fetchImpl, log: () => {} });
    const luna = (/** @type {string} */ model) => new Request('https://moku-proxy.example/v4/ai/language-model', {
      method: 'POST', headers: { authorization: `Bearer ${TOKEN}`, 'ai-language-model-id': model }, body: LUNA_BODY,
    });
    assert.equal((await proxy(jevCall(TOKEN, { 'ai-model-id': 'typesafe-ai/jev' }))).status, 200);
    assert.equal((await proxy(luna('openai/gpt-6-luna'))).status, 200);
    const lunaAsJudge = await proxy(jevCall(TOKEN, { 'ai-model-id': 'openai/gpt-6-luna' }));
    assert.deepEqual([lunaAsJudge.status, await lunaAsJudge.json()], [403, { error: 'model not allowed: openai/gpt-6-luna' }]);
    assert.equal((await proxy(luna('typesafe-ai/jev'))).status, 403);
    assert.equal(calls.length, 2);
  });

  it('MOKU_JUDGE_MODELS and MOKU_VOICE_MODELS move each list; MOKU_ALLOWED_MODELS is no longer read, and says so', async () => {
    const { calls, fetchImpl } = gateway();
    const lines = /** @type {string[]} */ ([]);
    const proxy = createProxy({ env: { ...ENV, MOKU_JUDGE_MODELS: 'typesafe-ai/jev, typesafe-ai/jev-2', MOKU_VOICE_MODELS: 'openai/gpt-6-luna-mini', MOKU_ALLOWED_MODELS: 'openai/gpt-6-luna,typesafe-ai/jev' }, fetch: fetchImpl, log: (l) => lines.push(l) });
    const luna = (/** @type {string} */ model) => new Request('https://moku-proxy.example/v4/ai/language-model', {
      method: 'POST', headers: { authorization: `Bearer ${TOKEN}`, 'ai-language-model-id': model }, body: LUNA_BODY,
    });
    assert.equal((await proxy(jevCall(TOKEN, { 'ai-model-id': 'typesafe-ai/jev-2' }))).status, 200);
    assert.equal((await proxy(luna('openai/gpt-6-luna-mini'))).status, 200);
    assert.equal((await proxy(luna('openai/gpt-6-luna'))).status, 403);
    assert.equal((await proxy(luna('typesafe-ai/jev-2'))).status, 403);
    assert.equal((await proxy(jevCall(TOKEN, { 'ai-model-id': 'openai/gpt-6-luna-mini' }))).status, 403);
    assert.equal(calls.length, 2);
    assert.deepEqual(lines.filter((l) => l.includes('MOKU_ALLOWED_MODELS')), ['moku-proxy MOKU_ALLOWED_MODELS is no longer read: MOKU_JUDGE_MODELS and MOKU_VOICE_MODELS name each endpoint\'s models']);
  });

  it('rate-limits per token, per minute and per day, with Retry-After', async () => {
    let now = Date.UTC(2026, 8, 24, 9, 0, 0);
    const { calls, fetchImpl } = gateway();
    const proxy = createProxy({ env: ENV, fetch: fetchImpl, log: () => {}, now: () => now });
    for (let i = 0; i < 3; i++) assert.equal((await proxy(jevCall())).status, 200);
    const limited = await proxy(jevCall());
    assert.equal(limited.status, 429);
    assert.equal(limited.headers.get('retry-after'), '60');
    assert.equal((await proxy(jevCall('moku_bob-token'))).status, 200); // bob has his own budget
    now += 61_000;
    assert.equal((await proxy(jevCall())).status, 200);
    assert.equal((await proxy(jevCall())).status, 200); // 5 of 5 today
    now += 61_000;
    const daily = await proxy(jevCall());
    assert.equal(daily.status, 429);
    assert.equal(daily.headers.get('retry-after'), String(15 * 3600 - 122)); // the day's calls start again at UTC midnight
    assert.equal((await daily.json()).code, 'daily_limit');
    assert.equal(calls.length, 6);
  });

  // Security review low (2026-10-05): the gateway's error bodies reached the app unchanged. They can name the provider,
  // the gateway account or quote the request back.
  it('answers a gateway error with its status and a code word only, keeping Retry-After; the gateway\'s own words stay out of the logs too', async () => {
    const leaky = { error: { message: 'Invalid prompt: "Q3 salaries.xlsx — Numbers" (team acct_93f2, key vck_live_abc)', type: 'invalid_request_error', param: 'prompt' } };
    /** @type {typeof fetch} */
    const answering = async () => new Response(JSON.stringify(leaky), {
      status: 400, headers: { 'content-type': 'application/json', 'x-vercel-id': 'bom1::abc', 'x-gateway-account': 'acct_93f2', 'retry-after': '7', 'retry-after-ms': '7000' },
    });
    const lines = /** @type {string[]} */ ([]);
    const res = await createProxy({ env: ENV, fetch: answering, log: (l) => lines.push(l) })(jevCall());
    assert.equal(res.status, 400);
    assert.deepEqual(await res.json(), { error: 'the model gateway answered 400', code: 'gateway_bad_request' });
    assert.deepEqual([...res.headers.keys()].toSorted(), ['content-type', 'retry-after', 'retry-after-ms']);
    assert.deepEqual([res.headers.get('retry-after'), res.headers.get('retry-after-ms')], ['7', '7000']);
    assert.equal(lines.length, 1);
    assert.match(lines[0], /^moku-proxy alice typesafe-ai\/jev 400 \d+ms upstream=invalid_request_error$/);
    // The brain decides by the status: each keeps its own, with its code word.
    for (const [status, code] of /** @type {[number, string][]} */ ([[401, 'gateway_refused'], [402, 'gateway_no_credit'], [403, 'gateway_refused'], [404, 'gateway_not_found'],
      [408, 'gateway_timeout'], [413, 'gateway_too_large'], [429, 'gateway_rate_limited'], [500, 'gateway_down'], [503, 'gateway_down'], [504, 'gateway_timeout'], [418, 'gateway_error']])) {
      /** @type {typeof fetch} */
      const failing = async () => new Response('<html>Bad Gateway from upstream-7.internal</html>', { status });
      const answer = await createProxy({ env: ENV, fetch: failing, log: () => {} })(jevCall());
      assert.deepEqual([answer.status, await answer.json()], [status, { error: `the model gateway answered ${status}`, code }]);
    }
  });

  it('passes gateway errors through, says 502 when the gateway is unreachable, 503 when not configured', async () => {
    const failing = gateway(429, { error: { message: 'slow down', type: 'rate_limit' } });
    assert.equal((await createProxy({ env: ENV, fetch: failing.fetchImpl, log: () => {} })(jevCall())).status, 429);
    /** @type {typeof fetch} */
    const down = async () => { throw new Error('ECONNREFUSED'); };
    assert.equal((await createProxy({ env: ENV, fetch: down, log: () => {} })(jevCall())).status, 502);
    assert.equal((await createProxy({ env: { MOKU_TESTER_TOKENS: ENV.MOKU_TESTER_TOKENS }, log: () => {} })(jevCall())).status, 503);
    assert.equal((await createProxy({ env: { AI_GATEWAY_API_KEY: 'k' }, log: () => {} })(jevCall())).status, 503);
  });

  it('GET /health says whether it is configured, never with what', async () => {
    const res = await createProxy({ env: ENV, log: () => {} })(new Request('https://p.example/api/proxy?path=health'));
    const body = await res.json();
    assert.deepEqual(body, { ok: true, service: 'moku-proxy', configured: true, installs: false, flags: { source: 'code', problems: 0 } });
    assert.ok(!JSON.stringify(body).includes('real-gateway-key'));
  });
});

describe('the Redis limiter', () => {
  it('counts in Upstash (INCR + EXPIRE) and falls back to memory when Redis fails', async () => {
    /** @type {unknown[]} */
    const sent = [];
    let count = 0;
    /** @type {typeof fetch} */
    const redis = async (_url, init) => {
      sent.push(JSON.parse(String(init?.body)));
      return new Response(JSON.stringify([{ result: ++count }, { result: 1 }]));
    };
    const allow = redisLimiter('https://redis.example', 't', memoryLimiter(), redis, () => 0);
    assert.equal(await allow('alice:minute', 2, 60), true);
    assert.equal(await allow('alice:minute', 2, 60), true);
    assert.equal(await allow('alice:minute', 2, 60), false);
    assert.deepEqual(sent[0], [['INCR', 'moku:rate:alice:minute:60:0'], ['EXPIRE', 'moku:rate:alice:minute:60:0', '120']]);
    /** @type {typeof fetch} */
    const broken = async () => new Response('no', { status: 500 });
    const fallback = redisLimiter('https://redis.example', 't', memoryLimiter(() => 0), broken, () => 0);
    assert.equal(await fallback('bob:minute', 1, 60), true);
    assert.equal(await fallback('bob:minute', 1, 60), false);
  });

  it('keeps a day\'s counts when the memory is swept, however many minute counters fill it', async () => {
    let clock = 0;
    const allow = memoryLimiter(() => clock);
    assert.equal(await allow('new-installs', 1, 86_400), true);
    assert.equal(await allow('new-installs', 1, 86_400), false);
    // 10,000 cheap requests from made-up devices, a minute later, then one more that sweeps.
    clock = 61_000;
    for (let i = 0; i <= 10_000; i++) await allow(`events:${i}`, 1, 60);
    clock = 122_000;
    await allow('alice:minute', 60, 60);
    assert.equal(await allow('new-installs', 1, 86_400), false, 'the day\'s cap was reset by a sweep');
    // A day later it opens again.
    clock = 86_400_000;
    assert.equal(await allow('new-installs', 1, 86_400), true);
  });
});

describe('usage per friend', () => {
  const answer = { answers: { kind: { type: 'choice', choice: 'work' } }, usage: { inputTokens: 960, outputTokens: 12 }, providerMetadata: { gateway: { cost: '0.000047' } } };
  /** A gateway that answers with usage, and PostHog, both recorded. */
  function both() {
    /** @type {{ url: string, body: any }[]} */
    const posthog = [];
    /** @type {typeof fetch} */
    const fetchImpl = async (input, init) => {
      if (String(input).includes('posthog')) { posthog.push({ url: String(input), body: JSON.parse(String(init?.body)) }); return new Response('{}'); }
      return new Response(JSON.stringify(answer), { status: 200, headers: { 'content-type': 'application/json' } });
    };
    return { posthog, fetchImpl };
  }

  it('sends one model_call per answer, with tokens and cost but never the prompt or the answer; the brain gets the answer unchanged', async () => {
    const { posthog, fetchImpl } = both();
    const pending = /** @type {Promise<unknown>[]} */ ([]), lines = /** @type {string[]} */ ([]);
    const proxy = createProxy({ env: { ...ENV, POSTHOG_KEY: 'phc_test' }, fetch: fetchImpl, log: (l) => lines.push(l), waitUntil: (p) => pending.push(p) });
    const res = await proxy(jevCall());
    assert.deepEqual(await res.json(), answer);
    await Promise.all(pending);
    assert.equal(posthog.length, 1);
    assert.equal(posthog[0].url, 'https://eu.i.posthog.com/i/v0/e/');
    const { event, distinct_id, properties } = posthog[0].body;
    assert.equal(event, 'model_call'); assert.equal(distinct_id, 'alice');
    assert.deepEqual({ ...properties }, { friend: 'alice', device: '', plan: 'tester', model: 'typesafe-ai/jev', endpoint: 'evaluation-model', status: 200,
      latency_ms: properties.latency_ms, input_tokens: 960, output_tokens: 12, cost_usd: 0.000047, $process_person_profile: false, $geoip_disable: true });
    assert.doesNotMatch(JSON.stringify(posthog[0].body), /tree\.py|work/);
    assert.match(lines.at(-1) ?? '', /moku-proxy alice typesafe-ai\/jev 200 \d+ms in=960 out=12 \$0\.000047/);
  });

  it('sends nothing without POSTHOG_KEY', async () => {
    const { posthog, fetchImpl } = both();
    const pending = /** @type {Promise<unknown>[]} */ ([]);
    const proxy = createProxy({ env: ENV, fetch: fetchImpl, log: () => {}, waitUntil: (p) => pending.push(p) });
    await (await proxy(jevCall())).json();
    assert.equal(posthog.length + pending.length, 0);
  });

  it('names invites and trials by who made the call', async () => {
    const { who, readUsage } = await import('../api/_lib/usage.js');
    assert.deepEqual(who('tester:friends/0a1b2c3d4e5f'), { plan: 'tester', friend: 'friends', device: '0a1b2c3d4e5f' });
    assert.deepEqual(who(`trial:${'ab'.repeat(32)}`), { plan: 'trial', friend: 'trial', device: 'abababababab' });
    assert.deepEqual(readUsage(JSON.stringify({ usage: { inputTokens: { total: 5 }, outputTokens: { total: 3 } }, providerMetadata: { gateway: { cost: '0.0002' } } })), { input: 5, output: 3, cost: 0.0002 });
    assert.equal(readUsage('not json'), null);
  });
});
