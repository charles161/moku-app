// @ts-check
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { createProxy, hashToken } from '../api/_lib/proxy.js';
import { MAX_BODY_BYTES, MAX_TEXT, textLength } from '../api/_lib/shape.js';
import { BRAIN_REQUESTS, LUNA_BODY } from './support/brain-requests.js';

// Open-source review 2026-10-14, finding 1: anyone can mint a trial, and Luna took any prompt and any response format,
// up to 32 KB in and 1,000 tokens out: a general model API on the gateway key. The relay now takes only what the brain
// sends, in the brain's own sizes (api/_lib/shape.js has the measurements).

const TOKEN = 'moku_alice-token';
const ENV = { AI_GATEWAY_API_KEY: 'k', MOKU_TESTER_TOKENS: `alice:${hashToken(TOKEN)}`, MOKU_RATE_PER_MINUTE: '1000', MOKU_RATE_PER_DAY: '1000' };
const HEADERS = {
  'evaluation-model': { 'ai-model-id': 'typesafe-ai/jev' },
  'language-model': { 'ai-language-model-id': 'openai/gpt-6-luna' },
};

function relay(/** @type {Record<string, string>} */ env = {}) {
  /** @type {string[]} */
  const sent = [];
  /** @type {string[]} */
  const lines = [];
  /** @type {typeof fetch} */
  const fetchImpl = async (_url, init) => { sent.push(new TextDecoder().decode(/** @type {Uint8Array} */ (init?.body))); return new Response('{"content":[]}'); };
  const handle = createProxy({ env: { ...ENV, ...env }, fetch: fetchImpl, log: (l) => lines.push(l) });
  const call = async (/** @type {'evaluation-model' | 'language-model'} */ endpoint, /** @type {unknown} */ body) => {
    const res = await handle(new Request(`https://relay.example/v4/ai/${endpoint}`, {
      method: 'POST', headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json', ...HEADERS[endpoint] },
      body: typeof body === 'string' ? body : JSON.stringify(body),
    }));
    return { status: res.status, body: await res.json() };
  };
  return { call, sent, lines };
}

const fill = (/** @type {number} */ n, /** @type {string} */ script) => script.repeat(n);
/** Pads one string field so the whole body's text is exactly `text` characters. */
function padTo(/** @type {any} */ body, /** @type {number} */ text, /** @type {(body: any, more: string) => void} */ add) {
  const missing = text - (textLength(body.state ?? body.prompt) + textLength(body.questions ?? body.responseFormat));
  assert.ok(missing >= 0, `the shape alone is ${-missing} characters over`);
  add(body, 'x'.repeat(missing));
  return body;
}

const ZDR = { gateway: { zeroDataRetention: true } };
const thread = (/** @type {number} */ i) => `t_${String(i).padStart(10, '0')}`;
const BUCKETS = ['building', 'learning', 'working', 'communicating', 'career', 'watching', 'scrolling', 'chatting', 'reading', 'shopping', 'playing', 'other'];

/** Jev's largest: labeling a screen with 9 threads offered and a bucket, every input the brain cuts at its cap. */
function jevLabel(/** @type {string} */ script) {
  const t = (/** @type {number} */ n) => fill(n, script);
  const criteria = Object.fromEntries([...Array.from({ length: 9 }, (_, i) => [thread(i), `${t(60)}: ${t(160)}`]), ['none', 'None of these threads']]);
  const body = {
    state: { user_app: t(100), window: t(300), site: t(160), screen_contents: t(1500), your_work: Array.from({ length: 9 }, () => t(60)) },
    questions: {
      thread: { type: 'choice', instructions: 'Which of the person\'s ongoing threads of work is this screen part of?', criteria },
      category: { type: 'choice', instructions: 'Which general bucket fits?', criteria: Object.fromEntries(BUCKETS.map((b) => [b, `${b}: …`])) },
    },
    providerOptions: ZDR,
  };
  return padTo(body, 6_784, (b, more) => { b.questions.thread.instructions += more; });
}

