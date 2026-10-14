// @ts-check
/**
 * What each model call cost, per friend: one PostHog `model_call` event per gateway answer, with who made it
 * (the invite's name, or "trial"), a short device id, the model, tokens in and out, and the gateway's cost. It
 * never carries the prompt or the answer. Without POSTHOG_KEY nothing is sent. It goes after the response, so
 * nobody waits for it.
 */
import { DEFAULT_HOST } from './heartbeat.js';

/** Tokens and cost from a gateway answer: Jev's `usage.inputTokens` is a number, Luna's is `{ total }`. */
export function readUsage(/** @type {string} */ text) {
  try {
    const body = JSON.parse(text);
    if (!body?.usage) return null;
    const count = (/** @type {any} */ v) => (typeof v === 'number' ? v : typeof v?.total === 'number' ? v.total : 0);
    const cost = Number(body.providerMetadata?.gateway?.cost);
    return { input: count(body.usage.inputTokens), output: count(body.usage.outputTokens), cost: Number.isFinite(cost) ? cost : 0 };
  } catch {
    return null;
  }
}

/** "tester:friends/0a1b2c3d4e5f" → friends, 0a1b2c3d4e5f; "trial:<device hash>" → trial, its first 12; "alice" → alice. */
export function who(/** @type {string} */ subject) {
  const colon = subject.indexOf(':');
  const plan = colon > 0 ? subject.slice(0, colon) : 'tester';
  const sub = colon > 0 ? subject.slice(colon + 1) : subject;
  const [friend, device = ''] = sub.includes('/') ? sub.split('/') : plan === 'tester' ? [sub] : [plan, sub];
  return { plan, friend, device: device.slice(0, 12) };
}

/** Vercel keeps the function running for this promise after the response has gone (as @vercel/functions does). */
export function vercelWaitUntil(/** @type {Promise<unknown>} */ promise) {
  /** @type {any} */ (globalThis)[Symbol.for('@vercel/request-context')]?.get?.()?.waitUntil?.(promise);
}

/**
 * @param {{ env: Record<string, string | undefined>, fetch: typeof fetch, log: (line: string) => void,
 *   waitUntil?: (promise: Promise<unknown>) => void }} options
 */
export function createUsage({ env, fetch, log, waitUntil = vercelWaitUntil }) {
  const host = (env.POSTHOG_HOST || DEFAULT_HOST).replace(/\/$/, '');
  /** @param {{ tester: string, model: string, endpoint: string, status: number, latencyMs: number, spent: ReturnType<typeof readUsage> }} call */
  return (call) => {
    if (!env.POSTHOG_KEY) return;
    const { plan, friend, device } = who(call.tester);
    const event = {
      api_key: env.POSTHOG_KEY, event: 'model_call', distinct_id: device ? `${friend}/${device}` : friend,
      properties: {
        friend, device, plan, model: call.model, endpoint: call.endpoint, status: call.status, latency_ms: call.latencyMs,
        input_tokens: call.spent?.input ?? 0, output_tokens: call.spent?.output ?? 0, cost_usd: call.spent?.cost ?? 0,
        // The call comes from the relay, so PostHog would place it in the relay's data centre: no location at all.
        $process_person_profile: false, $geoip_disable: true,
      },
    };
    const sending = fetch(`${host}/i/v0/e/`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(event), signal: AbortSignal.timeout(3000),
    }).then((res) => { if (!res.ok) log(`moku-proxy usage posthog-error ${res.status}`); })
      .catch((/** @type {Error} */ error) => log(`moku-proxy usage posthog-error ${error.message}`));
    waitUntil(sending);
  };
}
