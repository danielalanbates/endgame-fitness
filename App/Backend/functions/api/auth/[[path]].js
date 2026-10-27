/**
 * BatesAI Membership — Auth Router
 *
 * Endpoints (all under /api/auth/):
 *   POST  login            email + password
 *   POST  register         email + password + name
 *   GET   verify           Bearer token -> user (used by every client on launch)
 *   POST  logout
 *   GET   oauth/google     browser redirect to Google
 *   POST  oauth/google     browser callback: authorization_code | id_token
 *   GET   oauth/apple      browser redirect to Apple
 *   POST  oauth/apple      browser callback: authorization_code | id_token
 *   POST  native/apple     native macOS/iOS Sign in with Apple (identity token)
 *   POST  native/google    native Google Sign-In (id_token)
 *   POST  handoff          native app redeems a one-time code from a browser sign-in
 *   DELETE account         in-app account deletion
 *
 * GET oauth/google and GET oauth/apple also take:
 *   ?return_to=<same-site path>  land there after the /membership callback; see
 *                                functions/_lib/return-to.js
 *   ?redirect_scheme=<scheme>    native app sign-in (Docs/API_V2.md §1.1). Only the
 *                                schemes in APP_SCHEMES are honoured; the callback
 *                                then hands the app a one-time code, never a token.
 * Without either, nothing about the web flow changes.
 *
 * SECURITY NOTE: every path that accepts a provider id_token verifies the token's
 * RS256 signature against the provider's published JWKS, plus issuer, audience and
 * expiry. A previous revision of this file base64-decoded the token payload without
 * checking the signature, which let anyone mint an arbitrary identity token and log
 * in as any user. Do not reintroduce an unverified decode.
 *
 * Tables: users, sessions (schema.sql); user_identities, auth_handoff_codes
 * (migrations/2026-10-27-auth-v2.sql); rate_limits (migrations/2026-10-27-rate-limits.sql).
 */

import {
  RETURN_TO_COOKIE, CLEAR_RETURN_TO_COOKIE, safeReturnPath, returnToCookie,
} from '../../_lib/return-to.js';
import { rateLimit, clientIP, tooManyRequests, pruneRateLimits } from '../../_lib/ratelimit.js';

const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';
const GOOGLE_ISSUERS = ['https://accounts.google.com', 'accounts.google.com'];
const GOOGLE_JWKS_URL = 'https://www.googleapis.com/oauth2/v3/certs';

const SESSION_TTL_SECONDS = 30 * 24 * 60 * 60; // matches the website's batesai_session cookie

// Native apps allowed to receive a sign-in handoff code. functions/membership.js
// keeps the same list; change both together.
const APP_SCHEMES = ['endgamefitness'];
const APP_SCHEME_COOKIE = 'oauth_app_scheme';
const APP_SCHEME_MAX_AGE = 300;
const HANDOFF_TTL_SECONDS = 120;

// PBKDF2-SHA256. Cloudflare Workers refuses more than 100,000 iterations, so
// that is both the default and the ceiling. PBKDF2_ITERATIONS (env) can lower
// the cost of NEW hashes if CPU limits ever bite; stored hashes keep their own.
const PBKDF2_MAX_ITERATIONS = 100000;
const PBKDF2_MIN_ITERATIONS = 10000;
const MAX_PASSWORD_LENGTH = 256;   // new passwords
const MAX_LOGIN_PASSWORD = 1024;   // older accounts registered before the cap

// Fixed-window limits (Docs/API_V2.md §1.2).
const LIMITS = {
  loginEmail: { limit: 10, window: 15 * 60 },
  loginIp: { limit: 30, window: 15 * 60 },
  registerIp: { limit: 5, window: 60 * 60 },
  handoffIp: { limit: 20, window: 15 * 60 },
};

export async function onRequest(context) {
  const { request, env, params } = context;
  const path = params.path || [];
  const origin = request.headers.get('Origin');

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders(env, origin) });
  }

  const url = new URL(request.url);
  const endpoint = path[0] || '';

  try {
    switch (endpoint) {
      case 'login':
        return withCors(await handleLogin(request, env), env, origin);
      case 'register':
        return withCors(await handleRegister(request, env), env, origin);
      case 'verify':
        return withCors(await handleVerify(request, env), env, origin);
      case 'me':
        return withCors(await handleMe(request, env), env, origin);
      case 'logout':
        return withCors(await handleLogout(request, env), env, origin);
      case 'oauth':
        return withCors(await handleOAuth(request, env, url, path), env, origin);
      case 'native':
        return withCors(await handleNative(request, env, path), env, origin);
      case 'account':
        return withCors(await handleAccount(request, env, path), env, origin);
      case 'handoff':
        return withCors(await handleHandoff(request, env), env, origin);
      default:
        return withCors(json({ error: 'Unknown endpoint' }, 404), env, origin);
    }
  } catch (error) {
    console.error('Auth API error:', error && error.stack ? error.stack : error);
    return withCors(json({ error: 'Internal server error' }, 500), env, origin);
  }
}

/* ------------------------------------------------------------------ */
/* Native sign-in (macOS / iOS app)                                    */
/* ------------------------------------------------------------------ */

/**
 * The native apps do Sign in with Apple on-device via AuthenticationServices,
 * which hands back an identity token (a JWT signed by Apple). We verify it here
 * and exchange it for a BatesAI session token. No client secret is involved,
 * which is why signature verification is the only thing standing between this
 * endpoint and a full account takeover.
 */
