// @ts-check
import { createHmac, timingSafeEqual } from 'node:crypto';
import { pipeline } from './access.js';

/**
 * Moku Pro through Dodo Payments, the merchant of record (docs/specs/payments.md). No accounts: the Mac is the identity.
 *
 * - POST /v1/checkout `{ plan: 'monthly' | 'yearly' }` with the Mac's token: a Dodo hosted checkout for that plan, with
 *   the Mac's id in its metadata. Answers `{ url }`; the app opens it in the browser. In test mode only the Macs in
 *   `DODO_TEST_DEVICES` get one: every Mac on 0.1.13 has the button, and a test card mustn't make anyone else Pro.
 * - POST /v1/dodo: Dodo's webhooks (Standard Webhooks signatures). Each is handled once (its `webhook-id`); a
 *   subscription's state decides until when the Mac is Pro (`moku:pro:<device>`).
 * - `proUntil(device)`: POST /v1/renew asks it, and a Mac that's paid gets a Pro token to that end.
 *
 * The relay keeps the Mac's id, the subscription's id, its status and its end. Dodo keeps the email and the card.
 */

/** Pro lasts a little past the billing date, so a renewal paid a day late doesn't drop anyone to local mode. */
export const GRACE_MS = 3 * 86_400_000;
/** Standard Webhooks: a signature older or newer than this is refused (a replayed delivery). */
export const WEBHOOK_TOLERANCE_S = 5 * 60;
/** How long a delivery's id is remembered, so a retry isn't handled twice. Dodo retries for about 32 hours. */
const SEEN_TTL_S = 7 * 86_400;
const DEVICE = /^[0-9a-f]{12,64}$/;

/**
 * Standard Webhooks (https://standardwebhooks.com): the signed content is `id.timestamp.body`, HMAC-SHA256 with the
 * secret (`whsec_` and base64), base64; the header holds one or more `v1,<signature>` separated by spaces.
 * @param {{ id: string | null, timestamp: string | null, signature: string | null, body: string, secret: string, nowS: number }} input
 */
export function verifyWebhook({ id, timestamp, signature, body, secret, nowS }) {
  if (!id || !timestamp || !signature || !secret) return false;
  const sentAt = Number(timestamp);
  if (!Number.isFinite(sentAt) || Math.abs(nowS - sentAt) > WEBHOOK_TOLERANCE_S) return false;
  const key = Buffer.from(secret.replace(/^whsec_/, ''), 'base64');
  const expected = createHmac('sha256', key).update(`${id}.${timestamp}.${body}`).digest();
  for (const part of signature.split(' ')) {
    const [version, value] = part.split(',', 2);
    if (version !== 'v1' || !value) continue;
    const given = Buffer.from(value, 'base64');
    if (given.length === expected.length && timingSafeEqual(given, expected)) return true;
  }
  return false;
}

/**
 * What a subscription's state means for the Mac: Pro until a time, or not Pro (0). Dodo sends the subscription as it
 * is at delivery, and events can arrive out of order, so the state decides, not the event's name.
 * @param {{ status?: string, next_billing_date?: string, cancel_at_next_billing_date?: boolean }} sub
 */
export function proUntilFor(sub) {
  const next = Date.parse(sub.next_billing_date ?? '');
  if (sub.status === 'active') {
    if (!Number.isFinite(next)) return 0;
    return sub.cancel_at_next_billing_date ? next : next + GRACE_MS;
  }
  // A grace period Dodo keeps open (a failed renewal being retried): access is kept until Dodo decides.
  if (sub.status === 'past_due') return Number.isFinite(next) ? next + GRACE_MS : 0;
  return 0;  // pending, on_hold, paused, cancelled (now), failed, expired
}

/**
 * @param {{ env: Record<string, string | undefined>, fetch: typeof fetch, redis: (at: number) => import('./access.js').Redis,
 *   allow: (key: string, limit: number, windowS: number) => Promise<boolean>, log: (line: string) => void,
 *   json: (status: number, body: unknown, headers?: Record<string, string>) => Response, now: () => number }} deps
 */
