// @ts-check
/**
 * What a model call may ask for: the requests Moku's brain makes, in the brain's own sizes, and nothing else. Anyone can
 * mint a trial, and Luna took any prompt and any response format, up to 32 KB in and 1,000 tokens out: a general model
 * API on the gateway key (open-source review 2026-10-14, finding 1).
 *
 * Every build shipped (0.1.0 to 0.1.13) writes its requests with the same brain-go gateway.go:
 *   Jev   { state, questions, providerOptions }: state a JSON object (the screen; or a thread or goal, with a few
 *         screens), 1 or 2 questions, each { type: "choice" | "boolean", instructions, criteria? }, at most 21 choices.
 *   Luna  { maxOutputTokens, toolChoice: { type: "auto" }, responseFormat: { type: "json", schema }, prompt, providerOptions,
 *         headers }: prompt is a system string and one user text part; the schema an object of 1 to 8 strings;
 *         maxOutputTokens 600, or 400 for an activity.
 * The relay rebuilds providerOptions and headers itself (proxy.js upstreamRequest) and drops any other field.
 *
 * The largest each can be, measured 2026-10-14 with each version's own builders through its own gateway.go, every input
 * the brain cuts at its cap (screen text 1,500 characters, a window title 300, an address 160; 9 threads or 8 goals with
 * 60-character titles and 160-character summaries; 20 goals in a duplicate check):
 *
 *                                          text    bytes    bytes when the person's text is in a 3-byte script
 *   Jev   label (9 threads and a bucket)   6,784    7.1 KB   16.0 KB  (Hindi, Chinese, Japanese…)
 *         duplicate check (20 goals)       6,276    6.6 KB   15.8 KB  (0.1.8 on)
 *         goal (8 goals)                   4,926    5.1 KB   12.6 KB  (0.1.8 on)
 *   Luna  the day's note, 50 things done   5,741    6.3 KB   13.8 KB  (what's finished isn't capped: 50 is a big day)
 *         naming a thread                  5,280    5.7 KB   12.0 KB
 *         goal lines, 8 goals of 5 apps    9,976   11.1 KB            (0.1.8 on; the apps per goal aren't capped)
 *
 * Builds before 0.1.8 measure the same or less (the app cut their titles to 300). Real calls are smaller: the largest
 * seen is about 2,300 tokens in (PostHog, 2026-10-09), and Charles's heaviest goal lines were 3,162 characters (8 goals,
 * 32 apps). Renaming threads from before 0.1.0 grows with the number of threads, but runs once, on databases older
 * than any build shipped.
 */

/** A model call's body: half again over the largest a brain sends, in a 3-byte script. Checked before it's read. */
export const MAX_BODY_BYTES = 24 * 1024;
/** Text in a call (every key and string, in UTF-16 units as the brain counts them): half again over the largest. */
export const MAX_TEXT = { 'evaluation-model': 12_000, 'language-model': 16_000 };
/** The most a Luna call may ask to write: the most any shipped brain asks for. MOKU_MAX_OUTPUT_TOKENS can only lower it. */
export const MAX_OUTPUT_TOKENS = 600;
/** Jev: questions a call, choices a question, and how deep its state goes (a thread's screens: state.screens[0].app). */
const MAX_QUESTIONS = 4;
const MAX_CHOICES = 32;
const MAX_STATE_DEPTH = 4;
/** Luna: the strings its answer may hold (goal lines ask for 8). */
const MAX_FIELDS = 12;

/** The text in a JSON value: every string and every key, in UTF-16 units (a string's .length). */
export function textLength(/** @type {unknown} */ value) {
  if (typeof value === 'string') return value.length;
  if (Array.isArray(value)) return value.reduce((n, item) => n + textLength(item), 0);
  if (value && typeof value === 'object') return Object.entries(value).reduce((n, [key, item]) => n + key.length + textLength(item), 0);
  return 0;
}

/** @returns {v is Record<string, any>} */
const isObject = (/** @type {unknown} */ v) => Boolean(v) && typeof v === 'object' && !Array.isArray(v);
/** Whether an object has exactly these keys (`optional` may be missing). */
const keysAre = (/** @type {object} */ v, /** @type {string[]} */ required, /** @type {string[]} */ optional = []) =>
  required.every((k) => Object.hasOwn(v, k)) && Object.keys(v).every((k) => required.includes(k) || optional.includes(k));
const isCount = (/** @type {unknown} */ v) => Number.isInteger(v) && /** @type {number} */ (v) >= 0;

/** How deep a JSON value nests objects and arrays (a string is 0, { a: "x" } is 1). */
function depth(/** @type {unknown} */ value) {
  if (!value || typeof value !== 'object') return 0;
  return 1 + Math.max(0, ...Object.values(value).map(depth));
}