async function handleNative(request, env, path) {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const provider = path[1] || '';
  const body = await request.json().catch(() => ({}));

  let claims;
  let providerName;

  if (provider === 'apple') {
    const { identity_token: identityToken, nonce, full_name: fullName } = body;
    if (!identityToken) return json({ error: 'identity_token is required' }, 400);

    claims = await verifyProviderToken(identityToken, {
      jwksUrl: APPLE_JWKS_URL,
      issuers: [APPLE_ISSUER],
      audiences: appleAudiences(env),
    });
    if (!claims) return json({ error: 'Invalid Apple identity token' }, 401);

    // Apple echoes back the nonce we sent. If the client supplied one, it must
    // match either verbatim (client sent the hashed nonce, correct behaviour) or
    // after hashing (app build <=6 sent the RAW nonce while setting the SHA-256
    // on the Apple request, which made every real-device sign-in 401 here).
    if (nonce && claims.nonce && claims.nonce !== nonce && claims.nonce !== (await sha256Hex(nonce))) {
      return json({ error: 'Nonce mismatch' }, 401);
    }

    providerName = 'apple';
    claims.__name = formatAppleName(fullName);
  } else if (provider === 'google') {
    const { id_token: idToken } = body;
    if (!idToken) return json({ error: 'id_token is required' }, 400);

    claims = await verifyProviderToken(idToken, {
      jwksUrl: GOOGLE_JWKS_URL,
      issuers: GOOGLE_ISSUERS,
      audiences: googleAudiences(env),
    });
    if (!claims) return json({ error: 'Invalid Google id token' }, 401);

    providerName = 'google';
    claims.__name = claims.name;
  } else {
    return json({ error: 'Unknown provider' }, 404);
  }

  const { user, conflict } = await upsertOAuthUser(env, {
    provider: providerName,
    sub: claims.sub,
    // Apple may omit the email or hand out a private relay address;
    // upsertOAuthUser substitutes a per-sub placeholder when it is missing.
    email: claims.email,
    name: claims.__name,
    avatarUrl: claims.picture || null,
    emailVerified: isEmailVerified(claims),
  });
  if (conflict) return accountExistsResponse();

  const token = await issueSession(env, user);
  return json({ success: true, token, user: publicUser(user) }, 200);
}

/** Apple sends email_verified as the string "true"; Google as a boolean. */
function isEmailVerified(claims) {
  return claims.email_verified === true || claims.email_verified === 'true';
}

function accountExistsResponse() {
  return json({
    error: 'An account with this email already exists. Sign in with your password, '
      + 'or use a sign-in provider that has confirmed this email address.',
    code: 'account_exists',
  }, 409);
}

function appleAudiences(env) {
  // Web uses the Services ID; the native apps use their bundle identifiers.
  const configured = [env.OAUTH_APPLE_CLIENT_ID, env.APPLE_CLIENT_ID, env.APPLE_NATIVE_CLIENT_IDS];
  const list = configured.filter(Boolean).flatMap((v) => String(v).split(','));
  if (!list.length) list.push('org.batesai.membership');
  // The Endgame Fitness iOS bundle id. The older guess is kept as well: the
  // auth code live on production since 2026-09-26 accepts it, and dropping it
  // here could only ever turn a working sign-in into a 401.
  list.push('com.batesllc.EndgameFitnessMobile', 'org.batesai.endgamefitness');
  return [...new Set(list.map((s) => s.trim()).filter(Boolean))];
}

function googleAudiences(env) {
  const configured = [env.OAUTH_GOOGLE_CLIENT_ID, env.GOOGLE_CLIENT_ID, env.GOOGLE_NATIVE_CLIENT_IDS];
  const list = configured.filter(Boolean).flatMap((v) => String(v).split(','));
  return [...new Set(list.map((s) => s.trim()).filter(Boolean))];
}

function formatAppleName(fullName) {
  // Apple sends the display name exactly once, at first authorization.
  if (!fullName) return null;
  if (typeof fullName === 'string') return fullName.trim() || null;
  const given = fullName.givenName || fullName.firstName || '';
  const family = fullName.familyName || fullName.lastName || '';
  return `${given} ${family}`.trim() || null;
}

/* ------------------------------------------------------------------ */
/* Provider token verification (RS256 against published JWKS)          */
/* ------------------------------------------------------------------ */

const jwksCache = new Map(); // url -> { keys, fetchedAt }
const JWKS_TTL_MS = 60 * 60 * 1000;

async function fetchJwks(url) {
  const cached = jwksCache.get(url);
  if (cached && Date.now() - cached.fetchedAt < JWKS_TTL_MS) return cached.keys;

  const res = await fetch(url);
  if (!res.ok) throw new Error(`JWKS fetch failed for ${url}: ${res.status}`);
  const data = await res.json();
  const keys = data.keys || [];
  jwksCache.set(url, { keys, fetchedAt: Date.now() });
  return keys;
}

async function verifyProviderToken(token, { jwksUrl, issuers, audiences }) {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;

    const header = JSON.parse(base64UrlDecode(parts[0]));
    const payload = JSON.parse(base64UrlDecode(parts[1]));

    if (header.alg !== 'RS256') return null;

    let keys = await fetchJwks(jwksUrl);
    let jwk = keys.find((k) => k.kid === header.kid);
    if (!jwk) {
      // Providers rotate signing keys; bust the cache once before giving up.
      jwksCache.delete(jwksUrl);
      keys = await fetchJwks(jwksUrl);
      jwk = keys.find((k) => k.kid === header.kid);
    }
    if (!jwk) return null;

    const key = await crypto.subtle.importKey(
      'jwk',
      { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify']
    );

    const signature = base64UrlToBytes(parts[2]);
    const signedData = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    const valid = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, signature, signedData);
    if (!valid) return null;

    const now = Math.floor(Date.now() / 1000);
    if (typeof payload.exp !== 'number' || payload.exp < now) return null;
    if (typeof payload.iat === 'number' && payload.iat > now + 300) return null; // clock skew guard
    if (!issuers.includes(payload.iss)) return null;

    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (audiences.length && !aud.some((a) => audiences.includes(a))) return null;
    if (!payload.sub) return null;

    return payload;
  } catch (e) {
    console.error('Provider token verification failed:', e && e.message);
    return null;
  }
}

/* ------------------------------------------------------------------ */
/* Shared user + session helpers                                       */
/* ------------------------------------------------------------------ */