export function createPayments({ env, fetch: fetchImpl, redis, allow, log, json, now }) {
  const live = env.DODO_ENVIRONMENT === 'live_mode';
  const base = live ? 'https://live.dodopayments.com' : 'https://test.dodopayments.com';
  const products = { monthly: env.DODO_PRODUCT_MONTHLY, yearly: env.DODO_PRODUCT_YEARLY };
  const configured = Boolean(env.DODO_PAYMENTS_API_KEY && products.monthly && products.yearly);
  const testDevices = new Set((env.DODO_TEST_DEVICES ?? '').split(',').map((d) => d.trim()).filter(Boolean));

  /** The Mac's id comes from its token (the caller reads it); null: no token, or not a Mac's. */
  async function checkout(/** @type {Request} */ request, /** @type {string | null} */ device) {
    if (!configured) return json(503, { error: 'payments not configured' });
    if (!device) return json(401, { error: 'unknown token' });
    if (!live && !testDevices.has(device)) return json(503, { error: 'payments not open' });
    if (!(await allow(`checkout:${device}`, 20, 86_400))) return json(429, { error: 'too many checkouts' }, { 'retry-after': '3600' });
    /** @type {{ plan?: unknown }} */
    let body = {};
    try { body = await request.json(); } catch { /* an empty body is the monthly plan */ }
    const plan = body.plan === 'yearly' ? 'yearly' : 'monthly';
    const res = await fetchImpl(`${base}/checkouts`, {
      method: 'POST',
      headers: { authorization: `Bearer ${env.DODO_PAYMENTS_API_KEY}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        product_cart: [{ product_id: products[plan], quantity: 1 }],
        metadata: { moku_device: device },
        return_url: env.MOKU_CHECKOUT_RETURN_URL || 'https://hellomoku.com/thanks',
      }),
      signal: AbortSignal.timeout(15_000),
    }).catch(() => null);
    const answer = res?.ok ? /** @type {{ checkout_url?: string }} */ (await res.json().catch(() => ({}))) : null;
    if (!answer?.checkout_url) {
      log(`moku-proxy checkout ${plan} failed ${res?.status ?? 'network'}`);
      return json(502, { error: 'checkout unavailable' });
    }
    log(`moku-proxy checkout ${plan} ${device.slice(0, 12)}`);
    return json(200, { url: answer.checkout_url });
  }

  async function webhook(/** @type {Request} */ request) {
    const secret = env.DODO_PAYMENTS_WEBHOOK_KEY;
    if (!secret) return json(503, { error: 'payments not configured' });
    const body = await request.text();
    if (body.length > 256 * 1024) return json(413, { error: 'too large' });
    const id = request.headers.get('webhook-id');
    const ok = verifyWebhook({ id, timestamp: request.headers.get('webhook-timestamp'), signature: request.headers.get('webhook-signature'),
      body, secret, nowS: Math.floor(now() / 1000) });
    if (!ok) return json(401, { error: 'bad signature' });
    /** @type {{ type?: string, data?: Record<string, any> }} */
    let event;
    try { event = JSON.parse(body); } catch { return json(400, { error: 'bad json' }); }
    const type = event.type ?? '';
    if (!type.startsWith('subscription.')) return json(200, { received: true });  // payments, refunds: Dodo's to keep
    const data = event.data ?? {};
    const device = String(data.metadata?.moku_device ?? '');
    if (!DEVICE.test(device)) {
      log(`moku-proxy dodo ${type} no device`);
      return json(200, { received: true });
    }
    const until = proUntilFor(data);
    const key = `moku:pro:${device}`;
    const value = JSON.stringify({ sub: String(data.subscription_id ?? ''), status: String(data.status ?? ''), until });
    // Each delivery once: a retry of one already handled (perhaps older than what came since) changes nothing. Redis
    // down means 503, so Dodo tries again later rather than the payment being lost; a write that fails gives the claim back.
    const at = now();
    const seen = `moku:dodo:seen:${id}`;
    const [claim] = (await pipeline(redis(at), [['SET', seen, '1', 'NX', 'EX', String(SEEN_TTL_S)]])) ?? [];
    if (!claim) return json(503, { error: 'store unavailable' });
    if (claim.result !== 'OK') return json(200, { received: true, duplicate: true });
    const wrote = await pipeline(redis(at), [until > at ? ['SET', key, value, 'PXAT', String(until)] : ['DEL', key]]);
    if (!wrote) {
      await pipeline(redis(at), [['DEL', seen]]);
      return json(503, { error: 'store unavailable' });
    }
    log(`moku-proxy dodo ${type} ${String(data.status ?? '')} ${device.slice(0, 12)}${until > at ? ` until ${new Date(until).toISOString().slice(0, 10)}` : ''}`);
    return json(200, { received: true });
  }

  /** Until when this Mac is Pro (ms), or 0. */
  async function proUntil(/** @type {string | null} */ device) {
    if (!device) return 0;
    const [got] = (await pipeline(redis(now()), [['GET', `moku:pro:${device}`]])) ?? [];
    if (!got?.result) return 0;
    try {
      const until = Number(JSON.parse(got.result).until);
      return until > now() ? until : 0;
    } catch { return 0; }
  }

  return { checkout, webhook, proUntil, configured, live };
}
