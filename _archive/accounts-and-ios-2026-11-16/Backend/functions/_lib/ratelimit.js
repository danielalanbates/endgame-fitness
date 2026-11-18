/**
 * Fixed-window rate limiting on D1, shared by the auth and fitness workers.
 * Files under functions/_lib/ are not routed — they are import-only.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Table (migrations/2026-10-27-rate-limits.sql):
 *   rate_limits(bucket TEXT, window_start INTEGER, count INTEGER,
 *               PRIMARY KEY (bucket, window_start))
 *
 * A limiter failure (missing table, D1 hiccup) never blocks the request: rate
 * limiting is defence in depth, not a gate that can lock everyone out.
 */

/**
 * Count one hit against `bucket` and report whether it is within `limit` per
 * `windowSecs`. Buckets are free-form strings, e.g. `login:email:a@b.c`,
 * `login:ip:1.2.3.4`, `comments:user:<id>`.
 *
 * @returns {Promise<{ok: boolean, retryAfter: number}>}
 */
export async function rateLimit(env, bucket, limit, windowSecs) {
  const now = Math.floor(Date.now() / 1000);
  const windowStart = now - (now % windowSecs);
  try {
    const row = await env.DB.prepare(
      `INSERT INTO rate_limits (bucket, window_start, count) VALUES (?, ?, 1)
       ON CONFLICT(bucket, window_start) DO UPDATE SET count = count + 1
       RETURNING count`
    ).bind(bucket, windowStart).first();
    const count = row?.count ?? 1;
    if (count > limit) return { ok: false, retryAfter: windowStart + windowSecs - now };
    return { ok: true, retryAfter: 0 };
  } catch (e) {
    console.error('rateLimit failed open:', e?.message || e);
    return { ok: true, retryAfter: 0 };
  }
}

/** The caller's IP as Cloudflare reports it, or 'unknown'. */
export function clientIP(request) {
  return request.headers.get('CF-Connecting-IP') || 'unknown';
}

/** A 429 response in the API's error shape. */
export function tooManyRequests(retryAfter) {
  return new Response(JSON.stringify({ error: 'rate_limited', retry_after: retryAfter }), {
    status: 429,
    headers: { 'Content-Type': 'application/json', 'Retry-After': String(retryAfter) },
  });
}

/**
 * Drop windows older than a day. Cheap; call opportunistically (e.g. 1% of
 * requests) rather than on a schedule.
 */
export async function pruneRateLimits(env) {
  const cutoff = Math.floor(Date.now() / 1000) - 86400;
  try {
    await env.DB.prepare('DELETE FROM rate_limits WHERE window_start < ?').bind(cutoff).run();
  } catch { /* best effort */ }
}