/**
 * Resolve a verified provider identity to a membership row, creating or linking
 * as needed. Returns { user } or { conflict: true }.
 *
 * Order:
 *   1. (provider, sub) in user_identities, then the legacy users.oauth_* slot.
 *      Sub is the only stable identifier Apple gives us; emails rotate.
 *   2. Same email on an existing row: link ONLY when the provider says the email
 *      is verified. An unverified provider email never auto-links ({conflict}).
 *   3. Otherwise create a new member.
 *
 * Account pre-hijack (API_V2 §1.2): anyone can POST /register with someone
 * else's address. When the real owner later arrives with a provider-verified
 * email, the row is linked to them and, if no provider had ever verified it,
 * the password that stranger set is cleared and every existing session is
 * deleted. The address owner wins.
 */
async function upsertOAuthUser(env, { provider, sub, email, name, avatarUrl, emailVerified }) {
  const now = Math.floor(Date.now() / 1000);
  const realEmail = typeof email === 'string' && email.includes('@') && !isPlaceholderEmail(email)
    ? email.trim().toLowerCase()
    : null;
  // Fall back to a stable per-sub placeholder so the NOT NULL email holds and
  // repeat logins still resolve to one account. Placeholders never link.
  const normalizedEmail = realEmail || `${sub}@${provider}.local`;
  const verified = Boolean(realEmail && emailVerified);

  let user = await findUserByIdentity(env, provider, sub);

  if (!user) {
    const existing = await env.DB.prepare('SELECT * FROM users WHERE email = ?').bind(normalizedEmail).first();
    if (existing) {
      if (!verified) return { conflict: true };
      await clearUnverifiedPassword(env, existing, now);
      // Keep the legacy single-slot columns populated for older readers, but
      // never overwrite an existing link (that used to flip-flop Apple/Google).
      if (!existing.oauth_provider) {
        await env.DB.prepare(
          'UPDATE users SET oauth_provider = ?, oauth_id = ?, updated_at = ? WHERE id = ? AND oauth_provider IS NULL'
        ).bind(provider, sub, now, existing.id).run();
        existing.oauth_provider = provider;
        existing.oauth_id = sub;
      }
      user = existing;
    }
  }

  if (!user) {
    const userId = crypto.randomUUID();
    const displayName = cleanName(name) || normalizedEmail.split('@')[0];
    await env.DB.prepare(
      `INSERT INTO users (id, email, password_hash, name, avatar_url, oauth_provider, oauth_id, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(userId, normalizedEmail, '', displayName, avatarUrl, provider, sub, now, now).run();

    await ensureFitnessProfile(env, userId, displayName);

    user = {
      id: userId,
      email: normalizedEmail,
      name: displayName,
      avatar_url: avatarUrl,
      oauth_provider: provider,
      oauth_id: sub,
    };
  } else {
    // Backfill a name/avatar if we have one now and didn't before.
    const freshName = cleanName(name);
    if ((freshName && !user.name) || (avatarUrl && !user.avatar_url)) {
      await env.DB.prepare('UPDATE users SET name = ?, avatar_url = ?, updated_at = ? WHERE id = ?')
        .bind(user.name || freshName, user.avatar_url || avatarUrl, now, user.id)
        .run();
      user.name = user.name || freshName;
      user.avatar_url = user.avatar_url || avatarUrl;
    }
    await ensureFitnessProfile(env, user.id, user.name);
  }

  await recordIdentity(env, { provider, sub, userId: user.id, email: realEmail, verified, now });
  return { user };
}

/** (provider, sub) -> users row, via user_identities first, then the legacy slot. */
async function findUserByIdentity(env, provider, sub) {
  try {
    const row = await env.DB.prepare(
      `SELECT u.* FROM user_identities i JOIN users u ON u.id = i.user_id
        WHERE i.provider = ? AND i.provider_sub = ?`
    ).bind(provider, sub).first();
    if (row) return row;
  } catch (e) {
    // Migration not applied yet: the legacy columns below still resolve every
    // account that existed before it.
    console.error('user_identities lookup skipped:', e && e.message);
  }
  return (await env.DB.prepare('SELECT * FROM users WHERE oauth_provider = ? AND oauth_id = ?')
    .bind(provider, sub).first()) || null;
}

/** True once any provider has vouched for this row's email. */
async function hasVerifiedIdentity(env, user) {
  // A legacy link predates the verified flag; migrations/2026-10-27-auth-v2.sql
  // backfills those as verified, and this keeps the rule consistent without it.
  if (user.oauth_provider) return true;
  try {
    const row = await env.DB.prepare(
      'SELECT 1 AS ok FROM user_identities WHERE user_id = ? AND verified = 1 LIMIT 1'
    ).bind(user.id).first();
    return Boolean(row);
  } catch {
    return false;
  }
}

/**
 * The pre-hijack rule. Only called once the provider has verified the email.
 * Uses '' rather than NULL for "no password": that is what OAuth-created rows
 * already hold, and older copies of the users table declare the column NOT NULL.
 */
async function clearUnverifiedPassword(env, user, now) {
  if (!user.password_hash) return;
  if (await hasVerifiedIdentity(env, user)) return;
  await env.DB.batch([
    env.DB.prepare("UPDATE users SET password_hash = '', updated_at = ? WHERE id = ?").bind(now, user.id),
    env.DB.prepare('DELETE FROM sessions WHERE user_id = ?').bind(user.id),
  ]);
  user.password_hash = '';
}

/** Remember which provider identities belong to a member. Best effort. */
async function recordIdentity(env, { provider, sub, userId, email, verified, now }) {
  try {
    await env.DB.prepare(
      `INSERT INTO user_identities (provider, provider_sub, user_id, email, verified, created_at, last_used_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(provider, provider_sub) DO UPDATE SET
         email = COALESCE(excluded.email, user_identities.email),
         verified = MAX(user_identities.verified, excluded.verified),
         last_used_at = excluded.last_used_at`
    ).bind(provider, sub, userId, email, verified ? 1 : 0, now, now).run();
  } catch (e) {
    console.error('recordIdentity skipped:', e && e.message);
  }
}

/** Placeholder addresses this file mints for providers that withhold an email. */
function isPlaceholderEmail(email) {
  return /@(apple|google)\.local$/i.test(String(email).trim());
}

function cleanName(name) {
  if (typeof name !== 'string') return null;
  const trimmed = name.replace(/\s+/g, ' ').trim().slice(0, 80);
  return trimmed || null;
}

/**
 * Fitness display names show up on friends lists and leaderboards, so the
 * starting value is held to the same shape PUT /fitness/profile enforces
 * (2-24 chars of letters, digits, space and _-.'). Anything else falls back to
 * "Athlete" and the player picks a name in the app.
 */
function starterDisplayName(name) {
  const cleaned = String(name || '')
    .normalize('NFC')
    .replace(/[^\p{L}\p{N} _.'-]/gu, '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 24)
    .trim();
  return cleaned.length >= 2 ? cleaned : 'Athlete';
}

async function ensureFitnessProfile(env, userId, displayName) {
  try {
    // New profiles start private (API_V2 §2.3); onboarding asks.
    await env.DB.prepare(
      `INSERT INTO fitness_profiles (user_id, display_name, is_public, created_at, updated_at)
       VALUES (?, ?, 0, ?, ?)
       ON CONFLICT(user_id) DO NOTHING`
    ).bind(userId, starterDisplayName(displayName), Math.floor(Date.now() / 1000), Math.floor(Date.now() / 1000)).run();
  } catch (e) {
    // Table may not exist yet on a partially-migrated database. Sign-in must not
    // fail because the fitness schema is behind.
    console.error('ensureFitnessProfile skipped:', e && e.message);
  }
}

/**
 * Sessions are opaque random tokens; only their SHA-256 is stored, and the
 * same `sessions` table backs the website's batesai_session cookie. So a token
 * minted here works for the web (as a cookie) and a web cookie works here (as a
 * Bearer token) — one membership, one session store, no signing secret.
 */
async function issueSession(env, user) {
  const token = base64UrlFromBytes(crypto.getRandomValues(new Uint8Array(32)));
  const expiresAt = Math.floor(Date.now() / 1000) + SESSION_TTL_SECONDS;
  await env.DB.prepare(
    'INSERT INTO sessions (id, user_id, token_hash, expires_at) VALUES (?, ?, ?, ?)'
  ).bind(crypto.randomUUID(), user.id, await sha256Hex(token), expiresAt).run();
  return token;
}

/**
 * GET /api/auth/me — the membership page's session probe. Shape matches the
 * page script: { signedIn, user: { name, email, tier, memberSince } }.
 */
async function handleMe(request, env) {
  const user = await sessionUser(request, env);
  if (!user) return json({ signedIn: false }, 200);
  const created = await env.DB.prepare('SELECT created_at FROM users WHERE id = ?')
    .bind(user.id).first();
  return json({
    signedIn: true,
    user: {
      name: user.name,
      email: user.email,
      tier: user.membership_tier || 'free',
      memberSince: created?.created_at || null,
    },
  }, 200);
}

/** Bearer token (or website cookie) -> user row, or null. */
export async function sessionUser(request, env) {
  const authHeader = request.headers.get('Authorization') || '';
  let token = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
  if (!token) token = readCookie(request, 'batesai_session') || '';
  if (!token) token = new URL(request.url).searchParams.get('token') || '';
  if (!token) return null;
  const hash = await sha256Hex(token);
  const t = Math.floor(Date.now() / 1000);
  try {
    return await env.DB.prepare(
      `SELECT u.id, u.email, u.name, u.avatar_url, u.membership_tier, s.expires_at
         FROM sessions s JOIN users u ON u.id = s.user_id
        WHERE s.token_hash = ? AND s.expires_at > ?`
    ).bind(hash, t).first() || null;
  } catch (e) {
    // Databases created before the membership_tier column existed fail the
    // query above ("no such column"); fall back to the columns we know exist.
    return await env.DB.prepare(
      `SELECT u.id, u.email, u.name, u.avatar_url, s.expires_at
         FROM sessions s JOIN users u ON u.id = s.user_id
        WHERE s.token_hash = ? AND s.expires_at > ?`
    ).bind(hash, t).first() || null;
  }
}

function readCookie(request, name) {
  const header = request.headers.get('Cookie') || '';
  for (const part of header.split(';')) {
    const [k, ...rest] = part.trim().split('=');
    if (k === name) return rest.join('=');
  }
  return null;
}

function publicUser(user) {
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    avatar_url: user.avatar_url || null,
    membership: user.membership_tier || user.membership || 'free',
  };
}

/* ------------------------------------------------------------------ */
/* Account deletion (App Store Review 5.1.1(v): in-app, no web detour)  */
/* ------------------------------------------------------------------ */

/**
 * DELETE /api/auth/account  (Bearer token or website cookie)
 *
 * Removes the membership row. Every fitness table references users(id) with
 * ON DELETE CASCADE, so profile, sessions, workouts, XP, feed, friendships,
 * guild membership, talents, quests and achievements all go with it. A guild
 * the user owned is handed to its longest-serving member first so the other
 * members are not orphaned. The response body is the same whether or not the
 * row existed, so a replayed request is harmless.
 */
async function handleAccount(request, env, path) {
  const action = path[1] || '';
  if (request.method === 'DELETE' || (request.method === 'POST' && action === 'delete')) {
    const user = await sessionUser(request, env);
    if (!user) return json({ error: 'Not signed in' }, 401);

    const ownedGuilds = await env.DB.prepare('SELECT id FROM guilds WHERE owner_id = ?')
      .bind(user.id).all();
    for (const guild of ownedGuilds.results || []) {
      const heir = await env.DB.prepare(
        'SELECT user_id FROM guild_members WHERE guild_id = ? AND user_id != ? ORDER BY joined_at ASC LIMIT 1'
      ).bind(guild.id, user.id).first();
      if (heir) {
        await env.DB.batch([
          env.DB.prepare("UPDATE guild_members SET role = 'owner' WHERE guild_id = ? AND user_id = ?")
            .bind(guild.id, heir.user_id),
          env.DB.prepare('UPDATE guilds SET owner_id = ? WHERE id = ?').bind(heir.user_id, guild.id),
        ]);
      } else {
        await env.DB.prepare('DELETE FROM guilds WHERE id = ?').bind(guild.id).run();
      }
    }

    // Tables that predate ON DELETE CASCADE on this database are cleared
    // explicitly; the rest cascade from the users row. A table named here that
    // does not exist on this database (a website-only table on a fitness-only
    // copy, or a migration not yet applied) is skipped rather than failing the
    // whole batch: it cannot hold rows for this user.
    const explicit = [
      'sessions', 'fitness_profiles', 'workout_sessions', 'xp_transactions', 'activity_feed',
      'activity_reactions', 'talents', 'achievements', 'quests', 'personal_records',
      'guild_members', 'challenge_participants', 'subscriptions', 'user_settings',
      'workout_programs', 'programs', 'meso_cycles', 'progress_metrics', 'talent_unlocks',
      'dm_sync', 'sm_progress', 'sm_profile', 'sm_plan',
      'auth_handoff_codes', 'user_identities',
    ];
    const present = await existingTables(env, [...explicit, 'friendships', 'challenges', 'rate_limits']);
    const statements = explicit.filter((table) => present.has(table)).map((table) =>
      env.DB.prepare(`DELETE FROM ${table} WHERE user_id = ?`).bind(user.id)
    );
    if (present.has('friendships')) {
      statements.push(env.DB.prepare('DELETE FROM friendships WHERE user_low = ? OR user_high = ?').bind(user.id, user.id));
    }
    if (present.has('challenges')) {
      statements.push(env.DB.prepare('DELETE FROM challenges WHERE creator_id = ? OR opponent_id = ?').bind(user.id, user.id));
    }
    if (present.has('rate_limits') && user.email) {
      // The only rate-limit rows tied to a person are keyed by a hash of their
      // email (see handleLogin); IP buckets are not personal to one account.
      statements.push(env.DB.prepare('DELETE FROM rate_limits WHERE bucket = ?')
        .bind(await emailBucket(user.email)));
    }
    statements.push(env.DB.prepare('DELETE FROM users WHERE id = ?').bind(user.id));
    // batch() runs as one transaction; a failure in any statement rolls back
    // and the account stays intact rather than half-deleted.
    await env.DB.batch(statements);
    return json({ deleted: true }, 200);
  }
  return json({ error: 'Method not allowed' }, 405);
}

/** Which of `names` exist as tables here. On any error, assume all of them. */
async function existingTables(env, names) {
  try {
    const placeholders = names.map(() => '?').join(', ');
    const { results } = await env.DB.prepare(
      `SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (${placeholders})`
    ).bind(...names).all();
    return new Set((results || []).map((r) => r.name));
  } catch (e) {
    console.error('existingTables fell back to the full list:', e && e.message);
    return new Set(names);
  }
}

/* ------------------------------------------------------------------ */
/* Rate limits (functions/_lib/ratelimit.js)                           */
/* ------------------------------------------------------------------ */

/**
 * Count a hit; returns a 429 Response when over the limit, else null. Emails
 * are hashed before they become bucket names so the counter table never holds
 * an address in the clear.
 */
async function overLimit(env, bucket, { limit, window }) {
  if (Math.random() < 0.01) await pruneRateLimits(env);
  const result = await rateLimit(env, bucket, limit, window);
  return result.ok ? null : tooManyRequests(result.retryAfter);
}

async function emailBucket(email) {
  return `login:email:${await sha256Hex(String(email).trim().toLowerCase())}`;
}

/* ------------------------------------------------------------------ */
/* Email + password                                                    */
/* ------------------------------------------------------------------ */

async function handleLogin(request, env) {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const { email, password } = await request.json().catch(() => ({}));
  if (typeof email !== 'string' || typeof password !== 'string' || !email.trim() || !password) {
    return json({ error: 'Email and password are required' }, 400);
  }
  const normalizedEmail = email.trim().toLowerCase();

  const limited = (await overLimit(env, `login:ip:${clientIP(request)}`, LIMITS.loginIp))
    || (await overLimit(env, await emailBucket(normalizedEmail), LIMITS.loginEmail));
  if (limited) return limited;

  if (password.length > MAX_LOGIN_PASSWORD) return json({ error: 'Invalid email or password' }, 401);

  const user = await env.DB.prepare('SELECT * FROM users WHERE email = ?')
    .bind(normalizedEmail)
    .first();

  const check = user && user.password_hash
    ? await verifyPassword(password, user.password_hash, env)
    : { ok: false, needsRehash: false };
  if (!check.ok) return json({ error: 'Invalid email or password' }, 401);

  if (check.needsRehash) {
    // Transparent upgrade from the legacy SHA-256 formats (or a lower PBKDF2
    // cost). A failure here must not fail a correct login.
    try {
      await env.DB.prepare('UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?')
        .bind(await hashPassword(password, env), Math.floor(Date.now() / 1000), user.id)
        .run();
    } catch (e) {
      console.error('Password rehash skipped:', e && e.message);
    }
  }

  await ensureFitnessProfile(env, user.id, user.name);
  const token = await issueSession(env, user);
  return json({ message: 'Login successful', token, user: publicUser(user) }, 200);
}

async function handleRegister(request, env) {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const limited = await overLimit(env, `register:ip:${clientIP(request)}`, LIMITS.registerIp);
  if (limited) return limited;

  const { email, password, name } = await request.json().catch(() => ({}));
  if (typeof email !== 'string' || typeof password !== 'string' || !email.trim() || !password) {
    return json({ error: 'Email and password are required' }, 400);
  }
  if (password.length < 8) return json({ error: 'Password must be at least 8 characters' }, 400);
  if (password.length > MAX_PASSWORD_LENGTH) {
    return json({ error: `Password must be at most ${MAX_PASSWORD_LENGTH} characters` }, 400);
  }

  const normalizedEmail = email.trim().toLowerCase();
  // The placeholder domains are reserved for provider accounts with no email;
  // letting someone register one would let them squat a future Apple sign-in.
  if (normalizedEmail.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizedEmail)
      || /\.local$/.test(normalizedEmail)) {
    return json({ error: 'Please enter a valid email address' }, 400);
  }

  const existing = await env.DB.prepare('SELECT id FROM users WHERE email = ?').bind(normalizedEmail).first();
  if (existing) return json({ error: 'An account with that email already exists' }, 409);

  const now = Math.floor(Date.now() / 1000);
  const userId = crypto.randomUUID();
  const displayName = cleanName(name) || normalizedEmail.split('@')[0];
  const passwordHash = await hashPassword(password, env);

  await env.DB.prepare(
    `INSERT INTO users (id, email, password_hash, name, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)`
  ).bind(userId, normalizedEmail, passwordHash, displayName, now, now).run();

  await ensureFitnessProfile(env, userId, displayName);

  const user = { id: userId, email: normalizedEmail, name: displayName };
  const token = await issueSession(env, user);
  return json({ message: 'Account created', token, user: publicUser(user) }, 201);
}

async function handleVerify(request, env) {
  const user = await sessionUser(request, env);
  if (!user) return json({ valid: false, error: 'Invalid or missing token' }, 401);
  return json({ valid: true, user: publicUser(user) }, 200);
}

async function handleLogout(request, env) {
  const authHeader = request.headers.get('Authorization') || '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : readCookie(request, 'batesai_session');
  if (token) {
    try {
      await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(await sha256Hex(token)).run();
    } catch (e) {
      console.error('Logout cleanup failed:', e && e.message);
    }
  }
  return json({ message: 'Logged out successfully' }, 200);
}

/* ------------------------------------------------------------------ */
/* Native handoff: browser sign-in -> one-time code -> app session     */
/* ------------------------------------------------------------------ */

/** The scheme if it is on the allow-list, else null. Never echo anything else. */
function allowedAppScheme(value) {
  return typeof value === 'string' && APP_SCHEMES.includes(value) ? value : null;
}

/**
 * Mint a one-time code for the native app (API_V2 §1.1). 32 random bytes,
 * base64url; only its SHA-256 is stored. The session token itself never goes
 * into a URL: the app trades this code for one via POST /handoff.
 */
async function mintHandoffCode(env, userId, scheme) {
  const code = base64UrlFromBytes(crypto.getRandomValues(new Uint8Array(32)));
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    `INSERT INTO auth_handoff_codes (code_hash, user_id, scheme, created_at, expires_at)
     VALUES (?, ?, ?, ?, ?)`
  ).bind(await sha256Hex(code), userId, scheme, now, now + HANDOFF_TTL_SECONDS).run();
  try {
    // Housekeeping: codes are worthless a few minutes after minting.
    await env.DB.prepare('DELETE FROM auth_handoff_codes WHERE expires_at < ?').bind(now - 86400).run();
  } catch { /* best effort */ }
  return code;
}

/**
 * POST /api/auth/handoff {code} -> {success, token, user}, the same shape as
 * /login. Single use: the claim is one conditional UPDATE, so two concurrent
 * redemptions cannot both win.
 */
async function handleHandoff(request, env) {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const limited = await overLimit(env, `handoff:ip:${clientIP(request)}`, LIMITS.handoffIp);
  if (limited) return limited;

  const body = await request.json().catch(() => ({}));
  const code = typeof body.code === 'string' ? body.code.trim() : '';
  if (!/^[A-Za-z0-9_-]{43}$/.test(code)) return json({ error: 'invalid_code' }, 400);

  const hash = await sha256Hex(code);
  const now = Math.floor(Date.now() / 1000);
  const claimed = await env.DB.prepare(
    `UPDATE auth_handoff_codes SET used_at = ?
      WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?
      RETURNING user_id`
  ).bind(now, hash, now).first();

  if (!claimed) {
    const row = await env.DB.prepare('SELECT used_at FROM auth_handoff_codes WHERE code_hash = ?')
      .bind(hash).first();
    if (!row) return json({ error: 'invalid_code' }, 400);
    return json({ error: row.used_at ? 'code_used' : 'code_expired' }, 400);
  }

  const user = await env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(claimed.user_id).first();
  if (!user) return json({ error: 'invalid_code' }, 400);

  await ensureFitnessProfile(env, user.id, user.name);
  const token = await issueSession(env, user);
  return json({ success: true, message: 'Login successful', token, user: publicUser(user) }, 200);
}

/**
 * Start-of-flow cookies shared by both providers: the app scheme and the
 * return path. `sameSite` is 'Lax' for Google (it returns with a top-level
 * GET) and 'None' for Apple (it returns with a cross-site form POST, which a
 * Lax cookie would not ride along on). A plain sign-in clears leftovers from an
 * abandoned attempt so they cannot redirect this one.
 */
function appendFlowCookies(headers, request, url, sameSite) {
  const scheme = allowedAppScheme(url.searchParams.get('redirect_scheme'));
  if (scheme) {
    headers.append('Set-Cookie',
      `${APP_SCHEME_COOKIE}=${scheme}; Path=/; Max-Age=${APP_SCHEME_MAX_AGE}; SameSite=${sameSite}; Secure; HttpOnly`);
  } else if (readCookie(request, APP_SCHEME_COOKIE) !== null) {
    headers.append('Set-Cookie', `${APP_SCHEME_COOKIE}=; Path=/; Max-Age=0; SameSite=${sameSite}; Secure; HttpOnly`);
  }

  // Optional landing page for after the /membership callback (e.g.
  // /subjectmastery/, /fitness/). An invalid value is ignored, never echoed.
  // The app handoff takes precedence, so a return path is not kept alongside it.
  const returnTo = scheme ? null : safeReturnPath(url.searchParams.get('return_to'));
  if (returnTo) {
    headers.append('Set-Cookie', sameSite === 'Lax'
      ? returnToCookie(returnTo)
      : returnToCookie(returnTo).replace('SameSite=Lax', `SameSite=${sameSite}`));
  } else if (readCookie(request, RETURN_TO_COOKIE) !== null) {
    headers.append('Set-Cookie', CLEAR_RETURN_TO_COOKIE);
  }
}

/* ------------------------------------------------------------------ */
/* Browser OAuth (redirect + callback)                                 */
/* ------------------------------------------------------------------ */

async function handleOAuth(request, env, url, path) {
  const provider = path[1] || '';

  if (provider === 'google') {
    if (request.method === 'GET') {
      const clientId = googleAudiences(env)[0];
      if (!clientId) return json({ error: 'Google OAuth is not configured' }, 500);
      const state = crypto.randomUUID();
      const redirectUri = `${url.origin}/membership`;
      const authUrl =
        `https://accounts.google.com/o/oauth2/v2/auth?client_id=${encodeURIComponent(clientId)}` +
        `&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code` +
        `&scope=${encodeURIComponent('email profile openid')}&state=${state}` +
        `&access_type=offline&prompt=select_account`;
      const headers = new Headers({ Location: authUrl });
      headers.append('Set-Cookie', `google_oauth_state=${state}; Path=/; Max-Age=300; SameSite=Lax; Secure; HttpOnly`);
      appendFlowCookies(headers, request, url, 'Lax');
      return new Response(null, { status: 302, headers });
    }

    if (request.method === 'POST') {
      const body = await request.json().catch(() => ({}));
      let idToken = body.id_token;

      if (!idToken && body.authorization_code) {
        const clientId = googleAudiences(env)[0];
        const clientSecret = env.OAUTH_GOOGLE_CLIENT_SECRET || env.GOOGLE_CLIENT_SECRET;
        if (!clientId || !clientSecret) return json({ error: 'Google OAuth is not fully configured' }, 500);

        const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            code: body.authorization_code,
            client_id: clientId,
            client_secret: clientSecret,
            redirect_uri: `${url.origin}/membership`,
            grant_type: 'authorization_code',
          }),
        });
        if (!tokenRes.ok) {
          // Surface Google's own error code. These are diagnostic OAuth codes
          // (invalid_client, invalid_grant, redirect_uri_mismatch), not
          // secrets, and without them a failed sign-in is unfixable from the
          // client side — the page could only ever say "it didn't work".
          const raw = await tokenRes.text();
          console.error('Google token exchange failed:', raw);
          let detail = null;
          let code = null;
          try {
            const parsed = JSON.parse(raw);
            detail = parsed.error_description || parsed.error || null;
            code = parsed.error || null;
          } catch { /* non-JSON body: fall through with no detail */ }
          // `code` is the machine-readable form (invalid_grant, …). The
          // /membership callback keys its user-facing message off it, so it
          // must survive separately from the prose description.
          return json({ error: 'Failed to exchange authorization code', detail, code }, 400);
        }
        idToken = (await tokenRes.json()).id_token;
      }

      if (!idToken) return json({ error: 'No Google credential supplied' }, 400);

      const claims = await verifyProviderToken(idToken, {
        jwksUrl: GOOGLE_JWKS_URL,
        issuers: GOOGLE_ISSUERS,
        audiences: googleAudiences(env),
      });
      if (!claims) return json({ error: 'Invalid Google id token' }, 401);

      const { user, conflict } = await upsertOAuthUser(env, {
        provider: 'google',
        sub: claims.sub,
        email: claims.email,
        name: claims.name,
        avatarUrl: claims.picture || null,
        emailVerified: isEmailVerified(claims),
      });
      if (conflict) return accountExistsResponse();
      return browserSignInResponse(env, user, body.app_scheme);
    }
  }

  if (provider === 'apple') {
    if (request.method === 'GET') {
      const clientId = env.OAUTH_APPLE_CLIENT_ID || env.APPLE_CLIENT_ID || 'org.batesai.membership';
      const state = crypto.randomUUID();
      const redirectUri = `${url.origin}/membership`;
      const authUrl =
        `https://appleid.apple.com/auth/authorize?client_id=${encodeURIComponent(clientId)}` +
        `&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=${encodeURIComponent('code id_token')}` +
        // "code id_token" so Apple signs an identity token into the callback
        // itself. Verifying that against Apple's public keys needs no client
        // secret, which means the .p8 private key never has to live in Pages —
        // see wrangler.toml. Asking for "code" alone would force a secret we
        // deliberately do not hold.
        `&scope=${encodeURIComponent('email name')}&state=${state}` +
        `&response_mode=form_post`;
      const headers = new Headers({ Location: authUrl });
      // SameSite=None, unlike the Google cookies: Apple returns via a
      // cross-site POST, and a Lax cookie is not sent on one. Without this
      // the state check on the way back can never succeed.
      headers.append('Set-Cookie', `apple_oauth_state=${state}; Path=/; Max-Age=300; SameSite=None; Secure; HttpOnly`);
      appendFlowCookies(headers, request, url, 'None');
      return new Response(null, { status: 302, headers });
    }

    if (request.method === 'POST') {
      const body = await request.json().catch(() => ({}));
      let idToken = body.id_token;

      if (!idToken && body.authorization_code) {
        const clientId = env.OAUTH_APPLE_CLIENT_ID || env.APPLE_CLIENT_ID;
        const clientSecret = env.OAUTH_APPLE_CLIENT_SECRET || env.APPLE_CLIENT_SECRET;
        if (!clientId || !clientSecret) return json({ error: 'Apple OAuth is not fully configured' }, 500);

        const tokenRes = await fetch('https://appleid.apple.com/auth/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            grant_type: 'authorization_code',
            code: body.authorization_code,
            redirect_uri: `${url.origin}/membership`,
            client_id: clientId,
            client_secret: clientSecret,
          }),
        });
        if (!tokenRes.ok) {
          console.error('Apple token exchange failed:', await tokenRes.text());
          return json({ error: 'Failed to exchange authorization code' }, 400);
        }
        idToken = (await tokenRes.json()).id_token;
      }

      if (!idToken) return json({ error: 'No Apple credential supplied' }, 400);

      const claims = await verifyProviderToken(idToken, {
        jwksUrl: APPLE_JWKS_URL,
        issuers: [APPLE_ISSUER],
        audiences: appleAudiences(env),
      });
      if (!claims) return json({ error: 'Invalid Apple id token' }, 401);

      const { user, conflict } = await upsertOAuthUser(env, {
        provider: 'apple',
        sub: claims.sub,
        email: claims.email,
        name: formatAppleName(body.user),
        avatarUrl: null,
        emailVerified: isEmailVerified(claims),
      });
      if (conflict) return accountExistsResponse();
      return browserSignInResponse(env, user, body.app_scheme);
    }
  }

  return json({ error: 'Unknown OAuth provider' }, 404);
}