/** Jev's questions, as questions.go writes them: what's wrong with them, or null. */
function questionsProblem(/** @type {unknown} */ questions) {
  if (!isObject(questions)) return 'questions';
  const all = Object.values(/** @type {object} */ (questions));
  if (all.length < 1 || all.length > MAX_QUESTIONS) return 'questions';
  for (const q of all) {
    if (!isObject(q) || typeof q.instructions !== 'string') return 'questions';
    if (q.type === 'boolean' && keysAre(q, ['type', 'instructions'])) continue;
    if (q.type !== 'choice' || !keysAre(q, ['type', 'instructions', 'criteria']) || !isObject(q.criteria)) return 'questions';
    const choices = Object.values(q.criteria);
    if (choices.length < 2 || choices.length > MAX_CHOICES || !choices.every((c) => typeof c === 'string')) return 'questions';
  }
  return null;
}

/** Luna's response format, as gateway.go writes it (StringSchema.JSONSchema): an object of strings, nothing else. */
function formatProblem(/** @type {unknown} */ format) {
  if (!isObject(format) || !keysAre(format, ['type', 'schema']) || format.type !== 'json') return 'responseFormat';
  const { schema } = format;
  if (!isObject(schema) || !keysAre(schema, ['type', 'properties', 'required', 'additionalProperties'], ['$schema'])) return 'responseFormat';
  if (schema.type !== 'object' || schema.additionalProperties !== false || (schema.$schema !== undefined && typeof schema.$schema !== 'string')) return 'responseFormat';
  if (!isObject(schema.properties)) return 'responseFormat';
  const fields = Object.entries(schema.properties);
  if (fields.length < 1 || fields.length > MAX_FIELDS) return 'responseFormat';
  for (const [, field] of fields) {
    if (!isObject(field) || !keysAre(field, ['type'], ['minLength', 'maxLength']) || field.type !== 'string') return 'responseFormat';
    if ((field.minLength !== undefined && !isCount(field.minLength)) || (field.maxLength !== undefined && !isCount(field.maxLength))) return 'responseFormat';
  }
  if (!Array.isArray(schema.required) || !schema.required.every((/** @type {unknown} */ name) => typeof name === 'string' && Object.hasOwn(schema.properties, name))) return 'responseFormat';
  return null;
}

/** Luna's prompt, as gateway.go writes it: a system string, then one user message of one text part. */
function promptProblem(/** @type {unknown} */ prompt) {
  if (!Array.isArray(prompt) || prompt.length !== 2) return 'prompt';
  const [system, user] = prompt;
  if (!isObject(system) || !keysAre(system, ['role', 'content']) || system.role !== 'system' || typeof system.content !== 'string') return 'prompt';
  if (!isObject(user) || !keysAre(user, ['role', 'content']) || user.role !== 'user' || !Array.isArray(user.content) || user.content.length !== 1) return 'prompt';
  const [part] = user.content;
  if (!isObject(part) || !keysAre(part, ['type', 'text']) || part.type !== 'text' || typeof part.text !== 'string') return 'prompt';
  return null;
}

/**
 * Whether a model call's body (parsed) is one the brain makes: null when it is, else the status, the answer and the log
 * word to refuse it with. `maxOutputTokens` is Luna's cap (MAX_OUTPUT_TOKENS, or lower).
 * @param {'evaluation-model' | 'language-model'} endpoint
 * @param {Record<string, unknown>} body
 * @param {number} maxOutputTokens
 * @returns {{ status: number, body: { error: string, code: string }, log: string } | null}
 */
export function requestProblem(endpoint, body, maxOutputTokens) {
  const shape = (/** @type {string} */ what) => ({ status: 400, body: { error: `not a request Moku makes (${what})`, code: 'bad_shape' }, log: `bad-shape ${what}` });
  let text;
  if (endpoint === 'evaluation-model') {
    if (!isObject(body.state) || depth(body.state) > MAX_STATE_DEPTH) return shape('state');
    const problem = questionsProblem(body.questions);
    if (problem) return shape(problem);
    text = textLength(body.state) + textLength(body.questions);
  } else {
    const asked = body.maxOutputTokens;
    if (!Number.isInteger(asked) || /** @type {number} */ (asked) < 1 || /** @type {number} */ (asked) > maxOutputTokens) {
      return { status: 400, body: { error: `maxOutputTokens must be a whole number from 1 to ${maxOutputTokens}`, code: 'too_many_tokens' }, log: 'too-many-tokens' };
    }
    if (body.toolChoice !== undefined && !(isObject(body.toolChoice) && keysAre(body.toolChoice, ['type']) && body.toolChoice.type === 'auto')) return shape('toolChoice');
    const problem = promptProblem(body.prompt) ?? formatProblem(body.responseFormat);
    if (problem) return shape(problem);
    text = textLength(body.prompt) + textLength(body.responseFormat);
  }
  if (text > MAX_TEXT[endpoint]) {
    return { status: 400, body: { error: `more text than Moku sends (${text} characters, at most ${MAX_TEXT[endpoint]})`, code: 'too_long' }, log: `too-long ${text}` };
  }
  return null;
}