/** Jev with the most choices: a goal just named against 20 others, and its bucket. */
function jevDedupe(/** @type {string} */ script) {
  const t = (/** @type {number} */ n) => fill(n, script);
  const criteria = Object.fromEntries([...Array.from({ length: 20 }, (_, i) => [thread(i), `${t(60)}: ${t(160)}`]), ['different', 'A different goal']]);
  const body = {
    state: { thread: { name: t(60), summary: t(160) } },
    questions: {
      same: { type: 'choice', instructions: 'Is it the same ongoing goal?', criteria },
      category: { type: 'choice', instructions: 'Which general bucket fits?', criteria: Object.fromEntries(BUCKETS.slice(0, 5).map((b) => [b, `${b}: …`])) },
    },
    providerOptions: ZDR,
  };
  return padTo(body, 6_276, (b, more) => { b.questions.same.instructions += more; });
}

/** A Luna call as gateway.go writes it: a system string, one user text part, a JSON schema of strings. */
function luna(/** @type {string} */ system, /** @type {string} */ prompt, /** @type {[string, number, number][]} */ fields, maxOutputTokens = 600) {
  return {
    maxOutputTokens, toolChoice: { type: 'auto' },
    responseFormat: { type: 'json', schema: {
      $schema: 'http://json-schema.org/draft-07/schema#', type: 'object',
      properties: Object.fromEntries(fields.map(([name, min, max]) => [name, { type: 'string', ...(min ? { minLength: min } : {}), maxLength: max }])),
      required: fields.map(([name]) => name), additionalProperties: false,
    } },
    prompt: [{ role: 'system', content: system }, { role: 'user', content: [{ type: 'text', text: prompt }] }],
    providerOptions: { ...ZDR, openai: { reasoningEffort: 'low' } }, headers: { 'user-agent': 'ai/7.0.111' },
  };
}

/** Luna's largest whose inputs the brain cuts: the day's note with 50 things finished. */
function lunaNote(/** @type {string} */ script) {
  const t = (/** @type {number} */ n) => fill(n, script);
  const row = { place: t(60), activity: t(40), minutes: 120 };
  const facts = { day: 'Tuesday', built: [row, row, row, row], wandered: [row, row, row], finished: Array.from({ length: 50 }, () => t(60)) };
  const body = luna('You are Tetsu…', `<data>\n${JSON.stringify(facts)}\n</data>`, [['note', 1, 400]]);
  return padTo(body, 5_741, (b, more) => { b.prompt[0].content += more; });
}

/** Luna's goal lines: 8 goals of 5 apps each, every activity 40 characters (0.1.8 on). */
function lunaGoalLines() {
  const goal = { goal: 'a'.repeat(60), minutes: 120, apps: Array.from({ length: 5 }, () => ({ place: 'a'.repeat(40), minutes: 10, did: ['a'.repeat(40), 'a'.repeat(40), 'a'.repeat(40)] })) };
  const data = Object.fromEntries(Array.from({ length: 8 }, (_, i) => [`goal_${i + 1}`, goal]));
  const body = luna('You write the one line under each of the person\'s goals…', `<data>\n${JSON.stringify(data)}\n</data>`, Array.from({ length: 8 }, (_, i) => [`goal_${i + 1}`, 1, 120]));
  return padTo(body, 9_976, (b, more) => { b.prompt[0].content += more; });
}