/**
 * Finish a browser sign-in. Normally: a session plus the website's
 * batesai_session cookie (the /membership callback lifts the cookie onto its
 * own redirect). When functions/membership.js passes an allow-listed
 * `app_scheme`, the sign-in is for a native app instead: no session or cookie
 * is created here, only a one-time handoff code the app redeems itself.
 */
async function browserSignInResponse(env, user, appSchemeValue) {
  const scheme = allowedAppScheme(appSchemeValue);
  if (scheme) {
    const code = await mintHandoffCode(env, user.id, scheme);
    return json({ success: true, handoff_code: code, scheme }, 200);
  }
  const token = await issueSession(env, user);
  const res = json({ success: true, token, user: publicUser(user) }, 200);
  res.headers.append('Set-Cookie',
    `batesai_session=${token}; Path=/; Max-Age=${SESSION_TTL_SECONDS}; SameSite=Lax; Secure; HttpOnly`);
  return res;
}

/* ------------------------------------------------------------------ */
/* JWT / crypto utilities                                              */
/* ------------------------------------------------------------------ */

function base64UrlFromBytes(bytes) {
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlEncode(str) {
  const bytes = new TextEncoder().encode(str);
  let binary = '';
  bytes.forEach((b) => { binary += String.fromCharCode(b); });
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlToBytes(str) {
  const padded = str + '='.repeat((4 - (str.length % 4)) % 4);
  const base64 = padded.replace(/-/g, '+').replace(/_/g, '/');
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

function base64UrlDecode(str) {
  return new TextDecoder().decode(base64UrlToBytes(str));
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return toHex(new Uint8Array(digest));
}

function toHex(bytes) {
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('');
}

function bytesToBase64(bytes) {
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

function base64ToBytes(str) {
  return Uint8Array.from(atob(str), (c) => c.charCodeAt(0));
}

/** Compare without an early exit, so timing does not reveal the matching prefix. */
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

function pbkdf2Iterations(env) {
  const configured = Number(env && env.PBKDF2_ITERATIONS);
  if (!Number.isInteger(configured)) return PBKDF2_MAX_ITERATIONS;
  return Math.min(PBKDF2_MAX_ITERATIONS, Math.max(PBKDF2_MIN_ITERATIONS, configured));
}

async function pbkdf2(password, salt, iterations) {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveBits']
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt, iterations }, key, 256
  );
  return new Uint8Array(bits);
}

/** pbkdf2$<iterations>$<salt base64>$<hash base64>, 16-byte salt, 32-byte hash. */
async function hashPassword(password, env) {
  const iterations = pbkdf2Iterations(env);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await pbkdf2(password, salt, iterations);
  return `pbkdf2$${iterations}$${bytesToBase64(salt)}$${bytesToBase64(hash)}`;
}

/**
 * Returns { ok, needsRehash }. Understands, newest first:
 *   pbkdf2$<iter>$<salt b64>$<hash b64>   current
 *   $sha256$<salt hex>$<hex>              SHA-256(password + salt), before 2026-10-27
 *   <64 hex chars>                        unsalted SHA-256, the oldest accounts
 * Anything but a current-cost PBKDF2 hash is upgraded on the next good login.
 */
async function verifyPassword(password, storedHash, env) {
  try {
    const enc = new TextEncoder();
    const parts = String(storedHash).split('$');
    if (parts.length === 4 && parts[0] === 'pbkdf2') {
      const iterations = Number(parts[1]);
      if (!Number.isInteger(iterations) || iterations < 1 || iterations > PBKDF2_MAX_ITERATIONS) {
        return { ok: false, needsRehash: false };
      }
      const expected = base64ToBytes(parts[3]);
      const actual = await pbkdf2(password, base64ToBytes(parts[2]), iterations);
      const ok = timingSafeEqual(actual, expected);
      return { ok, needsRehash: ok && iterations < pbkdf2Iterations(env) };
    }
    if (parts.length === 4 && parts[0] === '' && parts[1] === 'sha256') {
      const digest = await crypto.subtle.digest('SHA-256', enc.encode(password + parts[2]));
      const ok = timingSafeEqual(enc.encode(toHex(new Uint8Array(digest))), enc.encode(parts[3]));
      return { ok, needsRehash: ok };
    }
    if (/^[0-9a-f]{64}$/i.test(storedHash)) {
      const digest = await crypto.subtle.digest('SHA-256', enc.encode(password));
      const ok = timingSafeEqual(enc.encode(toHex(new Uint8Array(digest))), enc.encode(storedHash.toLowerCase()));
      return { ok, needsRehash: ok };
    }
    return { ok: false, needsRehash: false };
  } catch {
    return { ok: false, needsRehash: false };
  }
}

/* ------------------------------------------------------------------ */
/* HTTP helpers                                                        */
/* ------------------------------------------------------------------ */

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function corsHeaders(env, origin) {
  const allowed = (env.ALLOWED_ORIGINS || '').split(',').map((s) => s.trim()).filter(Boolean);
  // Native apps send no Origin header at all; browsers must match the allowlist.
  const value = !allowed.length ? '*' : allowed.includes(origin) ? origin : allowed[0];
  return {
    'Access-Control-Allow-Origin': value,
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    Vary: 'Origin',
  };
}

function withCors(response, env, origin) {
  const headers = new Headers(response.headers);
  Object.entries(corsHeaders(env, origin)).forEach(([k, v]) => headers.set(k, v));
  return new Response(response.body, { status: response.status, headers });
}