describe('model calls: only what the brain sends', () => {
  it('takes every request the brain sends, byte for byte, and forwards it', async () => {
    const r = relay();
    for (const { name, endpoint, body } of BRAIN_REQUESTS) {
      const res = await r.call(/** @type {any} */ (endpoint), body);
      assert.equal(res.status, 200, `${name}: ${JSON.stringify(res.body)}`);
    }
    assert.equal(r.sent.length, BRAIN_REQUESTS.length);
  });

  it('takes the largest request any shipped brain can make, in a 3-byte script too (Hindi, Chinese)', async () => {
    const r = relay();
    const largest = /** @type {[string, 'evaluation-model' | 'language-model', any, number][]} */ ([
      ['Jev label', 'evaluation-model', jevLabel('a'), 7_000], ['Jev label, 3-byte', 'evaluation-model', jevLabel('語'), 16_000],
      ['Jev duplicate check', 'evaluation-model', jevDedupe('語'), 15_500],
      ['Luna note', 'language-model', lunaNote('語'), 13_500], ['Luna goal lines', 'language-model', lunaGoalLines(), 11_000],
    ]);
    for (const [name, endpoint, body, bytes] of largest) {
      const text = JSON.stringify(body);
      assert.ok(Buffer.byteLength(text) >= bytes, `${name} is ${Buffer.byteLength(text)} bytes`);
      const res = await r.call(endpoint, text);
      assert.equal(res.status, 200, `${name}: ${JSON.stringify(res.body)}`);
    }
    // At least half again over the largest, so nothing a real Mac sends is near a limit.
    assert.ok(MAX_TEXT['evaluation-model'] >= 1.5 * 6_784 && MAX_TEXT['language-model'] >= 1.5 * 9_976);
    assert.ok(MAX_BODY_BYTES >= 1.5 * 16_022 && MAX_BODY_BYTES <= 24 * 1024);
  });

  it('refuses more text than the brain ever writes (400 too_long), and a body past the limit (413)', async () => {
    const r = relay();
    const jev = jevLabel('a');
    jev.state.screen_contents += 'a'.repeat(MAX_TEXT['evaluation-model'] - 6_784 + 1);
    assert.deepEqual(await r.call('evaluation-model', jev), { status: 400, body: { error: `more text than Moku sends (${MAX_TEXT['evaluation-model'] + 1} characters, at most ${MAX_TEXT['evaluation-model']})`, code: 'too_long' } });
    const note = lunaNote('a');
    note.prompt[1].content[0].text += 'a'.repeat(MAX_TEXT['language-model'] - 5_741 + 1);
    assert.equal((await r.call('language-model', note)).body.code, 'too_long');
    const big = lunaNote('語');
    big.prompt[1].content[0].text += '語'.repeat(4_000);
    assert.ok(Buffer.byteLength(JSON.stringify(big)) > MAX_BODY_BYTES);
    assert.deepEqual(await r.call('language-model', big), { status: 413, body: { error: 'body too large', code: 'too_large' } });
    assert.equal(r.sent.length, 0);
    assert.ok(r.lines.some((l) => /^moku-proxy alice typesafe-ai\/jev too-long \d+$/.test(l)));
  });

  it('refuses a Luna call the brain never makes: another prompt shape, a file or an image, any response format', async () => {
    const r = relay();
    const brain = JSON.parse(LUNA_BODY);
    const user = brain.prompt[1];
    const not = /** @type {[string, (b: any) => void][]} */ ([
      ['no system message', (b) => { b.prompt = [user]; }],
      ['a third message', (b) => { b.prompt.push(user); }],
      ['an assistant turn', (b) => { b.prompt[1] = { role: 'assistant', content: [{ type: 'text', text: 'hi' }] }; }],
      ['two parts', (b) => { b.prompt[1].content.push({ type: 'text', text: 'more' }); }],
      ['an image', (b) => { b.prompt[1].content = [{ type: 'image', image: 'https://example.com/a.png' }]; }],
      ['a file', (b) => { b.prompt[1].content = [{ type: 'file', data: 'aGk=', mediaType: 'application/pdf' }]; }],
      ['a URL part', (b) => { b.prompt[1].content = [{ type: 'text', text: 'hi', url: 'https://example.com' }]; }],
      ['user content as a string', (b) => { b.prompt[1].content = 'hi'; }],
      ['system content as parts', (b) => { b.prompt[0].content = [{ type: 'text', text: 'hi' }]; }],
      ['no prompt', (b) => { delete b.prompt; }],
      ['no response format', (b) => { delete b.responseFormat; }],
      ['free text', (b) => { b.responseFormat = { type: 'text' }; }],
      ['JSON without a schema', (b) => { b.responseFormat = { type: 'json' }; }],
      ['an array in the schema', (b) => { b.responseFormat.schema.properties.line = { type: 'array', items: { type: 'string' } }; }],
      ['an object in the schema', (b) => { b.responseFormat.schema.properties.line = { type: 'object', properties: {} }; }],
      ['a pattern in the schema', (b) => { b.responseFormat.schema.properties.line.pattern = '.*'; }],
      ['extra properties allowed', (b) => { b.responseFormat.schema.additionalProperties = true; }],
      ['13 fields', (b) => { for (let i = 0; i < 13; i++) b.responseFormat.schema.properties[`f${i}`] = { type: 'string' }; }],
      ['tools forced', (b) => { b.toolChoice = { type: 'required' }; }],
    ]);
    for (const [name, change] of not) {
      const body = structuredClone(brain);
      change(body);
      const res = await r.call('language-model', body);
      assert.equal(res.status, 400, name);
      assert.equal(res.body.code, 'bad_shape', name);
    }
    assert.equal(r.sent.length, 0);
    assert.ok(r.lines.some((l) => /^moku-proxy alice openai\/gpt-6-luna bad-shape prompt$/.test(l)), r.lines.join('\n'));
  });

  it('refuses a Jev call the brain never makes', async () => {
    const r = relay();
    const brain = jevLabel('a');
    const not = /** @type {[string, (b: any) => void][]} */ ([
      ['no questions', (b) => { b.questions = {}; }],
      ['five questions', (b) => { for (const id of ['a', 'b', 'c']) b.questions[id] = b.questions.thread; }],
      ['a question of another type', (b) => { b.questions.thread.type = 'text'; }],
      ['a choice without choices', (b) => { delete b.questions.thread.criteria; }],
      ['33 choices', (b) => { for (let i = 0; i < 23; i++) b.questions.thread.criteria[`c${i}`] = 'x'; }],
      ['a choice that is not words', (b) => { b.questions.thread.criteria.none = { text: 'x' }; }],
      ['no instructions', (b) => { delete b.questions.thread.instructions; }],
      ['another field in a question', (b) => { b.questions.thread.examples = ['x']; }],
      ['a state that is a list', (b) => { b.state = [b.state]; }],
      ['a state nested past the brain\'s', (b) => { b.state.screens = [{ app: { name: { full: { text: 'x' } } } }]; }],
      ['no state', (b) => { delete b.state; }],
    ]);
    for (const [name, change] of not) {
      const body = structuredClone(brain);
      change(body);
      const res = await r.call('evaluation-model', body);
      assert.equal(res.status, 400, name);
      assert.equal(res.body.code, 'bad_shape', name);
    }
    assert.equal(r.sent.length, 0);
  });

  it('caps maxOutputTokens at 600, the most any shipped brain asks for; MOKU_MAX_OUTPUT_TOKENS can only lower it', async () => {
    const r = relay();
    const brain = JSON.parse(LUNA_BODY);
    for (const asked of [400, 600]) assert.equal((await r.call('language-model', { ...brain, maxOutputTokens: asked })).status, 200);
    for (const asked of [601, 1000, 0, 1.5, '600', undefined]) {
      assert.deepEqual(await r.call('language-model', { ...brain, maxOutputTokens: asked }),
        { status: 400, body: { error: 'maxOutputTokens must be a whole number from 1 to 600', code: 'too_many_tokens' } }, `asked ${asked}`);
    }
    assert.equal((await relay({ MOKU_MAX_OUTPUT_TOKENS: '2000' }).call('language-model', { ...brain, maxOutputTokens: 1000 })).status, 400);
    const lower = relay({ MOKU_MAX_OUTPUT_TOKENS: '500' });
    assert.equal((await lower.call('language-model', { ...brain, maxOutputTokens: 600 })).body.error, 'maxOutputTokens must be a whole number from 1 to 500');
  });
});
